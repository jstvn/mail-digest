import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")
private let outlook = MailboxRef(account: "Outlook", name: "Inbox")

private func settings(_ filter: MailFilter = MailFilter(), mailboxes: [MailboxRef] = [icloud, outlook]) -> RunnerSettings {
    RunnerSettings(timeZone: FixtureLoader.timeZone, filter: filter, dailyMailboxes: mailboxes)
}

/// Everything a test needs around one runner.
private struct Harness {
    let clock = FixedClock(today)
    let store: InMemoryDigestStore
    let llm: StubLLMClient
    let source: FixtureMailSource
    let notifier = RecordingNotifier()
    let runner: JobRunner
    let collector = ProgressCollector()

    init(source: FixtureMailSource, llm: StubLLMClient, store: InMemoryDigestStore = InMemoryDigestStore(),
         settings: RunnerSettings = settings()) {
        self.source = source
        self.llm = llm
        self.store = store
        runner = JobRunner(source: source, llm: llm, store: store, notifier: notifier, clock: clock,
                           settings: settings, sleep: { _ in })
    }

    /// Fixture mail with canned model answers.
    static func fixtures(filter: MailFilter = MailFilter()) async throws -> Harness {
        let h = Harness(source: FixtureMailSource(messages: try FixtureLoader.loadEmails()),
                        llm: StubLLMClient(results: try FixtureLoader.loadResultsByEmailID(), headlineText: "Stub headline."),
                        settings: settings(filter))
        await h.collector.attach(h.runner.progress)
        return h
    }

    func plan(kind: JobKind = .backlog, boxes: [MailboxRef] = [icloud, outlook], excluded: Set<String> = [],
              from: Date = today.addingTimeInterval(-30 * 86_400),
              to: Date = today.addingTimeInterval(60)) -> JobPlan {
        JobPlan(kind: kind, mailboxes: boxes, from: from, to: to, excludedMessageIDs: excluded)
    }

    func job(_ id: UUID? = nil) async throws -> Job {
        let all = try await store.jobs()
        return try #require(id.flatMap { id in all.first { $0.id == id } } ?? all.first)
    }

    func digest() async throws -> Digest { try #require(await store.allDigests().last) }
}

/// Old generated mail in iCloud Inbox, ending ten days before "today" (outside the Daily window).
private func oldMessages(_ count: Int, prefix: String = "old") -> [EmailMessage] {
    (0..<count).map { n in
        EmailMessage(id: "\(prefix)-\(n)@fixture", account: "iCloud", mailbox: "Inbox",
                     sender: "Sam <sam@example.com>", subject: "Old \(n)",
                     receivedAt: today.addingTimeInterval(-10 * 86_400 - 600 * Double(n)),
                     body: "Hello. Please reply by Friday.", headers: [:])
    }
}

@Suite struct JobRunnerTests {
    // MARK: Q25 provider failures

