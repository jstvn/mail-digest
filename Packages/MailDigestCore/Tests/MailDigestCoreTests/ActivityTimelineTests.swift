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

// MARK: - Empty runs and repeat runs (Phase 6)

extension ActivityTimelineTests {
    static func backlog(_ id: String, at date: Date, state: JobState = .finished, done: Int = 3, queued: Int = 0,
                        failed: Int = 0, scope: Date? = nil, name: String? = nil,
                        boxes: [MailboxRef] = [MailboxRef(account: "iCloud", name: "Inbox")]) -> Job {
        Job(id: UUID(uuidString: id)!, kind: .backlog, mailboxes: boxes, scopeFrom: scope ?? date, scopeTo: scope ?? date,
            state: state, createdAt: date,
            totals: JobTotals(queued: queued, done: done, failed: failed, skipped: 0), autoPaused: false, name: name)
    }

    @Test func emptyRunsAreOnlyFinishedJobsWithNothingInThem() {
        let d = Self.at(2026, 11, 8)
        #expect(ActivityTimeline.isEmptyRun(Self.job(state: .finished, at: d, done: 0)))
        #expect(!ActivityTimeline.isEmptyRun(Self.job(state: .finished, at: d, done: 1)))
        #expect(!ActivityTimeline.isEmptyRun(Self.job(state: .finished, at: d, failed: 1, done: 0)))
        for state in [JobState.running, .listing, .paused, .stopped, .failed, .pausing, .stopping, .idle] {
            #expect(!ActivityTimeline.isEmptyRun(Self.job(state: state, at: d, done: 0)))
        }
        // Stopped with mail still queued is never hidden either.
        #expect(!ActivityTimeline.isEmptyRun(Self.job(state: .finished, at: d, done: 0, queued: 2)))
    }

    @Test func emptyRunsAreHiddenUnlessShown() {
        let d = Self.at(2026, 11, 8, 9)
        let jobs = [Self.job("00000000-0000-0000-0000-000000000001", state: .finished, at: d, done: 0),
                    Self.job("00000000-0000-0000-0000-000000000002", state: .failed, at: d.addingTimeInterval(-60), done: 0),
                    Self.job("00000000-0000-0000-0000-000000000003", state: .paused, at: d.addingTimeInterval(-120), done: 0, queued: 4),
                    Self.job("00000000-0000-0000-0000-000000000004", state: .finished, at: d.addingTimeInterval(-180), done: 2)]
        let timeline = ActivityTimeline(jobs: jobs)
        let hidden = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: false)
        #expect(hidden.flatMap(\.entries).map { String($0.id.uuidString.suffix(1)) } == ["2", "3", "4"])
        let shown = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: true)
        #expect(shown.flatMap(\.entries).count == 4)
    }

    @Test func aDayWithOnlyEmptyRunsDisappears() {
        let d = Self.at(2026, 11, 7, 9)
        let timeline = ActivityTimeline(jobs: [Self.job(state: .finished, at: d, done: 0),
                                               Self.job(state: .finished, at: Self.at(2026, 11, 8), done: 2)])
        let sections = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: false)
        #expect(sections.map(\.title) == ["Today"])
    }

    @Test func consecutiveRepeatRunsGroupNewestFirst() {
        let d = Self.at(2026, 11, 8, 9)
        let scope = Self.at(2026, 10, 1)
        let a = Self.backlog("00000000-0000-0000-0000-00000000000A", at: d, scope: scope)
        let b = Self.backlog("00000000-0000-0000-0000-00000000000B", at: d.addingTimeInterval(-60), done: 5, scope: scope)
        let c = Self.backlog("00000000-0000-0000-0000-00000000000C", at: d.addingTimeInterval(-120), done: 0, scope: scope)
        let other = Self.backlog("00000000-0000-0000-0000-00000000000D", at: d.addingTimeInterval(-180), scope: Self.at(2026, 9, 1))
        let timeline = ActivityTimeline(jobs: [a, b, c, other])
        let entries = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: true)[0].entries
        #expect(entries.count == 2)
        guard case .group(let group) = entries[0] else { Issue.record("expected a group"); return }
        #expect(group.jobs.map(\.id) == [a.id, b.id, c.id] && group.title == "Run 3 times")
        #expect(group.totals.done == 8)
        #expect(entries[1] == .job(other))
        // With empty runs hidden the empty third run leaves the group, which becomes "Run 2 times".
        let trimmed = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: false)[0].entries
        guard case .group(let two) = trimmed[0] else { Issue.record("expected a group"); return }
        #expect(two.count == 2)
    }

    @Test func nonConsecutiveOrUnfinishedOrDifferentJobsDoNotGroup() {
        let d = Self.at(2026, 11, 8, 9)
        let scope = Self.at(2026, 10, 1)
        let first = Self.backlog("00000000-0000-0000-0000-000000000001", at: d, scope: scope)
        let between = Self.backlog("00000000-0000-0000-0000-000000000002", at: d.addingTimeInterval(-60), scope: Self.at(2026, 8, 1))
        let again = Self.backlog("00000000-0000-0000-0000-000000000003", at: d.addingTimeInterval(-120), scope: scope)
        let renamed = Self.backlog("00000000-0000-0000-0000-000000000004", at: d.addingTimeInterval(-180), scope: Self.at(2026, 7, 1), name: "A")
        let renamedB = Self.backlog("00000000-0000-0000-0000-000000000005", at: d.addingTimeInterval(-240), scope: Self.at(2026, 7, 1), name: "B")
        let stoppedA = Self.backlog("00000000-0000-0000-0000-000000000006", at: d.addingTimeInterval(-300), state: .stopped, queued: 3, scope: Self.at(2026, 6, 1))
        let stoppedB = Self.backlog("00000000-0000-0000-0000-000000000007", at: d.addingTimeInterval(-360), state: .stopped, queued: 3, scope: Self.at(2026, 6, 1))
        let daily1 = Self.job("00000000-0000-0000-0000-000000000008", at: d.addingTimeInterval(-420))
        let daily2 = Self.job("00000000-0000-0000-0000-000000000009", at: d.addingTimeInterval(-480))
        let timeline = ActivityTimeline(jobs: [first, between, again, renamed, renamedB, stoppedA, stoppedB, daily1, daily2])
        let entries = timeline.displaySections(calendar: Self.brisbane, now: Self.now, showEmptyRuns: true)[0].entries
        #expect(entries.count == 9)
        #expect(entries.allSatisfy { if case .job = $0 { true } else { false } })
    }

    @Test func differentMailboxesDoNotGroup() {
        let d = Self.at(2026, 11, 8, 9)
        let x = Self.backlog("00000000-0000-0000-0000-000000000001", at: d, boxes: [MailboxRef(account: "A", name: "Inbox")])
        let y = Self.backlog("00000000-0000-0000-0000-000000000002", at: d.addingTimeInterval(-1),
                             boxes: [MailboxRef(account: "B", name: "Inbox")])
        let entries = ActivityTimeline(jobs: [x, y]).displaySections(calendar: Self.brisbane, now: Self.now,
                                                                     showEmptyRuns: true)[0].entries
        #expect(entries.count == 2)
    }
}
