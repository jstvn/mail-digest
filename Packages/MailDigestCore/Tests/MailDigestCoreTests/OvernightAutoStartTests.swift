import Foundation
import Testing
@testable import MailDigestCore

private let today = FixtureLoader.today
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")

private func oldMessages(_ count: Int) -> [EmailMessage] {
    (0..<count).map { n in
        EmailMessage(id: "old-\(n)@fixture", account: "iCloud", mailbox: "Inbox", sender: "Sam <sam@example.com>",
                     subject: "Old \(n)", receivedAt: today.addingTimeInterval(-10 * 86_400 - 600 * Double(n)),
                     body: "Hello. Please reply by Friday.", headers: [:])
    }
}

/// A store that outlives the runner, so a second runner stands in for a relaunch.
private struct AutoStartHarness {
    let store = InMemoryDigestStore()
    let llm = StubLLMClient()

    func makeRunner() -> JobRunner {
        JobRunner(source: FixtureMailSource(messages: oldMessages(3)), llm: llm, store: store,
                  notifier: RecordingNotifier(), clock: FixedClock(today),
                  settings: RunnerSettings(timeZone: FixtureLoader.timeZone, dailyMailboxes: [icloud]),
                  sleep: { _ in })
    }

    func plan(overnight: Bool) -> JobPlan {
        JobPlan(kind: .backlog, mailboxes: [icloud], from: today.addingTimeInterval(-30 * 86_400),
                to: today.addingTimeInterval(60), excludedMessageIDs: [], name: "Backlog", overnightOnly: overnight)
    }

    func job() async throws -> Job { try #require(try await store.jobs().first) }

    /// Creates a job waiting for `reason` in a first runner, then returns a fresh runner (the relaunch).
    func relaunchedWithWaitingJob(overnight: Bool, reason: PauseReason = .quietHours) async throws -> JobRunner {
        let first = makeRunner()
        await first.setResourceBlockers(overnight ? [:] : [.backlog: reason], overnight: overnight ? reason : nil)
        try await first.start(plan(overnight: overnight))
        await first.waitUntilIdle()
        return makeRunner()
    }
}

@Suite struct OvernightAutoStartTests {
    @Test func aRelaunchedRunnerStartsAStoredOvernightJobInsideTheWindow() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: true)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
        #expect(await h.llm.extractCalls.count == 3)
    }

    @Test func aRelaunchedRunnerLeavesItWaitingOutsideTheWindow() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: true)
        try await runner.applyResourceRules([:], overnight: .quietHours)
        await runner.waitUntilIdle()
        let job = try await h.job()
        #expect(job.state == .paused && job.pauseReason == .quietHours)
        #expect(await h.llm.extractCalls.isEmpty)
    }

    @Test func itWaitsOnBatteryEvenInsideTheWindow() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: true)
        try await runner.applyResourceRules([:], overnight: .battery)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .paused)
        #expect(await h.llm.extractCalls.isEmpty)
    }

    @Test func aJobWaitingForPowerOrHeatStartsAfterARelaunchOnceClear() async throws {
        let h = AutoStartHarness()
        let first = h.makeRunner()
        await first.setResourceBlockers([.backlog: .lowPowerMode], overnight: nil)
        try await first.start(h.plan(overnight: true))
        await first.waitUntilIdle()
        #expect(try await h.job().pauseReason == .lowPowerMode)
        let runner = h.makeRunner()
        try await runner.applyResourceRules([.backlog: .lowPowerMode], overnight: nil)
        #expect(try await h.job().state == .paused)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }

    @Test func anOvernightJobCutOffWhileRunningIsStartedAgainAfterARelaunch() async throws {
        let h = AutoStartHarness()
        let first = h.makeRunner()
        await first.setResourceBlockers([:], overnight: .quietHours)
        try await first.start(h.plan(overnight: true))
        await first.waitUntilIdle()
        // The app quit while the job was running.
        var job = try await h.job()
        job.state = .running
        job.clearPause()
        try await h.store.updateJob(job)

        let runner = h.makeRunner()
        try await runner.recoverOnLaunch()
        #expect(try await h.job().state == .paused)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .finished)
    }

    @Test func aJobTheUserPausedIsNotStarted() async throws {
        let h = AutoStartHarness()
        let first = h.makeRunner()
        let llm = h.llm
        await llm.setOnExtract { email in
            if email.id == "old-0@fixture" { await first.pause() }
        }
        await first.setResourceBlockers([:], overnight: nil)
        try await first.start(h.plan(overnight: true))
        await first.waitUntilIdle()
        await llm.setOnExtract(nil)
        let paused = try await h.job()
        #expect(paused.state == .paused && paused.pauseReason == nil)
        let calls = await llm.extractCalls.count

        let runner = h.makeRunner()
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .paused)
        #expect(await llm.extractCalls.count == calls)
    }

    @Test func aStoppedOvernightJobIsNotStarted() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: true)
        let id = try await h.job().id
        try await runner.stopPaused(jobID: id)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .stopped)
        #expect(await h.llm.extractCalls.isEmpty)
    }

    @Test func anOrdinaryJobPausedInAnEarlierSessionIsNotStarted() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: false, reason: .battery)
        #expect(try await h.job().pauseReason == .battery)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .paused)
        #expect(await h.llm.extractCalls.isEmpty)
    }

    @Test func aJobWaitingForADailyJobIsNotStarted() async throws {
        let h = AutoStartHarness()
        let runner = try await h.relaunchedWithWaitingJob(overnight: true)
        var job = try await h.job()
        job.pauseReason = .dailyJob
        try await h.store.updateJob(job)
        try await runner.applyResourceRules([:], overnight: nil)
        await runner.waitUntilIdle()
        #expect(try await h.job().state == .paused)
        #expect(await h.llm.extractCalls.isEmpty)
    }
}