    @Test func unhealthyProviderStopsStartBeforeAnyJobIsCreated() async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(2)), llm: StubLLMClient(healthy: false))
        await #expect(throws: JobRunnerError.self) { try await h.runner.start(h.plan(boxes: [icloud])) }
        await #expect(throws: JobRunnerError.self) { try await h.runner.startDaily() }
        #expect(try await h.store.jobs().isEmpty)
        #expect(await h.llm.extractCalls.isEmpty)
        #expect(await h.source.listCalls == 0)
        // The runner is not left claimed.
        await h.llm.setHealthy(true)
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }

    @Test(arguments: [LLMError.unreachable("connection refused"), LLMError.timedOut, LLMError.http(status: 503)])
    func outageMidJobFailsTheJobWithoutSpendingAttempts(error: LLMError) async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(3)), llm: StubLLMClient())
        await h.collector.attach(h.runner.progress)
        let llm = h.llm
        await llm.setOnExtract { email in
            if email.id == "old-1@fixture" {
                await llm.setHealthy(false)
                throw error
            }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        var job = try await h.job()
        #expect(job.state == .failed)
        // The health check's reason is stored (the stub reports "unhealthy"; Ollama gives its fix text).
        #expect(job.lastError == "unhealthy")
        let items = await h.store.allItems()
        let hit = try #require(items.first { $0.messageID == "old-1@fixture" })
        #expect(hit.state == .queued && hit.attempts == 0)
        #expect(items.first { $0.messageID == "old-0@fixture" }?.state == .done)
        #expect(items.first { $0.messageID == "old-2@fixture" }?.state == .queued)
        #expect(await h.collector.events.last?.error == job.lastError)

        // Resuming while Ollama is still down fails fast and leaves the job as it was.
        await #expect(throws: JobRunnerError.self) { try await h.runner.resume(jobID: job.id) }
        #expect(try await h.job().state == .failed)

        // Once it is back, the same job resumes and finishes the remaining emails.
        await llm.setOnExtract(nil)
        await llm.setHealthy(true)
        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()
        job = try await h.job()
        #expect(job.state == .finished && job.lastError == nil)
        #expect(await h.store.allItems().allSatisfy { $0.state == .done && $0.attempts == 0 })
    }

    @Test func itemErrorWithHealthyProviderUsesTheRetryBudget() async throws {
        // StubLLMError.malformed while the provider is healthy is an item failure, not a job failure.
        let h = Harness(source: FixtureMailSource(messages: oldMessages(2)),
                        llm: StubLLMClient(failures: ["old-0@fixture": Int.max]))
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
        let bad = try #require(await h.store.allItems().first { $0.messageID == "old-0@fixture" })
        #expect(bad.state == .failed && bad.attempts == 3)
    }

    @Test func jobDecodesWithoutLastError() throws {
        let job = Job(id: UUID(), kind: .daily, mailboxes: [], scopeFrom: Date(timeIntervalSince1970: 0),
                      scopeTo: Date(timeIntervalSince1970: 60), state: .failed, createdAt: Date(timeIntervalSince1970: 0),
                      totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0), autoPaused: false, lastError: "x")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object["lastError"] = nil
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.lastError == nil && decoded.id == job.id)
    }

    // MARK: Q35 timeouts

    @Test func timedOutExtractionFailsOnceWithoutAutomaticRetry() async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(2)), llm: StubLLMClient())
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { throw LLMError.timedOut }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        // One attempt only, then failed; the other email is unaffected.
        #expect(await h.llm.extractCalls.filter { $0.id == "old-0@fixture" }.count == 1)
        let item = try #require(await h.store.allItems().first { $0.messageID == "old-0@fixture" })
        #expect(item.state == .failed)
        #expect(try await h.job().totals.done == 1)

        // Manual retry is still available and succeeds once the model answers.
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        #expect(try await h.runner.retryFailed(jobID: job.id) == 1)
        await h.runner.waitUntilIdle()
        #expect(try #require(await h.store.allItems().first { $0.messageID == "old-0@fixture" }).state == .done)
    }

    // MARK: Unreadable bodies

    @Test(arguments: ["", "  \n\t \r\n "])
    func emptyBodyIsSkippedWithoutModelCallOrAttempt(body: String) async throws {
        var messages = oldMessages(2)
        messages[0].body = body
        let h = Harness(source: FixtureMailSource(messages: messages), llm: StubLLMClient())
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        // Only the readable message reaches the model.
        #expect(await h.llm.extractCalls.map(\.id) == ["old-1@fixture"])
        let item = try #require(await h.store.allItems().first { $0.messageID == "old-0@fixture" })
        #expect(item.state == .skipped)
        #expect(item.attempts == 0)
        #expect(item.outcome == "skipped: no readable body")
        // Not marked processed, so a later job can try again once Mail has the body.
        #expect(try await h.store.isProcessed("old-0@fixture") == false)
        let digest = try await h.digest()
        #expect(digest.skipped.contains { $0.id == "old-0@fixture" && $0.reason == "no readable body" })
        #expect(try await h.job().totals.skipped == 1)
        #expect(try await h.job().totals.done == 1)
    }

    // MARK: 1, 2 End-to-end Daily job

    @Test func dailyJobOverFixtures() async throws {
        let h = try await Harness.fixtures()
        let emails = try FixtureLoader.loadEmails()
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()

        let digest = try await h.digest()
        let job = try await h.job()
        #expect(job.state == .finished && job.kind == .daily)
        #expect(digest.id == job.id)
        #expect(digest.emailCount == 18)
        #expect(Set(digest.info.map(\.emailID)) == Set(emails.map(\.id)))
        #expect(digest.skipped.isEmpty)
        #expect(digest.headline == "Stub headline.")
        #expect(job.totals == JobTotals(queued: 0, done: 18, failed: 0, skipped: 0))
        #expect(await h.store.processedIDs() == Set(emails.map(\.id)))
        #expect(await h.source.checkCalls == 1)

        // Hand-written expectation: (email prefix, title, due day in Brisbane, preselected).
        // Rent and energy are money mail from unapproved senders (rule 7, so not preselected); event-14 and
        // scam-15 lose their due date because the evidence has no date words (rule 3).
        let expected: [(String, String, String?, Bool)] = [
            ("uni-assessment-01", "Submit IFB398 Assessment 2", "2026-11-09", true),
            ("uni-exam-02", "Check exam timetable", "2026-11-06", true),
            ("bill-rent-04", "Pay rent $420", "2026-11-06", false),
            ("bill-energy-05", "Pay Origin bill $182.40", "2026-11-20", false),
            ("deliv-auspost-07", "Be home for parcel", "2026-11-05", false),
            ("event-14", "RSVP to Jamie's housewarming", nil, false),
            ("personal-sam-12", "Reply to Sam about Saturday", "2026-11-05", true),
            ("work-13", "Send Q4 planning feedback", "2026-11-11", true),
            ("quote-17", "Meet Sam Tuesday 3pm", "2026-11-10", true),
            ("misc-18", "Attend dental check-up", "2026-11-12", true),
            ("scam-15", "Buy gift cards", nil, false),
        ]
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = FixtureLoader.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let actual = digest.suggestions.map { s in
            (String(s.emailID.split(separator: "@")[0]), s.title, s.due.map(fmt.string(from:)), s.preselected)
        }
        for e in expected {
            let match = actual.first { $0.0 == e.0 }
            #expect(match?.1 == e.1, "\(e.0)")
            #expect(match?.2 == e.2, "\(e.0)")
            #expect(match?.3 == e.3, "\(e.0)")
        }
        #expect(actual.count == expected.count, "\(actual)")

        let pending = digest.suggestions.filter { $0.status == .pending }.count
        #expect(await h.notifier.messages == ["\(pending) suggestions ready"])
    }

    @Test func dailyJobKeepsEverySuggestionAndTagsCategory() async throws {
        // Q16: the 25-suggestion cap is presentation-only; the runner persists all of them.
        let recent = (0..<30).map { n in
            EmailMessage(id: "many-\(n)@fixture", account: "iCloud", mailbox: "Inbox",
                         sender: "Sam \(n) <sam\(n)@example.com>", subject: "Hi \(n)",
                         receivedAt: today.addingTimeInterval(-3600 - 60 * Double(n)),
                         body: "Hello. Please reply by Friday.", headers: [:])
        }
        let results = Dictionary(uniqueKeysWithValues: recent.map { m in
            (m.id, ExtractionResult(summary: "s", category: .finance, importance: 2, keyFacts: [], tasks: [
                ExtractedTask(title: "Reply to \(m.subject)", due: nil, dueHasTime: false, priority: .medium,
                              evidence: "Please reply by Friday", confidence: 0.9)]))
        })
        let h = Harness(source: FixtureMailSource(messages: recent), llm: StubLLMClient(results: results),
                        settings: settings(mailboxes: [icloud]))
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let digest = try await h.digest()
        #expect(digest.suggestions.count == 30 && digest.emailCount == 30)
        #expect(digest.suggestions.allSatisfy { $0.category == .finance })
    }

    @Test func emptyJobLeavesNoDigestAndRetryFailedDropsFailedResults() async throws {
        let h = Harness(source: FixtureMailSource(messages: []), llm: StubLLMClient())
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(await h.store.allDigests().isEmpty)

        let h2 = Harness(source: FixtureMailSource(messages: oldMessages(2)),
                         llm: StubLLMClient(failures: ["old-0@fixture": Int.max]))
        try await h2.runner.start(h2.plan(boxes: [icloud]))
        await h2.runner.waitUntilIdle()
        let failed = try await h2.digest()
        #expect(failed.emailCount == 2 && failed.skipped.map(\.id) == ["old-0@fixture"])
        await h2.llm.setFailures([:])
        #expect(try await h2.runner.retryFailed(jobID: failed.id) == 1)
        await h2.runner.waitUntilIdle()
        let fixed = try await h2.digest()
        #expect(fixed.emailCount == 2 && fixed.skipped.isEmpty && fixed.info.count == 2)
    }

    @Test func injectionScamAndNewsletters() async throws {
        let h = try await Harness.fixtures()
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let digest = try await h.digest()
        func suggestions(_ prefix: String) -> [Suggestion] { digest.suggestions.filter { $0.emailID.hasPrefix(prefix) } }

        #expect(suggestions("inject-16").isEmpty)
        let scam = try #require(suggestions("scam-15").first)
        #expect(scam.flags.contains("money-new-sender"))
        #expect(scam.preselected == false)
        for prefix in ["news-tech-09", "news-shop-10", "news-uni-11"] {
            #expect(suggestions(prefix).isEmpty)
            #expect(digest.info.contains { $0.emailID.hasPrefix(prefix) })
        }
        // Newsletters are info-only tier, so the extract call carries no tasks request.
        let calls = await h.llm.extractCalls
        #expect(calls.filter { $0.id.hasPrefix("news-") }.allSatisfy { $0.tier == .infoOnly })
    }

    // MARK: 3 Blocked sender

    @Test func blockedSenderSkippedWithoutModelCall() async throws {
        let emails = try FixtureLoader.loadEmails()
        let target = try #require(emails.first { $0.id.hasPrefix("work-13") })
        let h = try await Harness.fixtures(filter: MailFilter(blockedSenders: [MailFilter.address(from: target.sender)]))
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()

        #expect(await h.llm.extractCalls.contains { $0.id == target.id } == false)
        let digest = try await h.digest()
        let skipped = try #require(digest.skipped.first)
        #expect(skipped.id == target.id && skipped.reason == "blocked sender")
        #expect(digest.info.contains { $0.emailID == target.id } == false)
        let item = try #require(await h.store.allItems().first { $0.messageID == target.id })
        #expect(item.state == .skipped && item.outcome == "skipped: blocked sender")
        #expect(await h.store.processedIDs().contains(target.id))
        #expect(try await h.job().totals.skipped == 1)
    }

    // MARK: 4 Fetch batches

    @Test func fetchesInBatchesOfTen() async throws {
        let h = try await Harness.fixtures()
        try await h.runner.start(h.plan())
        await h.runner.waitUntilIdle()
        let calls = await h.source.fetchCalls
        #expect(calls.allSatisfy { $0.count <= 10 && !$0.isEmpty })
        #expect(calls.flatMap { $0 }.count == 18)
        // 12 iCloud + 6 Outlook: batches never mix mailboxes in one call.
        #expect(calls.count >= 3)
    }

    // MARK: 5 Dedupe

    @Test func secondRunFindsNothingNew() async throws {
        let h = try await Harness.fixtures()
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let extractsAfterFirst = await h.llm.extractCalls.count

        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        // A Backlog job over the same window also finds everything processed.
        try await h.runner.start(h.plan())
        await h.runner.waitUntilIdle()

        #expect(await h.llm.extractCalls.count == extractsAfterFirst)
        let jobs = try await h.store.jobs()
        #expect(jobs.count == 3 && jobs.allSatisfy { $0.state == .finished })
        #expect(await h.notifier.messages.count == 1)
        #expect(await h.store.allDigests().count == 1) // empty jobs write no digest
    }

    @Test func excludedIDsAreNeverQueued() async throws {
        let h = try await Harness.fixtures()
        let all = try FixtureLoader.loadEmails().map(\.id)
        let skipIDs = Set(all.filter { id in id.hasPrefix("news-tech-09") || id.hasPrefix("work-13") })
        try await h.runner.start(h.plan(excluded: skipIDs))
        await h.runner.waitUntilIdle()
        let queued = Set(await h.store.allItems().map(\.messageID))
        #expect(queued.isDisjoint(with: skipIDs))
        #expect(queued.count == 16)
        #expect(await h.llm.extractCalls.count == 16)
    }

    @Test func maxEmailsPerRunKeepsNewestForDaily() async throws {
        var s = settings()
        s.maxEmailsPerRun = 5
        let source = FixtureMailSource(messages: try FixtureLoader.loadEmails())
        let h = Harness(source: source, llm: StubLLMClient(results: try FixtureLoader.loadResultsByEmailID()), settings: s)
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let items = await h.store.allItems()
        #expect(items.count == 5)
        let newest = try FixtureLoader.loadEmails().sorted { $0.receivedAt > $1.receivedAt }.prefix(5).map(\.id)
        #expect(Set(items.map(\.messageID)) == Set(newest))
        #expect(items.map(\.receivedAt) == items.map(\.receivedAt).sorted(by: >))
    }
}

/// Counts calls so a hook can behave differently the first time.
private actor Counter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

@Suite struct JobRunnerPauseResumeTests {
    // MARK: 6 Large inbox: pause and resume

    @Test func pauseMidBacklogThenResumeFinishesAllWithoutRepeats() async throws {
        let source = FixtureMailSource.generatedInbox(count: 3000, mailboxes: [icloud], endingAt: today)
        let h = Harness(source: source, llm: StubLLMClient(headlineText: "Big backlog."))
        await h.collector.attach(h.runner.progress)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "gen-4@fixture" { await runner.pause() }
        }

        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        let items = await h.store.allItems()
        #expect(items.count == 3000)
        #expect(items.filter { $0.state == .done }.count == 5)
        #expect(items.filter { $0.state == .queued }.count == 2995)
        let paused = try await h.job()
        #expect(paused.state == .paused && paused.autoPaused == false)
        #expect(paused.totals == JobTotals(queued: 2995, done: 5, failed: 0, skipped: 0))
        #expect(await h.store.allDigests().last?.emailCount == 5)

