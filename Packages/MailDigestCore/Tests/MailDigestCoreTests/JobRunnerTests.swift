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
        let backlogWasAutoPaused = Box<Bool>()
        await llm.setOnExtract { email in
            if email.id == "old-4@fixture" {
                // startDaily waits for this very email to settle, so it must not be awaited here.
                dailyTask.value = Task { try await runner.startDaily() }
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
        _ = await eventually { dailyTask.value != nil }
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

    @Test func resumeNeverExtendsTheScopeOrAddsNewMail() async throws {
        let (h, job) = try await pausedDaily(3)
        let itemsBefore = await h.store.allItems().count
        await h.source.moveMessage(id: "recent-2@fixture", to: archive)
        // Arrived after the job was queued, inside its time range: still not added to this job.
        var late = recentMessages(1)[0]
        late.id = "late@fixture"
        late.receivedAt = today.addingTimeInterval(-60)
        await h.source.addMessage(late)
        try await h.runner.resume(jobID: job.id)
        await h.runner.waitUntilIdle()
        #expect(await h.store.allItems().count == itemsBefore)
        let resumed = try await h.job(job.id)
        #expect(resumed.scopeFrom == job.scopeFrom && resumed.scopeTo == job.scopeTo)
        #expect(!(await h.llm.extractCalls.map(\.id).contains("late@fixture")))
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

    @Test func backlogResumeDoesNotRelist() async throws {
        let h = Harness(source: FixtureMailSource(messages: oldMessages(4)), llm: StubLLMClient())
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { await runner.pause() }
        }
        try await h.runner.start(h.plan(boxes: [icloud]))
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)
        let lists = await h.source.listCalls
        try await h.runner.resume()
        await h.runner.waitUntilIdle()
        #expect(await h.source.listCalls == lists)
        #expect(try await h.job().state == .finished)
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
        let collector = h.collector
        await h.collector.attach(h.runner.progress)
        await h.llm.setOnExtract { email in
            if email.id == "old-1@fixture" {
                dailyTask.value = Task { try await runner.startDaily() }
                _ = await eventually { await collector.events.contains { $0.kind == .backlog && $0.state == .pausing } }
            } else if email.id.hasPrefix("recent-") {
                // The Mac goes on battery while the Daily job runs.
                await runner.setResourceBlockers([.backlog: .battery])
            }
        }
        try await h.runner.start(h.plan(boxes: [icloud], to: today.addingTimeInterval(-5 * 86_400)))
        _ = await eventually { dailyTask.value != nil }
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
