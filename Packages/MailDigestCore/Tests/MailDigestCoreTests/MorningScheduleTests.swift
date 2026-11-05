import Foundation
import Testing
@testable import MailDigestCore

@Suite struct MorningScheduleTests {
    private let zone = TimeZone(identifier: "Australia/Brisbane")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func job(_ state: JobState, at created: Date, kind: JobKind = .daily) -> Job {
        Job(id: UUID(), kind: kind, mailboxes: [], scopeFrom: created, scopeTo: created, state: state,
            createdAt: created, totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0), autoPaused: false)
    }

    private func due(_ now: Date, hour: Int = 6, minute: Int = 30, jobs: [Job] = []) -> Bool {
        MorningSchedule.isDue(now: now, hour: hour, minute: minute, jobs: jobs, timeZone: zone)
    }

    @Test func notDueBeforeRunTime() {
        #expect(!due(date(2026, 11, 6, 6, 29)))
    }

    @Test func dueJustAfterRunTime() {
        #expect(due(date(2026, 11, 6, 6, 30)))
        #expect(due(date(2026, 11, 6, 6, 31)))
    }

    @Test(arguments: [JobState.finished, .paused, .running, .listing, .pausing, .stopping, .idle])
    func notDueWhenTodaysJobExists(state: JobState) {
        let now = date(2026, 11, 6, 9, 0)
        #expect(!due(now, jobs: [job(state, at: date(2026, 11, 6, 6, 31))]))
    }

    @Test func dueWhenTodaysJobFailed() {
        let now = date(2026, 11, 6, 9, 0)
        #expect(due(now, jobs: [job(.failed, at: date(2026, 11, 6, 6, 31))]))
    }

    @Test func dueWhenOnlyYesterdaysJob() {
        let now = date(2026, 11, 6, 6, 45)
        #expect(due(now, jobs: [job(.finished, at: date(2026, 11, 5, 6, 31))]))
    }

    @Test func backlogJobDoesNotCount() {
        let now = date(2026, 11, 6, 7, 0)
        #expect(due(now, jobs: [job(.finished, at: date(2026, 11, 6, 6, 40), kind: .backlog)]))
    }

    @Test func runTimeNearMidnight() {
        // 23:50 run time: due at 23:55, not at 23:45; a job from 23:51 yesterday doesn't count today.
        #expect(!due(date(2026, 11, 6, 23, 45), hour: 23, minute: 50))
        #expect(due(date(2026, 11, 6, 23, 55), hour: 23, minute: 50,
                    jobs: [job(.finished, at: date(2026, 11, 5, 23, 51))]))
        // 00:05 run time at 00:10 the next day.
        #expect(due(date(2026, 11, 7, 0, 10), hour: 0, minute: 5,
                    jobs: [job(.finished, at: date(2026, 11, 6, 0, 6))]))
    }

    @Test func runTimeChangedLaterInTheDay() {
        // Ran at 06:31 for a 06:30 schedule. The user moves the time to 08:00: not due until 08:00, and a
        // job from before the new run time doesn't suppress it.
        let jobs = [job(.finished, at: date(2026, 11, 6, 6, 31))]
        #expect(!due(date(2026, 11, 6, 7, 30), hour: 8, minute: 0, jobs: jobs))
        #expect(due(date(2026, 11, 6, 8, 5), hour: 8, minute: 0, jobs: jobs))
        // Moving it earlier to 05:00 does not rerun: the 06:31 job is after the new run time.
        #expect(!due(date(2026, 11, 6, 7, 30), hour: 5, minute: 0, jobs: jobs))
    }

    @Test func dstGapFallsForward() {
        // Sydney skips 02:00-03:00 on 2026-10-04; a 02:30 run time must still resolve.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        var c = Calendar(identifier: .gregorian)
        c.timeZone = sydney
        let noon = c.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        let run = MorningSchedule.runTime(on: noon, hour: 2, minute: 30, timeZone: sydney)
        #expect(c.component(.day, from: run) == 4)
        #expect(run < noon)
        #expect(MorningSchedule.isDue(now: noon, hour: 2, minute: 30, jobs: [], timeZone: sydney))
    }
}