        #expect(await eventually { await h.collector.events.last?.state == .paused })
        let last = try #require(await h.collector.events.last)
        #expect(last.lastFinished?.messageID == "gen-4@fixture" && last.lastFinished?.outcome == "info only")
        #expect(last.nextUp?.messageID == "gen-5@fixture")
        #expect(last.done == 5 && last.total == 3000)
        let states = await h.collector.events.map(\.state)
        #expect(states.contains(.pausing))

        await h.llm.setOnExtract(nil)
        try await h.runner.resume()
        await h.runner.waitUntilIdle()

        let calls = await h.llm.extractCalls.map(\.id)
        #expect(calls.count == 3000 && Set(calls).count == 3000)
        #expect(calls[5] == "gen-5@fixture")
        let finalItems = await h.store.allItems()
        // Q22: pausing never spends attempts.
        #expect(finalItems.allSatisfy { $0.state == .done && $0.attempts == 0 })
        #expect(try await h.job().state == .finished)
        let digest = try await h.digest()
        #expect(digest.emailCount == 3000 && digest.info.count == 3000 && digest.headline == "Big backlog.")
        #expect(await h.notifier.messages.isEmpty) // no suggestions, no notification
    }

    // MARK: 7 Simulated crash

    @Test func recoverAfterCrashRequeuesAndResumes() async throws {
        let source = FixtureMailSource(messages: oldMessages(4))
        let store = InMemoryDigestStore()
        let h = Harness(source: source, llm: StubLLMClient(), store: store)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.pause() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(await store.allItems().filter { $0.state == .done }.count == 2)

        // Mimic a crash while old-2 was in flight: item left processing, job left running.
        let crashed = try #require(await store.allItems().first { $0.messageID == "old-2@fixture" })
        try await store.setItemState(crashed.id, .processing, error: nil)
        var job = try await h.job()
        job.state = .running
        try await store.updateJob(job)

        let llm2 = StubLLMClient()
        let runner2 = JobRunner(source: source, llm: llm2, store: store, notifier: h.notifier, clock: h.clock,
                                settings: settings(), sleep: { _ in })
        try await runner2.recoverOnLaunch()
        #expect(try await h.job().state == .paused)
        #expect(await store.allItems().first { $0.id == crashed.id }?.state == .queued)

        try await runner2.resume()
        await runner2.waitUntilIdle()

        #expect(await llm2.extractCalls.map(\.id) == ["old-2@fixture", "old-3@fixture"])
        let items = await store.allItems()
        #expect(items.allSatisfy { $0.state == .done })
        // Q22: a crash and its recovery do not count as failures.
        #expect(items.first { $0.id == crashed.id }?.attempts == 0)
        #expect(try await h.job().state == .finished)
        // The resumed run kept appending to the same digest.
        #expect(await store.allDigests().count == 1)
        #expect(try await h.digest().info.count == 4)
    }

    // MARK: 8 Retries

    @Test func itemsFailingThreeTimesEndFailedAndOneFailureRecovers() async throws {
        let source = FixtureMailSource(messages: oldMessages(3))
        let llm = StubLLMClient(failures: ["old-0@fixture": Int.max, "old-1@fixture": 1])
        let h = Harness(source: source, llm: llm)
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        let items = await h.store.allItems()
        let bad = try #require(items.first { $0.messageID == "old-0@fixture" })
        #expect(bad.state == .failed && bad.attempts == 3 && bad.lastError == "malformed")
        #expect(bad.outcome == "failed: malformed")
        let flaky = try #require(items.first { $0.messageID == "old-1@fixture" })
        #expect(flaky.state == .done && flaky.attempts == 1)  // one genuine failure

        let digest = try await h.digest()
        #expect(digest.skipped.map(\.id) == ["old-0@fixture"])
        #expect(digest.skipped.first?.reason == "failed: malformed")
        #expect(digest.emailCount == 3 && digest.info.count == 2)
        let processed = await h.store.processedIDs()
        #expect(processed == ["old-1@fixture", "old-2@fixture"])
        #expect(await llm.extractCalls.filter { $0.id == "old-0@fixture" }.count == 3)
        let job = try await h.job()
        #expect(job.state == .finished)
        #expect(job.totals == JobTotals(queued: 0, done: 2, failed: 1, skipped: 0))
    }

    // MARK: 9 Pause now and stop

    @Test(arguments: [true, false]) func cancelInFlightRequeuesItem(usePauseNow: Bool) async throws {
        let source = FixtureMailSource(messages: oldMessages(3))
        let h = Harness(source: source, llm: StubLLMClient())
        let entered = Gate()
        let counter = Counter()
        await h.llm.setOnExtract { email in
            guard email.id == "old-1@fixture", await counter.next() == 1 else { return }
            await entered.fire()
            try await Task.sleep(for: .seconds(60)) // only ends by cancellation
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await entered.wait()
        if usePauseNow { await h.runner.pauseNow() } else { await h.runner.stop() }
        await h.runner.waitUntilIdle()

        let stuck = try #require(await h.store.allItems().first { $0.messageID == "old-1@fixture" })
        #expect(stuck.state == .queued && stuck.lastError == nil)
        let job = try await h.job()
        // Q15: Pause now leaves the job paused; Stop records an explicit `.stopped`.
        #expect(job.state == (usePauseNow ? .paused : .stopped) && job.autoPaused == false && job.pauseReason == nil)
        #expect(await h.store.processedIDs() == ["old-0@fixture"])
        #expect(job.totals == JobTotals(queued: 2, done: 1, failed: 0, skipped: 0))

        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()
        let items = await h.store.allItems()
        #expect(items.allSatisfy { $0.state == .done })
        // Q22: a cancelled in-flight email is not charged an attempt.
        #expect(items.first { $0.messageID == "old-1@fixture" }?.attempts == 0)
        #expect(try await h.job().state == .finished)
    }

    // MARK: 10 Daily before Backlog

    @Test func dailyPausesBacklogThenBacklogResumes() async throws {
        let source = FixtureMailSource(messages: try FixtureLoader.loadEmails() + oldMessages(12))
        let store = InMemoryDigestStore()
        let llm = StubLLMClient(results: try FixtureLoader.loadResultsByEmailID())
        let h = Harness(source: source, llm: llm, store: store)
        await h.collector.attach(h.runner.progress)
        let runner = h.runner
        let collector = h.collector
        let dailyTask = Box<Task<Void, Error>>()
        // Waited on, not polled: under a full parallel test run the loop can take longer than `eventually` allows.
        let dailyTaskCreated = Gate()
        let backlogWasAutoPaused = Box<Bool>()
        await llm.setOnExtract { email in
            if email.id == "old-4@fixture" {
                // startDaily waits for this very email to settle, so it must not be awaited here.
                dailyTask.value = Task { try await runner.startDaily() }
                await dailyTaskCreated.fire()
                // The .pausing event can only appear after startDaily sets pauseRequested (the flag is set
                // before emit), so waiting for it stops the loop right after old-4 instead of racing on.
                _ = await eventually { await collector.events.contains { $0.kind == .backlog && $0.state == .pausing } }
            } else if !email.id.hasPrefix("old-"), backlogWasAutoPaused.value == nil {
                let backlog = try await store.jobs().first { $0.kind == .backlog }
                backlogWasAutoPaused.value = backlog?.state == .paused && backlog?.autoPaused == true
                    && backlog?.pauseReason == .dailyJob
            }
        }

        try await h.runner.start(h.plan(boxes: [icloud], to: today.addingTimeInterval(-5 * 86_400)))
        await dailyTaskCreated.wait()
        try await #require(dailyTask.value).value
        await h.runner.waitUntilIdle()

        #expect(backlogWasAutoPaused.value == true)
        #expect(try await store.jobs().first { $0.kind == .backlog }?.pauseReason == nil)
        let order = await llm.extractCalls.map(\.id)
        let old = (0..<12).map { "old-\($0)@fixture" }
        #expect(order.prefix(5) == old.prefix(5))
        let fixtureIDs = Set(try FixtureLoader.loadEmails().map(\.id))
        #expect(Set(order[5..<23]) == fixtureIDs)
        #expect(Array(order[23...]) == Array(old[5...]))
        #expect(Set(order).count == 30)

        let jobs = try await store.jobs()
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .finished })
        let backlog = try #require(jobs.first { $0.kind == .backlog })
        #expect(backlog.autoPaused == false && backlog.totals.done == 12)
        #expect(try #require(jobs.first { $0.kind == .daily }).totals.done == 18)
        #expect(await store.allDigests().count == 2)
        #expect(await eventually { await h.collector.events.last?.state == .finished })
        let events = await h.collector.events
        #expect(events.contains { $0.kind == .backlog && $0.state == .paused })
    }

    @Test func startWhileRunningThrows() async throws {
        let source = FixtureMailSource(messages: oldMessages(2))
        let h = Harness(source: source, llm: StubLLMClient())
        let entered = Gate()
        let release = Gate()
        await h.llm.setOnExtract { _ in await entered.fire(); await release.wait() }
        // A running Daily job can't be interrupted; only a Backlog job is auto-paused by startDaily.
        try await h.runner.start(h.plan(kind: .daily, boxes: [icloud]))
        await entered.wait()
        await #expect(throws: JobRunnerError.alreadyRunning) { try await h.runner.start(h.plan(boxes: [icloud])) }
        await #expect(throws: JobRunnerError.alreadyRunning) { try await h.runner.startDaily() }
        await release.fire()
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }

    // MARK: 11 Progress stream

    @Test func progressEmitsStateChangesAndThrottles() async throws {
        let h = try await Harness.fixtures()
        try await h.runner.start(h.plan())
        await h.runner.waitUntilIdle()
        #expect(await eventually { await h.collector.events.last?.state == .finished })
        let events = await h.collector.events
        // The clock never advances, so only state changes and job end get through.
        #expect(events.map(\.state) == [.listing, .running, .finished])
        let end = try #require(events.last)
        #expect(end.done == 18 && end.total == 18 && end.failed == 0 && end.stage == .saving)
        #expect(end.countsByMailbox == [icloud: MailboxProgress(done: 12, total: 12), outlook: MailboxProgress(done: 6, total: 6)])
    }

    @Test func progressReportsSpeedAndEtaWhenClockAdvances() async throws {
        let source = FixtureMailSource(messages: oldMessages(6))
        let h = Harness(source: source, llm: StubLLMClient())
        await h.collector.attach(h.runner.progress)
        let clock = h.clock
        await h.llm.setOnExtract { _ in clock.advance(by: 2) }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(await eventually { await h.collector.events.last?.state == .finished })

        let events = await h.collector.events
        #expect(events.count > 6)
        #expect(events.map(\.done) == events.map(\.done).sorted())
        let running = try #require(events.first { $0.done == 3 && $0.state == .running && $0.current == nil })
        #expect(running.avgSecondsPerEmail == 2)
        #expect(running.eta == 6) // 3 left at 2 s each
        #expect(running.lastFinished?.position == 3)
        #expect(running.nextUp?.messageID == "old-3@fixture")
    }
}


