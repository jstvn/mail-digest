import Foundation
import Testing
@testable import MailDigestCore

@Suite struct DailyLifecycleTests {
    private let zone = TimeZone(identifier: "Australia/Brisbane")!

    private func date(_ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: min))!
    }

    private func job(_ state: JobState, kind: JobKind = .daily, queued: Int = 3, created: Date? = nil,
                     lastError: String? = nil) -> Job {
        let created = created ?? date(5, 6, 30)
        return Job(id: UUID(), kind: kind, mailboxes: [], scopeFrom: created.addingTimeInterval(-3600), scopeTo: created,
                   state: state, createdAt: created, totals: JobTotals(queued: queued, done: 2, failed: 0, skipped: 0),
                   autoPaused: false, lastError: lastError)
    }

    private func live(_ job: Job, _ state: JobState, done: Int = 2, total: Int = 5) -> JobProgress {
        JobProgress(jobID: job.id, kind: job.kind, state: state, done: done, total: total, failed: 0,
                    avgSecondsPerEmail: nil, eta: nil, stage: .summarising, current: nil, lastFinished: nil,
                    nextUp: nil, countsByMailbox: [:])
    }

    @Test func retryStartKeepsTheStartBehaviourWithRetryWording() {
        #expect(DailyMenuAction.retryStart.title == "Retry Daily Digest")
        #expect(DailyMenuAction.retryStart.behavior == .startNew)
    }

    // MARK: Derivation

    @Test func finishedDailyHistoryIsNotUnresolved() {
        let jobs = [job(.finished, queued: 0), job(.finished, queued: 0), job(.idle, queued: 0)]
        #expect(DailyLifecycle(jobs: jobs) == .none)
        #expect(DailyLifecycle(jobs: []).menuAction.behavior == .startNew)
        #expect(DailyLifecycle(jobs: []).menuAction.title == "Run Daily Digest Now")
    }

    @Test func eachUnresolvedStateMapsToItsAction() {
        let paused = job(.paused)
        #expect(DailyLifecycle(jobs: [paused]) == .paused(paused))
        #expect(DailyLifecycle(jobs: [paused]).menuAction.behavior == .resume(paused.id))
        #expect(DailyLifecycle(jobs: [paused]).menuAction.title == "Resume")

        for state in [JobState.listing, .running, .pausing] {
            let busy = job(state, queued: 0)
            #expect(DailyLifecycle(jobs: [busy]) == .running(busy))
            #expect(DailyLifecycle(jobs: [busy]).menuAction == .running)
            #expect(!DailyLifecycle(jobs: [busy]).menuAction.isActionable)
        }

        let stopping = job(.stopping)
        #expect(DailyLifecycle(jobs: [stopping]).menuAction.title == "Stopping…")
        #expect(DailyLifecycle(jobs: [stopping]).menuAction.behavior == .none)

        let stopped = job(.stopped)
        #expect(DailyLifecycle(jobs: [stopped]) == .stopped(stopped))
        #expect(DailyLifecycle(jobs: [stopped]).menuAction.behavior == .review)
        #expect(DailyLifecycle(jobs: [stopped]).menuAction.title == "Review Daily Job…")

        let failed = job(.failed, lastError: "Ollama is not reachable.")
        #expect(DailyLifecycle(jobs: [failed]) == .failed(failed))
        #expect(DailyLifecycle(jobs: [failed]).menuAction.behavior == .retry(failed.id))
        #expect(DailyLifecycle(jobs: [failed]).menuAction.note == "Ollama is not reachable.")
    }

    @Test(arguments: [JobState.paused, .stopped, .failed])
    func nothingLeftToContinueIsResolved(state: JobState) {
        // A failed listing queues nothing; Q23 already leaves its window to the next Daily job.
        #expect(DailyLifecycle(jobs: [job(state, queued: 0)]) == .none)
    }

    @Test(arguments: [JobState.paused, .running, .stopped, .failed, .listing])
    func backlogJobsNeverCount(state: JobState) {
        let backlog = job(state, kind: .backlog)
        #expect(DailyLifecycle(jobs: [backlog]) == .none)
        #expect(DailyLifecycle(jobs: [backlog]).menuAction.behavior == .startNew)
    }

    @Test func pausedBacklogBesidePausedDailyLeavesTheDailyAction() {
        let daily = job(.paused)
        #expect(DailyLifecycle(jobs: [job(.paused, kind: .backlog), daily]) == .paused(daily))
    }

    @Test func multipleUnresolvedDailyJobsAreAConflictNotAPick() {
        let newer = job(.stopped, created: date(5, 6, 30))
        let older = job(.paused, created: date(4, 6, 30))
        let lifecycle = DailyLifecycle(jobs: [newer, job(.finished, queued: 0), older])
        #expect(lifecycle == .conflict([newer, older]))
        #expect(lifecycle.jobs.map(\.id) == [newer.id, older.id])
        #expect(lifecycle.menuAction.behavior == .review)
        #expect(lifecycle.menuAction.title == "Review Daily Jobs…")
    }

    @Test func liveProgressOverridesTheStoredState() {
        let stored = job(.running, queued: 3)
        var pausing = stored
        pausing.state = .pausing
        #expect(DailyLifecycle(jobs: [stored], live: live(stored, .pausing)) == .running(pausing))
        if case .stopping = DailyLifecycle(jobs: [stored], live: live(stored, .stopping)) {} else {
            Issue.record("expected stopping")
        }
        if case .paused(let j) = DailyLifecycle(jobs: [stored], live: live(stored, .paused)) {
            #expect(j.id == stored.id && j.totals.queued == 3)
        } else {
            Issue.record("expected paused")
        }
        #expect(DailyLifecycle(jobs: [stored], live: live(stored, .finished, done: 5, total: 5)) == .none)
        // Progress for another job changes nothing.
        let other = job(.running, kind: .backlog)
        #expect(DailyLifecycle(jobs: [stored], live: live(other, .finished)) == .running(stored))
    }

    // MARK: Scheduler (Q52)

    private func decision(_ now: Date, _ jobs: [Job]) -> ScheduledDailyDecision {
        MorningSchedule.decision(now: now, hour: 6, minute: 30, jobs: jobs, timeZone: zone)
    }

    @Test(arguments: [JobState.paused, .stopped, .failed, .running])
    func dueRunWaitsForAnEarlierUnresolvedDailyJob(state: JobState) {
        let old = job(state, created: date(5, 6, 30))
        #expect(decision(date(6, 6, 45), [old]) == .deferred(DailyLifecycle(jobs: [old])))
        // Still deferred on every later check until the user resolves it; nothing is recorded.
        #expect(decision(date(6, 9, 0), [old]) == .deferred(DailyLifecycle(jobs: [old])))
    }

    @Test func dueRunStartsOnceTheEarlierJobIsResolved() {
        var old = job(.paused, created: date(5, 6, 30))
        old.state = .finished
        old.totals.queued = 0
        #expect(decision(date(6, 10, 0), [old]) == .start)
    }

    @Test func todaysPausedDailyJobMeansTheRunHappened() {
        #expect(decision(date(6, 9, 0), [job(.paused, created: date(6, 6, 31))]) == .notDue)
        #expect(decision(date(6, 6, 0), [job(.paused, created: date(5, 6, 31))]) == .notDue)
    }

    @Test func todaysFailedDailyJobWithAQueueIsNotReplaced() {
        // Before Q52 a failed job made the run due again, which created a second job next to it.
        let failed = job(.failed, created: date(6, 6, 31))
        #expect(decision(date(6, 7, 0), [failed]) == .deferred(.failed(failed)))
        // One that failed before queuing anything is retried by the scheduler as before (Q25).
        #expect(decision(date(6, 7, 0), [job(.failed, queued: 0, created: date(6, 6, 31))]) == .start)
    }

    @Test func pausedBacklogDoesNotDeferTheScheduledRun() {
        #expect(decision(date(6, 7, 0), [job(.paused, kind: .backlog, created: date(5, 20, 0))]) == .start)
    }
}
