import Foundation
import Testing
@testable import MailDigestCore

@Suite struct ActivityTimelineTests {
    static var brisbane: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return c
    }
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// 2026-11-08 12:00 Brisbane.
    static let now = brisbane.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0, cal: Calendar = brisbane) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func job(_ id: String = UUID().uuidString, kind: JobKind = .daily, state: JobState = .finished,
                    at date: Date, failed: Int = 0, done: Int = 3, queued: Int = 0) -> Job {
        Job(id: UUID(uuidString: id) ?? UUID(), kind: kind, mailboxes: [MailboxRef(account: "iCloud", name: "Inbox")],
            scopeFrom: date, scopeTo: date, state: state, createdAt: date,
            totals: JobTotals(queued: queued, done: done, failed: failed, skipped: 0), autoPaused: false)
    }

    @Test func statusMapping() {
        let d = Self.at(2026, 11, 8)
        #expect(ActivityJobStatus(Self.job(state: .running, at: d)) == .running)
        #expect(ActivityJobStatus(Self.job(state: .listing, at: d)) == .running)
        #expect(ActivityJobStatus(Self.job(state: .pausing, at: d)) == .pausing)
        #expect(ActivityJobStatus(Self.job(state: .paused, at: d)) == .paused)
        #expect(ActivityJobStatus(Self.job(state: .stopping, at: d)) == .stopping)
        #expect(ActivityJobStatus(Self.job(state: .stopped, at: d)) == .stopped)
        #expect(ActivityJobStatus(Self.job(state: .finished, at: d)) == .completed)
        #expect(ActivityJobStatus(Self.job(state: .finished, at: d, failed: 2)) == .completedWithFailures)
        #expect(ActivityJobStatus(Self.job(state: .failed, at: d)) == .failed)
        #expect(ActivityJobStatus(Self.job(state: .idle, at: d)) == .notStarted)
        #expect(ActivityJobStatus.allCases.map(\.title).contains("Completed with failures"))
        #expect(ActivityJobStatus.running.isLive && !ActivityJobStatus.paused.isLive)
    }

    @Test func sameDayDailyJobsStaySeparate() {
        let a = Self.job(at: Self.at(2026, 11, 8, 7)), b = Self.job(at: Self.at(2026, 11, 8, 9))
        let sections = ActivityTimeline(jobs: [a, b]).sections(calendar: Self.brisbane, now: Self.now)
        #expect(sections.count == 1)
        #expect(sections[0].jobs.map(\.id) == [b.id, a.id])
        #expect(sections[0].title == "Today")
    }

    @Test func sectionTitles() {
        let t = ActivityTimeline(jobs: [
            Self.job(at: Self.at(2026, 11, 8)), Self.job(at: Self.at(2026, 11, 7)),
            Self.job(at: Self.at(2026, 11, 6)), Self.job(at: Self.at(2025, 9, 2)),
        ])
        #expect(t.sections(calendar: Self.brisbane, now: Self.now).map(\.title)
                == ["Today", "Yesterday", "Fri, 6 Nov", "Tue, 2 Sep 2025"])
    }

    @Test func timeZoneDecidesTheDay() {
        // 23:30 on 7 Nov in Brisbane is 13:30 UTC the same day; 06:30 on 8 Nov Brisbane is 20:30 UTC on 7 Nov.
        let late = Self.job(at: Self.at(2026, 11, 7, 23, 30)), early = Self.job(at: Self.at(2026, 11, 8, 0, 30))
        let t = ActivityTimeline(jobs: [late, early])
        let brisbane = t.sections(calendar: Self.brisbane, now: Self.now)
        #expect(brisbane.map(\.title) == ["Today", "Yesterday"])
        // In UTC both fall on 7 Nov (early = 14:30 UTC on the 7th).
        let utcNow = Self.at(2026, 11, 8, 2, cal: Self.utc)
        let utc = t.sections(calendar: Self.utc, now: utcNow)
        #expect(utc.count == 1 && utc[0].title == "Yesterday")
    }

    @Test func tiesOrderByIDDescending() {
        let d = Self.at(2026, 11, 8)
        let low = Self.job("00000000-0000-0000-0000-000000000001", at: d)
        let high = Self.job("00000000-0000-0000-0000-000000000009", at: d)
        #expect(ActivityTimeline(jobs: [low, high]).jobs.map(\.id) == [high.id, low.id])
        #expect(ActivityTimeline(jobs: [high, low]).jobs.map(\.id) == [high.id, low.id])
        #expect(ActivityTimeline(jobs: [low, high]).cursor == ActivityCursor(after: low))
    }

    @Test func mergeDedupesAndReplacesInPlace() {
        let a = Self.job(kind: .daily, state: .running, at: Self.at(2026, 11, 8, 9))
        let b = Self.job(at: Self.at(2026, 11, 7))
        var t = ActivityTimeline(jobs: [a, b])
        var updated = a
        updated.state = .finished
        var older = Self.job(at: Self.at(2026, 11, 1))
        older.kind = .backlog
        t.merge([updated, older])
        #expect(t.jobs.map(\.id) == [a.id, b.id, older.id])
        #expect(t.jobs[0].state == .finished)
        // Merging the same page again changes nothing.
        let before = t
        t.merge([updated, older])
        #expect(t == before)
    }

    @Test func elapsedAndProgressText() {
        let d = Self.at(2026, 11, 8, 9)
        var running = Self.job(state: .running, at: d, done: 4, queued: 6)
        #expect(ActivityText.elapsed(running, now: d.addingTimeInterval(90)) == nil)
        running.startedAt = d
        #expect(ActivityText.elapsed(running, now: d.addingTimeInterval(90)) == 90)
        var done = Self.job(at: d)
        done.startedAt = d
        done.endedAt = d.addingTimeInterval(3900)
        #expect(ActivityText.elapsed(done, now: d.addingTimeInterval(99_999)) == 3900)
        #expect(ActivityText.elapsedText(3900) == "1 h 05 min")
        #expect(ActivityText.elapsedText(750) == "12 min 30 s")
        #expect(ActivityText.elapsedText(45) == "45 s")
        #expect(ActivityText.elapsedText(nil) == "—")
        #expect(ActivityText.progressText(running) == "4 of 10 emails")
        #expect(ActivityText.title(running) == "Daily Digest")
        var backlog = running
        backlog.kind = .backlog
        #expect(ActivityText.title(backlog) == "Backlog · iCloud Inbox")
    }

    @Test func eventDescriptions() {
        func text(_ k: JobEventKind, _ p: JobEventPayload = .empty) -> String {
            ActivityText.eventText(JobEvent(jobID: UUID(), kind: k, at: Date(timeIntervalSince1970: 0), payload: p))
        }
        #expect(text(.autoPaused, JobEventPayload(pauseReason: .battery)) == "Paused automatically · On battery")
        #expect(text(.autoPaused, JobEventPayload(pauseReason: .quietHours)) == "Paused automatically · Outside the run window")
        #expect(text(.paused) == "Paused")
        #expect(text(.resumed, JobEventPayload(trigger: .automatic)) == "Resumed · Automatic")
        #expect(text(.completedWithFailures, JobEventPayload(count: 3)) == "Completed with failures · 3 failed")
        #expect(text(.failed, JobEventPayload(errorCategory: "provider")) == "Failed · Model unavailable")
        #expect(text(.recoveredAfterInterruption, JobEventPayload(trigger: .launch, count: 1)) == "Recovered after interruption · 1 email requeued")
        for kind in JobEventKind.allCases { #expect(!text(kind).isEmpty) }
    }
}