// MARK: T19 resource pauses and stop

@Suite struct JobRunnerResourceTests {
    private func harness(_ count: Int = 6) -> Harness {
        Harness(source: FixtureMailSource(messages: oldMessages(count)), llm: StubLLMClient())
    }

    @Test func autoPauseRecordsReasonAndAutoResumeWaitsForItToClear() async throws {
        let h = harness()
        await h.collector.attach(h.runner.progress)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-2@fixture" { await runner.autoPause(.battery) }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        let paused = try await h.job()
        #expect(paused.state == .paused && paused.autoPaused && paused.pauseReason == .battery)
        #expect(paused.totals.done == 3 && paused.totals.queued == 3)
        #expect(await eventually { await h.collector.events.last?.pauseReason == .battery })

        // Still on battery: nothing resumes.
        #expect(try await h.runner.autoResume(blocked: [.backlog: .battery]) == nil)
        #expect(try await h.job().state == .paused)
        // A different kind being blocked doesn't matter for a Backlog job.
        let resumed = try await h.runner.autoResume(blocked: [.daily: .lowPowerMode])
        #expect(resumed == paused.id)
        await h.runner.waitUntilIdle()
        let done = try await h.job()
        #expect(done.state == .finished && done.pauseReason == nil && done.totals.done == 6)
        // Each email was processed exactly once.
        #expect(await h.llm.extractCalls.map(\.id).count == 6)
    }

    @Test func userPausedJobIsNeverAutoResumed() async throws {
        let h = harness(4)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.pause() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        let paused = try await h.job()
        #expect(paused.state == .paused && paused.pauseReason == nil)
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
        #expect(try await h.job().state == .paused)
    }

    @Test func stoppedJobIsNeverAutoResumedAndNeedsAnExplicitResume() async throws {
        let h = harness(4)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.stop() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        let stopped = try await h.job()
        #expect(stopped.state == .stopped)
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
        // Resuming "the most recent paused job" ignores stopped ones.
        try await h.runner.resume()
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .stopped)

        await h.llm.setOnExtract { _ in }
        try await h.runner.resume(jobID: stopped.id)
        await h.runner.waitUntilIdle()
        let finished = try await h.job()
        #expect(finished.state == .finished && finished.totals.done == 4)
    }

    @Test func dailyJobPauseAndEarlierSessionPausesAreNotAutoResumed() async throws {
        let h = harness(2)
        var job = Job(id: UUID(), kind: .backlog, mailboxes: [icloud], scopeFrom: today, scopeTo: today,
                      state: .paused, createdAt: today,
                      totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: true,
                      pauseReason: .dailyJob)
        try await h.store.createJob(job)
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
        // Paused for battery in a previous session: this runner didn't pause it, so it waits for the user.
        job.pauseReason = .battery
        try await h.store.updateJob(job)
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
    }

    @Test func interruptedStopRecoversAsStopped() async throws {
        let h = harness(2)
        let stopping = Job(id: UUID(), kind: .backlog, mailboxes: [icloud], scopeFrom: today, scopeTo: today,
                           state: .stopping, createdAt: today,
                           totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        let running = Job(id: UUID(), kind: .backlog, mailboxes: [icloud], scopeFrom: today, scopeTo: today,
                          state: .running, createdAt: today.addingTimeInterval(1),
                          totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        try await h.store.createJob(stopping)
        try await h.store.createJob(running)
        try await h.runner.recoverOnLaunch()
        let jobs = try await h.store.jobs()
        #expect(jobs.first { $0.id == stopping.id }?.state == .stopped)
        #expect(jobs.first { $0.id == running.id }?.state == .paused)
    }

    @Test func applyResourceRulesPausesTheActiveBacklogJob() async throws {
        let h = harness(5)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" {
                // A blocked Daily kind must not touch a Backlog job; a blocked Backlog kind pauses it.
                try await runner.applyResourceRules([.daily: .lowPowerMode])
                try await runner.applyResourceRules([.backlog: .heat])
            }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        let job = try await h.job()
        #expect(job.state == .paused && job.pauseReason == .heat && job.totals.done == 2)
    }
}

// MARK: - Refresh before resuming a Daily job, and resource rules on Start/Resume (Q43)

private let archive = MailboxRef(account: "iCloud", name: "Archive")
private let elsewhere = MailboxRef(account: "iCloud", name: "Receipts")

/// Recent mail in iCloud Inbox, inside the Daily window (newest first: recent-0 is the newest).
private func recentMessages(_ count: Int) -> [EmailMessage] {
    (0..<count).map { n in
        EmailMessage(id: "recent-\(n)@fixture", account: "iCloud", mailbox: "Inbox",
                     sender: "Sam <sam@example.com>", subject: "Recent \(n)",
                     receivedAt: today.addingTimeInterval(-3600 * Double(n + 1)),
                     body: "Hello. Please reply by Friday.", headers: [:])
    }
}

