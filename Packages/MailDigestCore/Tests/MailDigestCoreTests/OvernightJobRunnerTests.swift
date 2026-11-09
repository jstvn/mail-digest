import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")

/// Old mail ending ten days before "today", so a Backlog plan finds it.
private func oldMessages(_ count: Int) -> [EmailMessage] {
    (0..<count).map { n in
        EmailMessage(id: "old-\(n)@fixture", account: "iCloud", mailbox: "Inbox", sender: "Sam <sam@example.com>",
                     subject: "Old \(n)", receivedAt: today.addingTimeInterval(-10 * 86_400 - 600 * Double(n)),
                     body: "Hello. Please reply by Friday.", headers: [:])
    }
}

private struct OvernightHarness {
    let store = InMemoryDigestStore()
    let llm = StubLLMClient()
    let runner: JobRunner

    init(count: Int = 3) {
        runner = JobRunner(source: FixtureMailSource(messages: oldMessages(count)), llm: llm, store: store,
                           notifier: RecordingNotifier(), clock: FixedClock(today),
                           settings: RunnerSettings(timeZone: FixtureLoader.timeZone, dailyMailboxes: [icloud]),
                           sleep: { _ in })
    }

    func plan(overnight: Bool, name: String? = "October Backlog") -> JobPlan {
        JobPlan(kind: .backlog, mailboxes: [icloud], from: today.addingTimeInterval(-30 * 86_400),
                to: today.addingTimeInterval(60), excludedMessageIDs: [], name: name, overnightOnly: overnight)
    }

    func job() async throws -> Job { try #require(try await store.jobs().first) }
}

/// "Overnight While Plugged In": the job is created paused for the run window, keeps its name, and only the
/// existing resource-rule path (Q43, Q44) ever starts it.
@Suite struct OvernightJobRunnerTests {
    @Test func startedOutsideTheWindowItIsStoredPausedNamedAndReadsNothing() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: .quietHours)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()

        let job = try await h.job()
        #expect(job.state == .paused && job.autoPaused && job.pauseReason == .quietHours)
        #expect(job.overnightOnly && job.name == "October Backlog" && job.totals.queued == 3)
        #expect(await h.llm.extractCalls.isEmpty)
        #expect(BacklogRowText.isScheduled(job))
    }

    @Test func itStaysPausedUntilTheWindowOpensThenRunsToTheEnd() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: .quietHours)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()
        let id = try await h.job().id

        // The resource monitor re-evaluates during the day: still closed.
        #expect(try await h.runner.autoResume(blocked: [:], overnight: .quietHours) == nil)
        // Plugged in but still outside the window: the global rules alone would let it run; the overnight rule must not.
        #expect(try await h.runner.autoResume(blocked: [.backlog: .battery], overnight: nil) == nil)
        // The window opens (the monitor's boundary timer fires and nothing blocks).
        #expect(try await h.runner.autoResume(blocked: [:], overnight: nil) == id)
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
        #expect(await h.llm.extractCalls.count == 3)
    }

    @Test func aManualResumeOutsideTheWindowLeavesItPausedAndSaysWhy() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: .quietHours)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()
        let id = try await h.job().id
        await #expect(throws: JobRunnerError.resourceBlocked(.quietHours)) { try await h.runner.resume(jobID: id) }
        #expect(try await h.job().state == .paused)
        #expect(await h.llm.extractCalls.isEmpty)
    }

    @Test func aStoppedOvernightJobIsNeverResumedAutomatically() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: .quietHours)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()
        let id = try await h.job().id
        try await h.runner.stopPaused(jobID: id)
        #expect(try await h.job().state == .stopped)
        #expect(try await h.runner.autoResume(blocked: [:], overnight: nil) == nil)
        #expect(try await h.job().state == .stopped)
    }

    @Test func theOvernightRuleDoesNotAffectOrdinaryBacklogJobs() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: .quietHours)
        try await h.runner.start(h.plan(overnight: false))
        await h.runner.waitUntilIdle()
        let job = try await h.job()
        #expect(job.state == .finished && !job.overnightOnly && job.name == "October Backlog")
    }

    @Test func startedInsideTheWindowItRunsAtOnce() async throws {
        let h = OvernightHarness()
        await h.runner.setResourceBlockers([:], overnight: nil)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()
        let job = try await h.job()
        #expect(job.state == .finished && job.overnightOnly)
    }

    @Test func aRunningOvernightJobPausesWhenTheWindowClosesAndResumesTheNextNight() async throws {
        let h = OvernightHarness(count: 4)
        let runner = h.runner
        // Close the window while the first email is being read.
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { try? await runner.applyResourceRules([:], overnight: .quietHours) }
        }
        await h.runner.setResourceBlockers([:], overnight: nil)
        try await h.runner.start(h.plan(overnight: true))
        await h.runner.waitUntilIdle()
        await h.llm.setOnExtract(nil)

        var job = try await h.job()
        #expect(job.state == .paused && job.pauseReason == .quietHours && job.totals.done == 1)
        #expect(BacklogRowText.isScheduled(job))
        // Next night.
        #expect(try await h.runner.autoResume(blocked: [:], overnight: nil) == job.id)
        await h.runner.waitUntilIdle()
        job = try await h.job()
        #expect(job.state == .finished && job.totals.done == 4)
    }

    @Test func anOrdinaryJobKeepsRunningWhenOnlyTheOvernightRuleCloses() async throws {
        let h = OvernightHarness(count: 3)
        let runner = h.runner
        await h.llm.setOnExtract { email in
            if email.id == "old-0@fixture" { try? await runner.applyResourceRules([:], overnight: .quietHours) }
        }
        try await h.runner.start(h.plan(overnight: false))
        await h.runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }
}