@Suite struct OvernightPolicyRuleTests {
    private func job(_ state: JobState, reason: PauseReason?, overnight: Bool, kind: JobKind = .backlog) -> Job {
        Job(id: UUID(), kind: kind, mailboxes: [icloud], scopeFrom: today, scopeTo: today, state: state,
            createdAt: today, totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: reason != nil, pauseReason: reason, overnightOnly: overnight)
    }

    @Test(arguments: [PauseReason.battery, .lowPowerMode, .heat, .quietHours])
    func overnightJobsWithAResourceReasonAreCandidatesInAnySession(_ reason: PauseReason) {
        let j = job(.paused, reason: reason, overnight: true)
        #expect(OvernightPolicy.isAutoResumeCandidate(j, autoPausedThisSession: false))
        #expect(OvernightPolicy.isAutoResumeCandidate(j, autoPausedThisSession: true))
    }

    @Test func nothingElseIsACandidateOutsideItsSession() {
        #expect(!OvernightPolicy.isAutoResumeCandidate(job(.paused, reason: nil, overnight: true), autoPausedThisSession: true))
        #expect(!OvernightPolicy.isAutoResumeCandidate(job(.paused, reason: .dailyJob, overnight: true), autoPausedThisSession: false))
        #expect(!OvernightPolicy.isAutoResumeCandidate(job(.stopped, reason: .battery, overnight: true), autoPausedThisSession: true))
        #expect(!OvernightPolicy.isAutoResumeCandidate(job(.running, reason: .battery, overnight: true), autoPausedThisSession: true))
        #expect(!OvernightPolicy.isAutoResumeCandidate(job(.paused, reason: .battery, overnight: false), autoPausedThisSession: false))
        #expect(OvernightPolicy.isAutoResumeCandidate(job(.paused, reason: .battery, overnight: false), autoPausedThisSession: true))
    }

    @Test func idleSleepIsPreventedOnlyWhileAnOvernightJobWorksOnMains() {
        let states: [JobState] = [.idle, .listing, .running, .pausing, .paused, .stopping, .stopped, .finished, .failed]
        for state in states {
            let working = state == .listing || state == .running
            #expect(OvernightPolicy.shouldPreventIdleSleep(state: state, overnightOnly: true, onBattery: false) == working)
            #expect(!OvernightPolicy.shouldPreventIdleSleep(state: state, overnightOnly: true, onBattery: true))
            #expect(!OvernightPolicy.shouldPreventIdleSleep(state: state, overnightOnly: false, onBattery: false))
            #expect(!OvernightPolicy.shouldPreventIdleSleep(state: state, overnightOnly: false, onBattery: true))
        }
    }
}