@Suite struct JobRunnerResumeRefreshTests {
    /// A Daily job over Inbox and Archive, paused by the user after its first email.
    private func pausedDaily(_ count: Int = 5) async throws -> (Harness, Job) {
        let h = Harness(source: FixtureMailSource(messages: recentMessages(count)), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud, archive]))
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "recent-0@fixture" { await runner.pause() }
        }
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        #expect(job.kind == .daily && job.state == .paused && job.totals.done == 1)
        return (h, job)
    }

    private func item(_ h: Harness, _ id: String) async throws -> JobItem {
        try #require(await h.store.allItems().first { $0.messageID == id })
    }

    @Test func resumeSkipsDeletedAndMovedOutMailKeepsTheRestAndFollowsMoves() async throws {
        let (h, job) = try await pausedDaily()
        let doneBefore = try await item(h, "recent-0@fixture")
        await h.source.removeMessage(id: "recent-1@fixture")                // deleted
        await h.source.moveMessage(id: "recent-2@fixture", to: elsewhere)   // moved outside the job
        await h.source.moveMessage(id: "recent-3@fixture", to: archive)     // moved between selected mailboxes
        // recent-4 is unchanged.

        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()

        for gone in ["recent-1@fixture", "recent-2@fixture"] {
            let i = try await item(h, gone)
            #expect(i.state == .skipped && i.outcome == JobRunner.goneFromMailboxOutcome)
            #expect(i.attempts == 0 && i.lastError == nil)
            #expect(!(await h.store.processedIDs().contains(gone)))
        }
        let calls = await h.llm.extractCalls.map(\.id)
        #expect(calls == ["recent-0@fixture", "recent-3@fixture", "recent-4@fixture"])
        let moved = try await item(h, "recent-3@fixture")
        #expect(moved.state == .done && moved.mailbox.name == "Archive")
        #expect(try await item(h, "recent-4@fixture").mailbox == icloud)
        // The finished item and its result are untouched.
        #expect(try await item(h, "recent-0@fixture") == doneBefore)
        let finished = try await h.job(job.id)
        #expect(finished.state == .finished)
        #expect(finished.totals == JobTotals(queued: 0, done: 3, failed: 0, skipped: 2))
        // Gone mail leaves no result in the review digest.
        let digest = try await h.digest()
        #expect(Set(digest.info.map(\.emailID)) == ["recent-0@fixture", "recent-3@fixture", "recent-4@fixture"])
        #expect(digest.skipped.isEmpty)
    }

    @Test func listingFailureAbortsResumeAndKeepsTheQueue() async throws {
        let (h, job) = try await pausedDaily()
        let before = await h.store.allItems()
        await h.source.removeMessage(id: "recent-1@fixture")
        await h.source.setListingFails(true, for: archive)

        await #expect(throws: FixtureMailError.listingFailed) { try await h.runner.resume(jobID: job.id) }
        #expect(await h.store.allItems() == before)
        #expect(try await h.job(job.id).state == .paused)
        #expect(await h.llm.extractCalls.count == 1)

        // Once Mail can be read again, the resume goes through.
        await h.source.setListingFails(false, for: archive)
        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()
        #expect(try await item(h, "recent-1@fixture").outcome == JobRunner.goneFromMailboxOutcome)
        #expect(try await h.job(job.id).state == .finished)
    }

    // MARK: Daily discovery

    private func newMail(_ id: String, at date: Date, in box: String = "Inbox") -> EmailMessage {
        EmailMessage(id: id, account: "iCloud", mailbox: box, sender: "Sam <sam@example.com>", subject: id,
                     receivedAt: date, body: "Hello. Please reply by Friday.", headers: [:])
    }

    private func resumeAndFinish(_ h: Harness, _ job: Job) async throws {
        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()
    }

    @Test func dailyResumeDiscoversNewMailInTheSameJobAfterExistingPositions() async throws {
        let (h, job) = try await pausedDaily(3)
        let before = await h.store.allItems()
        let now = today.addingTimeInterval(3600)
        h.clock.set(now)
        await h.source.addMessage(newMail("fresh-a@fixture", at: today.addingTimeInterval(600)))
        await h.source.addMessage(newMail("fresh-b@fixture", at: today.addingTimeInterval(1800)))
        let rangesBefore = await h.source.listRanges.count

        try await resumeAndFinish(h, job)

        let items = await h.store.allItems()
        #expect(items.count == before.count + 2)
        #expect(Set(items.map(\.jobID)) == [job.id])
        let maxOld = before.map(\.position).max() ?? 0
        // Newest first among the new items, positions continue after the existing ones.
        #expect(try await item(h, "fresh-b@fixture").position == maxOld + 1)
        #expect(try await item(h, "fresh-a@fixture").position == maxOld + 2)
        let resumed = try await h.job(job.id)
        #expect(resumed.state == .finished && resumed.scopeFrom == job.scopeFrom && resumed.scopeTo == now)
        #expect(await h.store.allDigests().count == 1)
        #expect(try await h.digest().id == job.id)
        #expect(Set(try await h.digest().info.map(\.emailID)).isSuperset(of: ["fresh-a@fixture", "fresh-b@fixture"]))
        // Discovery window starts at the cursor (the old scope end) and ends at the resume time.
        let discovery = await h.source.listRanges[rangesBefore...].filter { $0.to == now }
        #expect(!discovery.isEmpty)
        #expect(discovery.allSatisfy { $0.from == today })
        #expect(await h.source.checkCalls == 2)
    }

    @Test func dailyDiscoveryNeverLooksBackFurtherThanTheCap() async throws {
        let (h, job) = try await pausedDaily(2)
        let now = today.addingTimeInterval(10 * 86_400)
        h.clock.set(now)
        let rangesBefore = await h.source.listRanges.count
        try await resumeAndFinish(h, job)
        let discovery = await h.source.listRanges[rangesBefore...].filter { $0.to == now }
        #expect(!discovery.isEmpty)
        #expect(discovery.allSatisfy { $0.from == now.addingTimeInterval(-48 * 3600) })
    }

    @Test func reconciliationCoversItemsOlderThanTheNewWindow() async throws {
        let (h, job) = try await pausedDaily(5)
        h.clock.set(today.addingTimeInterval(10 * 86_400))
        await h.source.removeMessage(id: "recent-1@fixture")
        await h.source.moveMessage(id: "recent-3@fixture", to: archive)
        try await resumeAndFinish(h, job)
        #expect(try await item(h, "recent-1@fixture").outcome == JobRunner.goneFromMailboxOutcome)
        #expect(try await item(h, "recent-3@fixture").mailbox.name == "Archive")
        #expect(try await item(h, "recent-3@fixture").state == .done)
        #expect(try await item(h, "recent-4@fixture").state == .done)
    }

    @Test func discoveryNeverReaddsMailAlreadyInTheJobProcessedOrQueuedElsewhere() async throws {
        let (h, job) = try await pausedDaily(3)
        await h.source.removeMessage(id: "recent-1@fixture")
        // Gone from the old window but reappearing in the new one: it is already an item of this job.
        await h.source.addMessage(newMail("recent-1@fixture", at: today.addingTimeInterval(4000)))
        await h.source.addMessage(newMail("recent-0@fixture", at: today.addingTimeInterval(4100)))
        await h.source.addMessage(newMail("elsewhere@fixture", at: today.addingTimeInterval(4200)))
        await h.source.addMessage(newMail("processed@fixture", at: today.addingTimeInterval(4300)))
        try await h.store.markProcessed(ProcessedEmail(id: "processed@fixture", receivedAt: today, tier: .full,
                                                       processedAt: today))
        let other = Job(id: UUID(), kind: .backlog, mailboxes: [icloud], scopeFrom: today, scopeTo: today,
                        state: .paused, createdAt: today.addingTimeInterval(-5),
                        totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        try await h.store.createJob(other)
        try await h.store.enqueue([MessageHeader(id: "elsewhere@fixture", account: "iCloud", mailbox: "Inbox",
                                                 sender: "x", subject: "x", receivedAt: today,
                                                 sourceReference: MailMessageReference(messageID: "elsewhere@fixture",
                                                                                       storeRowID: nil))], job: other.id)
        h.clock.set(today.addingTimeInterval(7200))
        let before = await h.store.allItems().filter { $0.jobID == job.id }.count

        try await resumeAndFinish(h, job)

        let mine = await h.store.allItems().filter { $0.jobID == job.id }
        #expect(mine.count == before)
        #expect(mine.filter { $0.messageID == "recent-1@fixture" }.count == 1)
        #expect(try await item(h, "recent-1@fixture").state == .skipped)
        #expect(!mine.map(\.messageID).contains("processed@fixture"))
        #expect(!mine.map(\.messageID).contains("elsewhere@fixture"))
        #expect(mine.filter { $0.messageID == "recent-0@fixture" }.count == 1)
    }

    @Test func dailyResumeRespectsTheDailyCapWithoutDroppingQueuedItems() async throws {
        var cfg = settings(mailboxes: [icloud, archive])
        cfg.maxEmailsPerRun = 4
        let h = Harness(source: FixtureMailSource(messages: recentMessages(3)), llm: StubLLMClient(), settings: cfg)
        let runner = h.runner
        await h.llm.setOnExtract { email in if email.id == "recent-0@fixture" { await runner.pause() } }
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        // 2 open items remain, so only 2 of the 3 new emails fit (newest first).
        h.clock.set(today.addingTimeInterval(3600))
        for n in 0..<3 { await h.source.addMessage(newMail("new-\(n)@fixture", at: today.addingTimeInterval(Double(100 * (n + 1))))) }
        try await resumeAndFinish(h, job)
        let ids = Set(await h.store.allItems().map(\.messageID))
        #expect(ids.contains("new-2@fixture") && ids.contains("new-1@fixture") && !ids.contains("new-0@fixture"))
        #expect(ids.count == 5)
    }

    @Test func dailyResumeWithQueueOverTheCapAdmitsNothingNew() async throws {
        let (h, job) = try await pausedDaily(5)   // 4 open
        _ = job
        var cfg = settings(mailboxes: [icloud, archive])
        cfg.maxEmailsPerRun = 2
        let h2 = Harness(source: h.source, llm: h.llm, store: h.store, settings: cfg)
        h2.clock.set(today.addingTimeInterval(3600))
        await h.source.addMessage(newMail("fresh@fixture", at: today.addingTimeInterval(100)))
        // The runner in h2 uses its own clock instance; its "now" is `today`, so only the cap matters here.
        let before = await h.store.allItems().count
        try await h2.runner.resume(jobID: job.id)
        await h2.runner.waitUntilIdle()
        let items = await h.store.allItems()
        #expect(items.count == before)
        #expect(items.filter { $0.state == .done }.count == 5)
    }

    @Test func discoveryListingFailureLeavesEverythingUnchanged() async throws {
        let (h, job) = try await pausedDaily(3)
        let before = await h.store.allItems()
        h.clock.set(today.addingTimeInterval(3600))
        await h.source.addMessage(newMail("fresh@fixture", at: today.addingTimeInterval(600), in: "Archive"))
        // Reconciliation lists Inbox and Archive; fail Archive so the (first) listing errors.
        await h.source.setListingFails(true, for: archive)
        await #expect(throws: FixtureMailError.listingFailed) { try await h.runner.resume(jobID: job.id) }
        #expect(await h.store.allItems() == before)
        #expect(try await h.job(job.id) == job)

        await h.source.setListingFails(false, for: archive)
        try await resumeAndFinish(h, job)
        #expect(try await h.job(job.id).state == .finished)
        #expect(await h.store.allItems().filter { $0.messageID == "fresh@fixture" }.count == 1)
    }

    @Test func listingFailureInDiscoveryOnlyAbortsWithoutPartialChanges() async throws {
        // No open items: reconciliation lists nothing, so the failure is in the discovery listing.
        let h = Harness(source: FixtureMailSource(messages: recentMessages(1)), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud, archive]))
        let runner = h.runner
        await h.llm.setOnExtract { _ in await runner.pause() }
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        #expect(job.state == .paused && job.totals.queued == 0)
        let before = await h.store.allItems()
        h.clock.set(today.addingTimeInterval(3600))
        await h.source.addMessage(newMail("fresh@fixture", at: today.addingTimeInterval(600)))
        await h.source.setListingFails(true, for: archive)
        await #expect(throws: FixtureMailError.listingFailed) { try await h.runner.resume(jobID: job.id) }
        #expect(await h.store.allItems() == before)
        #expect(try await h.job(job.id).scopeTo == job.scopeTo)
        await h.source.setListingFails(false, for: archive)
        try await resumeAndFinish(h, job)
        #expect(try await h.job(job.id).scopeTo == today.addingTimeInterval(3600))
        #expect(await h.store.allItems().map(\.messageID).contains("fresh@fixture"))
    }

    @Test func resumingTwiceNeverDuplicates() async throws {
        let (h, job) = try await pausedDaily(2)
        h.clock.set(today.addingTimeInterval(3600))
        await h.source.addMessage(newMail("fresh@fixture", at: today.addingTimeInterval(600)))
        try await resumeAndFinish(h, job)
        let count = await h.store.allItems().count
        h.clock.set(today.addingTimeInterval(7200))
        try await resumeAndFinish(h, job)
        #expect(await h.store.allItems().count == count)
    }

    @Test func anotherUnresolvedDailyJobSkipsDiscovery() async throws {
        let (h, job) = try await pausedDaily(2)
        let other = Job(id: UUID(), kind: .daily, mailboxes: [icloud], scopeFrom: today, scopeTo: today,
                        state: .stopped, createdAt: today.addingTimeInterval(-1),
                        totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        try await h.store.createJob(other)
        h.clock.set(today.addingTimeInterval(3600))
        await h.source.addMessage(newMail("fresh@fixture", at: today.addingTimeInterval(600)))
        try await resumeAndFinish(h, job)
        #expect(!(await h.store.allItems().map(\.messageID).contains("fresh@fixture")))
        #expect(try await h.job(job.id).scopeTo == job.scopeTo)
    }

    // MARK: Backlog reconciliation

    @Test func backlogResumeReconcilesOverItsScopeOnlyAndAddsNothing() async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(4)), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud, archive]))
        let runner = h.runner
        await h.llm.setOnExtract { email in if email.id == "old-0@fixture" { await runner.pause() } }
        let plan = h.plan(boxes: [icloud, archive])
        try await h.runner.start(plan)
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        await h.source.removeMessage(id: "old-1@fixture")
        await h.source.moveMessage(id: "old-2@fixture", to: archive)
        // Arrives inside the scope after queueing, and later than the scope; neither is appended.
        await h.source.addMessage(newMail("late-in@fixture", at: today.addingTimeInterval(-86_400)))
        await h.source.addMessage(newMail("late-after@fixture", at: today.addingTimeInterval(30)))
        let calls = await h.source.listCalls
        h.clock.set(today.addingTimeInterval(3600))

        try await h.runner.resume()
        await h.runner.waitUntilIdle()

        #expect(await h.source.listCalls > calls)
        #expect(await h.source.checkCalls == 0)
        let ranges = await h.source.listRanges.dropFirst(calls)
        #expect(ranges.allSatisfy { $0.from <= job.scopeFrom && $0.to >= job.scopeTo && $0.to < today.addingTimeInterval(3600) })
        #expect(try await item(h, "old-1@fixture").outcome == JobRunner.goneFromMailboxOutcome)
        #expect(try await item(h, "old-1@fixture").attempts == 0)
        #expect(try await item(h, "old-2@fixture").mailbox.name == "Archive")
        let ids = await h.store.allItems().map(\.messageID)
        #expect(!ids.contains("late-in@fixture") && !ids.contains("late-after@fixture"))
        let done = try await h.job(job.id)
        #expect(done.scopeFrom == job.scopeFrom && done.scopeTo == job.scopeTo && done.state == .finished)
    }

    @Test func backlogListingFailureLeavesTheQueueUnchanged() async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(3)), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud, archive]))
        let runner = h.runner
        await h.llm.setOnExtract { email in if email.id == "old-0@fixture" { await runner.pause() } }
        try await h.runner.start(h.plan(boxes: [icloud, archive]))
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let before = await h.store.allItems()
        let job = try await h.job()
        await h.source.removeMessage(id: "old-1@fixture")
        await h.source.setListingFails(true, for: archive)
        await #expect(throws: FixtureMailError.listingFailed) { try await h.runner.resume() }
        #expect(await h.store.allItems() == before)
        #expect(try await h.job() == job)
    }
}

