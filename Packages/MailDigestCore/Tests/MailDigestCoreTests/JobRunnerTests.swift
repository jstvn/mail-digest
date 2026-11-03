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
        #expect(finalItems.allSatisfy { $0.state == .done && $0.attempts == 1 })
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
        #expect(items.first { $0.id == crashed.id }?.attempts == 2)
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
        #expect(flaky.state == .done && flaky.attempts == 2)

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
        #expect(job.state == .paused && job.autoPaused == false)
        #expect(await h.store.processedIDs() == ["old-0@fixture"])
        #expect(job.totals == JobTotals(queued: 2, done: 1, failed: 0, skipped: 0))

        try await h.runner.resume()
        await h.runner.waitUntilIdle()
        let items = await h.store.allItems()
        #expect(items.allSatisfy { $0.state == .done })
        #expect(items.first { $0.messageID == "old-1@fixture" }?.attempts == 2)
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
        let dailyTask = Box<Task<Void, Error>>()
        let backlogWasAutoPaused = Box<Bool>()
        await llm.setOnExtract { email in
            if email.id == "old-4@fixture" {
                // startDaily waits for this very email to settle, so it must not be awaited here.
                dailyTask.value = Task { try await runner.startDaily() }
            } else if !email.id.hasPrefix("old-"), backlogWasAutoPaused.value == nil {
                let backlog = try await store.jobs().first { $0.kind == .backlog }
                backlogWasAutoPaused.value = backlog?.state == .paused && backlog?.autoPaused == true
            }
        }

        try await h.runner.start(h.plan(boxes: [icloud], to: today.addingTimeInterval(-5 * 86_400)))
        _ = await eventually { dailyTask.value != nil }
        try await #require(dailyTask.value).value
        await h.runner.waitUntilIdle()

        #expect(backlogWasAutoPaused.value == true)
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
