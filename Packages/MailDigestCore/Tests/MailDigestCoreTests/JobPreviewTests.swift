import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")
private let outlook = MailboxRef(account: "Outlook", name: "Inbox")

private struct PreviewHarness {
    let clock = FixedClock(today)
    let store = InMemoryDigestStore()
    let llm: StubLLMClient
    let runner: JobRunner
    let collector = ProgressCollector()

    init(count: Int, llm: StubLLMClient = StubLLMClient()) {
        let source = FixtureMailSource.generatedInbox(count: count, mailboxes: [icloud, outlook], endingAt: today)
        self.llm = llm
        runner = JobRunner(source: source, llm: llm, store: store, notifier: RecordingNotifier(), clock: clock,
                           settings: RunnerSettings(timeZone: FixtureLoader.timeZone), sleep: { _ in })
    }

    func plan(excluded: Set<String> = [], from: Date = today.addingTimeInterval(-30 * 86_400)) -> JobPlan {
        JobPlan(kind: .backlog, mailboxes: [icloud, outlook], from: from, to: today.addingTimeInterval(60),
                excludedMessageIDs: excluded)
    }

    func markProcessed(_ ids: [String]) async throws {
        for id in ids {
            try await store.markProcessed(ProcessedEmail(id: id, receivedAt: today, tier: .full, processedAt: today))
        }
    }
}

@Suite struct JobPreviewTests {
    @Test func previewOfLargeInboxReportsTotalsAndEstimates() async throws {
        let h = PreviewHarness(count: 3000)
        let done = (0..<10).map { "gen-\($0)@fixture" }
        try await h.markProcessed(done)

        let p = try await h.runner.preview(h.plan())
        #expect(p.mailboxTotals == [icloud: 1500, outlook: 1500])
        #expect(p.totalFound == 3000 && p.alreadyProcessed == 10 && p.excluded == 0)
        #expect(p.toProcess.count == 2990)
        #expect(!p.toProcess.map(\.id).contains("gen-3@fixture"))
        #expect(p.dateRangeFound == today.addingTimeInterval(-600 * 2999)...today)
        // Newest first.
        #expect(p.toProcess.first?.id == "gen-10@fixture")
        #expect(zip(p.toProcess, p.toProcess.dropFirst()).allSatisfy { $0.receivedAt >= $1.receivedAt })

        // The generator makes senders 14...19 of every 20 newsletters or no-reply addresses.
        let bulk = p.toProcess.filter { (Int($0.id.dropFirst(4).prefix { $0 != "@" }) ?? 0) % 20 >= 14 }.count
        #expect(p.estimatedTiers == TierEstimate(skip: 0, infoOnly: bulk, full: 2990 - bulk))
        #expect(bulk > 0)

        #expect(p.estimatedSeconds == 20 * 2990)
        #expect(p.firstItems.count == 200 && p.firstItems == Array(p.toProcess.prefix(200)))

        // List only: no job, no queue.
        #expect(try await h.store.jobs().isEmpty)
        #expect(await h.store.allItems().isEmpty)
    }

    @Test func estimateUsesRollingAverageOfFinishedEmails() async throws {
        let h = PreviewHarness(count: 40)
        let clock = h.clock
        await h.llm.setOnExtract { _ in clock.advance(by: 10) }
        // Only the newest five emails are in range.
        try await h.runner.start(h.plan(from: today.addingTimeInterval(-2500)))
        await h.runner.waitUntilIdle()
        #expect(await h.store.allItems().count == 5)

        let p = try await h.runner.preview(h.plan())
        #expect(p.alreadyProcessed == 5 && p.toProcess.count == 35)
        #expect(p.estimatedSeconds == 10 * 35)
    }

    @Test func builderUsesGivenAverageOrDefault() {
        let headers = (0..<4).map {
            MessageHeader(id: "m\($0)", account: "iCloud", mailbox: "Inbox", sender: "A <a@x.com>",
                          subject: "s", receivedAt: today.addingTimeInterval(Double(-$0)))
        }
        let plan = JobPlan(kind: .backlog, mailboxes: [icloud], from: today, to: today, excludedMessageIDs: [])
        let builder = JobPreviewBuilder()
        let a = builder.build(plan: plan, headers: [icloud: headers], isProcessedOrQueued: [], averageSecondsPerEmail: 7.5)
        let b = builder.build(plan: plan, headers: [icloud: headers], isProcessedOrQueued: [], averageSecondsPerEmail: nil)
        #expect(a.estimatedSeconds == 30 && b.estimatedSeconds == 80)
    }

    @Test func startQueuesExactlyThePreviewedEmailsInOrder() async throws {
        let h = PreviewHarness(count: 120)
        try await h.markProcessed(["gen-0@fixture", "gen-1@fixture"])
        // One unticked email, plus the whole "Shop" sender (every 20th message from n = 15).
        let shop = (0..<120).filter { $0 % 20 == 15 }.map { "gen-\($0)@fixture" }
        let excluded = Set(shop + ["gen-7@fixture"])

        let p = try await h.runner.preview(h.plan(excluded: excluded))
        #expect(p.excluded == excluded.count && p.alreadyProcessed == 2)
        #expect(p.toProcess.count == 120 - 2 - excluded.count)

        try await h.runner.start(p.plan)
        await h.runner.waitUntilIdle()

        #expect(await h.store.allItems().map(\.messageID) == p.toProcess.map(\.id))
        let calls = await h.llm.extractCalls.map(\.id)
        #expect(Set(calls).isDisjoint(with: excluded))
        #expect(calls == p.toProcess.map(\.id))
    }