@Suite struct JobRunnerResourceStartTests {
    private func harness(_ count: Int = 4) -> Harness {
        Harness(source: FixtureMailSource(messages: oldMessages(count)), llm: StubLLMClient())
    }

    @Test func backlogStartedWhileBlockedIsStoredPausedBeforeAnyEmail() async throws {
        let h = harness()
        await h.collector.attach(h.runner.progress)
        await h.runner.setResourceBlockers([.backlog: .battery])
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()

        #expect(await h.llm.extractCalls.isEmpty)
        let job = try await h.job()
        #expect(job.state == .paused && job.autoPaused && job.pauseReason == .battery)
        #expect(job.totals == JobTotals(queued: 4, done: 0, failed: 0, skipped: 0))
        #expect(await eventually { await h.collector.events.last?.state == .paused })
        #expect(await h.collector.events.last?.nextUp?.messageID == "old-0@fixture")

        // Still blocked: nothing runs. Once the rule clears it auto-resumes in this session (Q44).
        #expect(try await h.runner.autoResume(blocked: [.backlog: .battery]) == nil)
        #expect(try await h.runner.autoResume(blocked: [:]) == job.id)
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
        #expect(await h.llm.extractCalls.count == 4)
    }

    @Test func manualResumeWhileBlockedStaysPausedAndSaysWhy() async throws {
        let h = harness()
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { await runner.pause() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()

        await h.runner.setResourceBlockers([.backlog: .quietHours])
        await #expect(throws: JobRunnerError.resourceBlocked(.quietHours)) { try await h.runner.resume(jobID: job.id) }
        let parked = try await h.job()
        #expect(parked.state == .paused && parked.pauseReason == .quietHours && parked.autoPaused)
        #expect(await h.llm.extractCalls.count == 1)

        // Mandatory rules apply as well.
        await h.runner.setResourceBlockers([.backlog: .lowPowerMode])
        await #expect(throws: JobRunnerError.resourceBlocked(.lowPowerMode)) { try await h.runner.resume() }

        #expect(try await h.runner.autoResume(blocked: [:]) == job.id)
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }

    @Test func blockedResumeOfAStoppedJobKeepsItStopped() async throws {
        let h = harness()
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { await runner.stop() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        let job = try await h.job()
        await h.runner.setResourceBlockers([.backlog: .battery])
        await #expect(throws: JobRunnerError.resourceBlocked(.battery)) { try await h.runner.resume(jobID: job.id) }
        #expect(try await h.job().state == .stopped)
        // Q48: never resumed automatically.
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
    }

    @Test func resumeCannotWithdrawAPendingPauseWhileBlocked() async throws {
        let h = harness()
        let runner = h.runner
        let threw = Box<Bool>()
        await h.llm.setOnExtract { email in
            guard email.id == "old-0@fixture" else { return }
            await runner.pause()
            await runner.setResourceBlockers([.backlog: .heat])
            do { try await runner.resume() } catch JobRunnerError.resourceBlocked(.heat) { threw.value = true }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(threw.value == true)
        let job = try await h.job()
        #expect(job.state == .paused && job.pauseReason == .heat && job.totals.done == 1)
    }

    @Test func dailyFollowsItsOwnRules() async throws {
        let h = Harness(source: FixtureMailSource(messages: recentMessages(2)), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud]))
        // Battery and the run window only apply to Backlog jobs.
        await h.runner.setResourceBlockers([.backlog: .battery])
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)

        // Low Power Mode applies to Daily as well (the policy blocks the .daily kind).
        let lpm = Harness(source: FixtureMailSource(messages: recentMessages(2)), llm: StubLLMClient(),
                          settings: settings(mailboxes: [icloud]))
        await lpm.runner.setResourceBlockers([.daily: .lowPowerMode, .backlog: .lowPowerMode])
        try await lpm.runner.startDaily()
        await lpm.runner.waitUntilIdle()
        let parked = try await lpm.job()
        #expect(parked.kind == .daily && parked.state == .paused && parked.pauseReason == .lowPowerMode)
        #expect(await lpm.llm.extractCalls.isEmpty)
    }

    @Test func backlogHandOffAfterDailyRespectsANewBlocker() async throws {
        let source = FixtureMailSource(messages: recentMessages(2) + oldMessages(6))
        let h = Harness(source: source, llm: StubLLMClient(), settings: settings(mailboxes: [icloud]))
        let runner = h.runner
        let dailyTask = Box<Task<Void, Error>>()
        // Waited on, not polled: under a full parallel test run the loop can take longer than `eventually` allows.
        let dailyTaskCreated = Gate()
        let collector = h.collector
        await h.collector.attach(h.runner.progress)
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" {
                dailyTask.value = Task { try await runner.startDaily() }
                await dailyTaskCreated.fire()
                _ = await eventually { await collector.events.contains { $0.kind == .backlog && $0.state == .pausing } }
            } else if email.id.hasPrefix("recent-") {
                // The Mac goes on battery while the Daily job runs.
                await runner.setResourceBlockers([.backlog: .battery])
            }
        }
        try await h.runner.start(h.plan(boxes: [icloud], to: today.addingTimeInterval(-5 * 86_400)))
        await dailyTaskCreated.wait()
        try await #require(dailyTask.value).value
        await h.runner.waitUntilIdle()

        let jobs = try await h.store.jobs()
        #expect(try #require(jobs.first { $0.kind == .daily }).state == .finished)
        let backlog = try #require(jobs.first { $0.kind == .backlog })
        #expect(backlog.state == .paused && backlog.pauseReason == .battery && backlog.totals.done == 2)
        #expect(try await h.runner.autoResume(blocked: [:]) == backlog.id)
        await h.runner.waitUntilIdle()
        #expect(try await h.job(backlog.id).state == .finished)
    }
}

/// Q52: at most one unresolved Daily job; the runner never creates a second one or resumes one by itself.
@Suite struct JobRunnerDailyLifecycleTests {
    private func harness(_ messages: [EmailMessage]) async -> Harness {
        let h = Harness(source: FixtureMailSource(messages: messages), llm: StubLLMClient(),
                        settings: settings(mailboxes: [icloud]))
        await h.collector.attach(h.runner.progress)
        return h
    }

    /// A Daily job over four recent emails that `interrupt` pauses or stops after the first one.
    private func interruptedDaily(_ interrupt: @escaping @Sendable (JobRunner) async -> Void,
                                  messages: [EmailMessage] = recentMessages(4)) async throws -> (Harness, Job) {
        let h = await harness(messages)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "recent-0@fixture" { await interrupt(runner) }
        }
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let job = try await h.job()
        // Pause finishes the email in flight; Stop cancels it and puts it back in the queue.
        #expect(job.kind == .daily && job.totals.done + job.totals.queued == 4 && job.totals.queued >= 3)
        return (h, job)
    }

    private func lifecycle(_ h: Harness) async throws -> DailyLifecycle {
        DailyLifecycle(jobs: try await h.store.jobs())
    }

    private func storedJob(_ state: JobState, kind: JobKind = .daily, queued: Int = 1, failed: Int = 0,
                           created: Date = today) -> Job {
        Job(id: UUID(), kind: kind, mailboxes: [icloud], scopeFrom: created.addingTimeInterval(-3600),
            scopeTo: created, state: state, createdAt: created,
            totals: JobTotals(queued: queued, done: 0, failed: failed, skipped: 0), autoPaused: false)
    }

    @Test func withNoUnresolvedDailyJobRunNowCreatesOne() async throws {
        let h = await harness(recentMessages(2))
        #expect(try await lifecycle(h).menuAction.behavior == .startNew)
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let jobs = try await h.store.jobs()
        #expect(jobs.count == 1 && jobs[0].kind == .daily && jobs[0].state == .finished)
        // A finished Daily job is history, so Run Now is offered again.
        #expect(try await lifecycle(h) == .none)
    }

    @Test func pausedDailyResumesTheSameJobAndNeverRepeatsAnEmail() async throws {
        let (h, paused) = try await interruptedDaily { await $0.pause() }
        #expect(paused.state == .paused)
        let state = try await lifecycle(h)
        #expect(state == .paused(paused))
        #expect(state.menuAction.behavior == .resume(paused.id))

        // Run Now can't be used to get around it.
        let itemsBefore = await h.store.allItems()
        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.startDaily() }
        await #expect(throws: JobRunnerError.dailyJobUnresolved) {
            try await h.runner.start(h.plan(kind: .daily, boxes: [icloud]))
        }
        #expect(try await h.store.jobs().map(\.id) == [paused.id])

        try await h.runner.resume(jobID: paused.id)
        await h.runner.waitUntilIdle()
        let jobs = try await h.store.jobs()
        #expect(jobs.map(\.id) == [paused.id])
        #expect(jobs[0].state == .finished && jobs[0].totals.done == 4)
        // Same queue: nothing enqueued again, and every email went to the model exactly once.
        let itemsAfter = await h.store.allItems()
        #expect(Set(itemsAfter.map(\.id)) == Set(itemsBefore.map(\.id)))
        let calls = await h.llm.extractCalls.map(\.id)
        #expect(calls.count == 4 && Set(calls).count == 4)
        #expect(try await lifecycle(h) == .none)
    }

    @Test func runningDailyBlocksAnotherDailyJob() async throws {
        let h = await harness(recentMessages(2))
        let entered = Gate()
        let release = Gate()
        await h.llm.setOnExtract { _ in await entered.fire(); await release.wait() }
        try await h.runner.startDaily()
        await entered.wait()
        let running = try await lifecycle(h)
        if case .running = running {} else { Issue.record("expected running, got \(running)") }
        #expect(running.menuAction == .running)
        await #expect(throws: JobRunnerError.alreadyRunning) { try await h.runner.startDaily() }
        await #expect(throws: JobRunnerError.alreadyRunning) {
            try await h.runner.start(h.plan(kind: .daily, boxes: [icloud]))
        }
        await release.fire()
        await h.runner.waitUntilIdle()
        #expect(try await h.store.jobs().count == 1)
    }

    @Test func stoppedDailyIsNeitherResumedNorReplaced() async throws {
        let (h, stopped) = try await interruptedDaily { await $0.stop() }
        #expect(stopped.state == .stopped)
        #expect(try await lifecycle(h).menuAction.behavior == .review)

        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.startDaily() }
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
        try await h.runner.resume()
        await h.runner.waitUntilIdle()
        let job = try await h.job()
        #expect(try await h.store.jobs().count == 1)
        #expect(job.state == .stopped && job.totals.queued == 4)
        #expect(await h.store.allItems().filter { $0.state == .queued }.count == 4)

        // Q48: an explicit Resume from Past Jobs continues it.
        try await h.runner.resume(jobID: stopped.id)
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
        #expect(try await lifecycle(h) == .none)
    }

    @Test func stoppingAPausedDailyStoresItStoppedWithItsQueue() async throws {
        let (h, paused) = try await interruptedDaily { await $0.pause() }
        try await h.runner.stopPaused(jobID: paused.id)
        let job = try await h.job()
        #expect(job.state == .stopped && job.totals.queued == 3 && job.pauseReason == nil)
        #expect(try await h.runner.autoResume(blocked: [:]) == nil)
        #expect(try await lifecycle(h) == .stopped(job))
    }

    @Test func failedDailyKeepsTheRetryPathAndIsNotReplaced() async throws {
        let h = await harness(recentMessages(3))
        let llm = h.llm
        await llm.setOnExtract { email in
            if email.id == "recent-1@fixture" {
                await llm.setHealthy(false)
                throw LLMError.unreachable("connection refused")
            }
        }
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let failed = try await h.job()
        #expect(failed.state == .failed && failed.totals.queued == 2)
        #expect(try await lifecycle(h).menuAction.behavior == .retry(failed.id))

        await llm.setOnExtract(nil)
        await llm.setHealthy(true)
        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.startDaily() }
        #expect(try await h.store.jobs().count == 1)

        // Q25: Retry resumes the same job by id.
        try await h.runner.resume(jobID: failed.id)
        await h.runner.waitUntilIdle()
        let jobs = try await h.store.jobs()
        #expect(jobs.map(\.id) == [failed.id] && jobs[0].state == .finished)
        #expect(await h.llm.extractCalls.map(\.id).filter { $0 == "recent-0@fixture" }.count == 1)
    }

    @Test func multipleUnresolvedDailyJobsAreKeptAndNothingIsAdded() async throws {
        let h = await harness(recentMessages(2))
        let older = storedJob(.paused, created: today.addingTimeInterval(-2 * 86_400))
        let newer = storedJob(.stopped, created: today.addingTimeInterval(-86_400))
        var withFailures = storedJob(.finished, queued: 0, failed: 1, created: today.addingTimeInterval(-3 * 86_400))
        withFailures.totals.done = 1
        for job in [older, newer, withFailures] { try await h.store.createJob(job) }

        let state = try await lifecycle(h)
        #expect(state == .conflict([newer, older]))
        #expect(state.menuAction.behavior == .review)
        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.startDaily() }
        // Retry Failed would turn a third Daily job back into unresolved work.
        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.retryFailed(jobID: withFailures.id) }
        let jobs = try await h.store.jobs()
        #expect(jobs.count == 3)
        #expect(jobs.first { $0.id == older.id }?.state == .paused)
        #expect(jobs.first { $0.id == newer.id }?.state == .stopped)
        #expect(jobs.first { $0.id == withFailures.id }?.state == .finished)
    }

    @Test func pausedBacklogDoesNotReplaceTheDailyAction() async throws {
        let h = await harness(recentMessages(2))
        let backlog = storedJob(.paused, kind: .backlog, queued: 5, created: today.addingTimeInterval(-600))
        try await h.store.createJob(backlog)
        #expect(try await lifecycle(h).menuAction.behavior == .startNew)
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let jobs = try await h.store.jobs()
        #expect(jobs.first { $0.kind == .daily }?.state == .finished)
        // A user-paused Backlog job is not resumed by the Daily run (Q46).
        #expect(jobs.first { $0.id == backlog.id }?.state == .paused)
    }

    @Test func resumingAPausedDailyPreemptsARunningBacklogThenHandsBack() async throws {
        let (h, paused) = try await interruptedDaily({ await $0.pause() },
                                                      messages: recentMessages(4) + oldMessages(8))
        let runner = h.runner
        let collector = h.collector
        let resumeTask = Box<Task<Void, Error>>()
        // Waited on, not polled: under a full parallel test run the loop can take longer than `eventually` allows.
        let resumeTaskCreated = Gate()
        await h.llm.setOnExtract { email in
            if email.id == "old-2@fixture" {
                resumeTask.value = Task { try await runner.resume(jobID: paused.id) }
                await resumeTaskCreated.fire()
                _ = await eventually { await collector.events.contains { $0.kind == .backlog && $0.state == .pausing } }
            }
        }
        try await h.runner.start(h.plan(boxes: [icloud], to: today.addingTimeInterval(-5 * 86_400)))
        await resumeTaskCreated.wait()
        try await #require(resumeTask.value).value
        await h.runner.waitUntilIdle()

        let jobs = try await h.store.jobs()
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .finished })
        #expect(jobs.first { $0.kind == .daily }?.id == paused.id)
        #expect(await h.collector.events.contains { $0.kind == .backlog && $0.state == .paused })
        let calls = await h.llm.extractCalls.map(\.id)
        #expect(calls.count == 12 && Set(calls).count == 12)
    }

    @Test func afterResolvingTheDailyJobTheNextOneStartsAtTheCursor() async throws {
        let (h, paused) = try await interruptedDaily { await $0.pause() }
        try await h.runner.resume(jobID: paused.id)
        await h.runner.waitUntilIdle()

        h.clock.set(today.addingTimeInterval(3600))
        try await h.runner.startDaily()
        await h.runner.waitUntilIdle()
        let jobs = try await h.store.jobs()
        #expect(jobs.count == 2)
        let next = try #require(jobs.first { $0.id != paused.id })
        // Q23: max(lastDailyScopeTo, now - lookbackCap), unchanged.
        #expect(next.kind == .daily && next.scopeFrom == paused.scopeTo)
        #expect(next.scopeTo == today.addingTimeInterval(3600))
    }

    @Test(arguments: [(JobState.running, JobState.paused), (.listing, .paused), (.pausing, .paused), (.stopping, .stopped)])
    func stateIsRestoredAfterRelaunch(interrupted: JobState, recovered: JobState) async throws {
        let store = InMemoryDigestStore()
        try await store.createJob(storedJob(interrupted, queued: 2))
        // A new runner on the same store, as after a quit or crash.
        let h = Harness(source: FixtureMailSource(messages: recentMessages(2)), llm: StubLLMClient(), store: store,
                        settings: settings(mailboxes: [icloud]))
        try await h.runner.recoverOnLaunch()
        let job = try await h.job()
        #expect(job.state == recovered)
        let state = try await lifecycle(h)
        #expect(state.menuAction.behavior == (recovered == .paused ? .resume(job.id) : .review))
        await #expect(throws: JobRunnerError.dailyJobUnresolved) { try await h.runner.startDaily() }
        #expect(try await store.jobs().count == 1)
    }
}