    @Test func queuedMailboxTotalsComeFromQueuedItems() async throws {
        let h = PreviewHarness(count: 30)
        try await h.markProcessed((0..<10).map { "gen-\($0)@fixture" })
        await h.collector.attach(h.runner.progress)
        try await h.runner.start(h.plan())
        await h.runner.waitUntilIdle()
        #expect(await eventually { await h.collector.events.last?.state == .finished })
        let last = try #require(await h.collector.events.last)
        // 30 found, 10 processed; 20 queued, 10 per mailbox.
        #expect(last.countsByMailbox == [icloud: MailboxProgress(done: 10, total: 10),
                                         outlook: MailboxProgress(done: 10, total: 10)])
        #expect(last.total == 20)
    }

    // MARK: Text

    @Test func durationText() {
        #expect(JobFormat.duration(0) == "under a minute")
        #expect(JobFormat.duration(29) == "under a minute")
        #expect(JobFormat.duration(240) == "about 4 min")
        #expect(JobFormat.duration(3599) == "about 1 h")
        #expect(JobFormat.duration(6000) == "about 1 h 40 min")
        #expect(JobFormat.duration(21_620) == "about 6 h")
        #expect(JobFormat.duration(3 * 3600 + 50 * 60) == "about 3 h 50 min")
        #expect(JobFormat.number(1081) == "1,081")
        #expect(JobFormat.number(999) == "999")
        #expect(JobFormat.number(1_234_567) == "1,234,567")
    }

    @Test func startTitles() {
        let builder = JobPreviewBuilder()
        let archive = MailboxRef(account: "iCloud", name: "Archive")
        func title(_ boxes: [MailboxRef], count: Int) -> String {
            let headers = (0..<count).map {
                MessageHeader(id: "m\($0)", account: "iCloud", mailbox: "Inbox", sender: "A <a@x.com>",
                              subject: "s", receivedAt: today.addingTimeInterval(Double(-$0)))
            }
            let plan = JobPlan(kind: .backlog, mailboxes: boxes, from: today, to: today, excludedMessageIDs: [])
            let p = builder.build(plan: plan, headers: [boxes[0]: headers], isProcessedOrQueued: [], averageSecondsPerEmail: 20)
            return builder.startTitle(for: p)
        }
        #expect(title([icloud], count: 1) == "Process 1 email from iCloud Inbox (under a minute)")
        #expect(title([icloud, outlook], count: 1081) == "Process 1,081 emails from iCloud Inbox and Outlook Inbox (about 6 h)")
        #expect(title([icloud, outlook, archive], count: 12) == "Process 12 emails from 3 mailboxes (about 4 min)")
    }
}

@Suite struct JobRunnerProgressTests {
    @Test func pausedProgressNamesLastAndNextAndAdvancesAfterResume() async throws {
        let h = PreviewHarness(count: 30)
        await h.collector.attach(h.runner.progress)
        let runner = h.runner
        await h.llm.setOnExtract { email in if email.id == "gen-4@fixture" { await runner.pause() } }
        try await runner.start(h.plan())
        await runner.waitUntilIdle()

        #expect(await eventually { await h.collector.events.last?.state == .paused })
        var last = try #require(await h.collector.events.last)
        #expect(last.lastFinished?.position == 5 && last.lastFinished?.sender == "AusPost <tracking@auspost.example>")
        #expect(last.nextUp?.position == 6 && last.nextUp?.sender == "Amazon <ship-confirm@amazon.example>")
        // Items alternate mailboxes: 0, 2, 4 in iCloud and 1, 3 in Outlook are done.
        #expect(last.countsByMailbox == [icloud: MailboxProgress(done: 3, total: 15),
                                         outlook: MailboxProgress(done: 2, total: 15)])

        await h.llm.setOnExtract { email in if email.id == "gen-9@fixture" { await runner.pause() } }
        try await runner.resume()
        await runner.waitUntilIdle()
        #expect(await eventually { let e = await h.collector.events.last; return e?.state == .paused && e?.done == 10 })
        last = try #require(await h.collector.events.last)
        #expect(last.lastFinished?.position == 10 && last.nextUp?.position == 11)
    }

    @Test func retryFailedRequeuesAndCompletesOnceModelRecovers() async throws {
        let h = PreviewHarness(count: 3, llm: StubLLMClient(failures: ["gen-1@fixture": Int.max]))
        try await h.runner.start(h.plan())
        await h.runner.waitUntilIdle()
        let failed = try #require(await h.store.allItems().first { $0.messageID == "gen-1@fixture" })
        #expect(failed.state == .failed && failed.attempts == 3 && failed.finishedAt == today)
        let jobID = failed.jobID
        let before = try #require(await h.store.digest(id: jobID))
        #expect(before.skipped.map(\.id) == ["gen-1@fixture"] && before.emailCount == 3)

        await h.llm.setFailures([:])
        #expect(try await h.runner.retryFailed(jobID: jobID) == 1)
        await h.runner.waitUntilIdle()

        let item = try #require(await h.store.allItems().first { $0.messageID == "gen-1@fixture" })
        #expect(item.state == .done && item.attempts == 1)
        let after = try #require(await h.store.digest(id: jobID))
        #expect(after.skipped.isEmpty && after.emailCount == 3 && after.info.count == 3)
        let job = try #require(await h.store.jobs().first)
        #expect(job.state == .finished && job.totals == JobTotals(queued: 0, done: 3, failed: 0, skipped: 0))
        // Nothing failed any more, so a second retry does nothing.
        #expect(try await h.runner.retryFailed(jobID: jobID) == 0)
    }
}