/// T29: lifecycle events emitted at the real transitions, written with the job-state change.
@Suite struct JobRunnerLifecycleEventTests {
    private func harness(_ count: Int = 4, failures: [String: Int] = [:]) -> Harness {
        Harness(source: FixtureMailSource(messages: oldMessages(count)), llm: StubLLMClient(failures: failures))
    }

    private func events(_ h: Harness) async throws -> [JobEvent] {
        try await h.store.jobEvents(job: try await h.job().id)
    }

    private func kinds(_ h: Harness) async throws -> [JobEventKind] { try await events(h).map(\.kind) }

    @Test func normalCompletion() async throws {
        let h = harness()
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(try await kinds(h) == [.created, .started, .completed])
        let job = try await h.job()
        #expect(job.startedAt == today && job.endedAt == today)
        // Per-email work and progress never write events.
        #expect(try await events(h).count == 3)
    }

    @Test func completionWithFailuresCarriesTheCount() async throws {
        let h = harness(3, failures: ["old-0@fixture": Int.max])
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        let all = try await events(h)
        #expect(all.map(\.kind) == [.created, .started, .completedWithFailures])
        #expect(all.last?.payload.count == 1)
    }

    @Test func pauseThenResume() async throws {
        let h = harness()
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.pause() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        // A second pause while already paused is a no-op.
        await h.runner.pause()
        #expect(try await kinds(h) == [.created, .started, .paused])
        #expect(try await events(h).last?.payload.pauseReason == nil)

        await h.llm.setOnExtract(nil)
        try await h.runner.resume()
        await h.runner.waitUntilIdle()
        let all = try await events(h)
        #expect(all.map(\.kind) == [.created, .started, .paused, .resumed, .completed])
        #expect(all[3].payload.trigger == .user)
    }

    @Test func autoPauseThenAutoResume() async throws {
        let h = harness()
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.autoPause(.battery) }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        _ = try await h.runner.autoResume(blocked: [:])
        await h.runner.waitUntilIdle()
        let all = try await events(h)
        #expect(all.map(\.kind) == [.created, .started, .autoPaused, .resumed, .completed])
        #expect(all[2].payload.pauseReason == .battery)
        #expect(all[3].payload.trigger == .automatic)
    }

    @Test func stopSetsEndedAtAndResumeClearsIt() async throws {
        let h = harness()
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" { await runner.stop() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(try await kinds(h) == [.created, .started, .stopped])
        #expect(try await h.job().endedAt == today)

        await h.llm.setOnExtract(nil)
        // A stopped job only resumes by id.
        try await h.runner.resume(jobID: try await h.job().id)
        await h.runner.waitUntilIdle()
        #expect(try await kinds(h) == [.created, .started, .stopped, .resumed, .completed])
        #expect(try await h.job().endedAt == today)
    }

    @Test func retryFailedRecordsRequestThenResume() async throws {
        let h = harness(3, failures: ["old-0@fixture": Int.max])
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        await h.llm.setFailures([:])
        let job = try await h.job()
        #expect(try await h.runner.retryFailed(jobID: job.id) == 1)
        await h.runner.waitUntilIdle()
        let all = try await events(h)
        #expect(all.map(\.kind) == [.created, .started, .completedWithFailures, .retryRequested, .resumed, .completed])
        #expect(all[3].payload.count == 1)
    }

    @Test func recoverOnLaunchOnlyForInterruptedJobs() async throws {
        let h = harness()
        func job(_ state: JobState, _ offset: TimeInterval) -> Job {
            Job(id: UUID(), kind: .backlog, mailboxes: [icloud], scopeFrom: today, scopeTo: today, state: state,
                createdAt: today.addingTimeInterval(offset),
                totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false)
        }
        // Created before the fixed clock's "now", so event times order as in real use.
        let running = job(.running, -30), paused = job(.paused, -20), stopping = job(.stopping, -10)
        for j in [running, paused, stopping] { try await h.store.createJob(j) }
        try await h.runner.recoverOnLaunch()

        let runningEvents = try await h.store.jobEvents(job: running.id)
        #expect(runningEvents.map(\.kind) == [.created, .recoveredAfterInterruption])
        #expect(runningEvents.last?.payload.trigger == .launch)
        #expect(try await h.store.jobEvents(job: paused.id).map(\.kind) == [.created])
        #expect(try await h.store.jobEvents(job: stopping.id).map(\.kind) == [.created, .recoveredAfterInterruption])
        let stopped = try await h.store.jobs().first { $0.id == stopping.id }
        #expect(stopped?.state == .stopped && stopped?.endedAt == today)
    }

    @Test func itemStartTimeIsRecordedWhenProcessingBegins() async throws {
        let h = harness(2)
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        #expect(await h.store.allItems().allSatisfy { $0.startedAt == today })
    }
}
