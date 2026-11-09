import Foundation
import Testing
@testable import MailDigestCore

@Suite struct SidebarPresentationTests {
    private let zone = TimeZone(identifier: "Australia/Brisbane")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    private let en = Locale(identifier: "en_AU")

    private func flat(_ y: Int, _ m: Int) -> [MonthGridCell] {
        MonthGrid.weeks(for: DigestMonth(year: y, month: m), calendar: calendar).flatMap { $0 }
    }

    // MARK: Month grid

    @Test func novemberStartingOnSundayHasSixLeadingDays() {
        let weeks = MonthGrid.weeks(for: DigestMonth(year: 2026, month: 11), calendar: calendar)
        #expect(weeks.count == 6 && weeks.allSatisfy { $0.count == 7 })
        // Monday 26 Oct leads; Sunday 1 Nov sits in the last column.
        #expect(weeks[0][0].day == DigestDay(year: 2026, month: 10, day: 26) && !weeks[0][0].isInMonth)
        #expect(weeks[0][6].day == DigestDay(year: 2026, month: 11, day: 1) && weeks[0][6].isInMonth)
        // 30 Nov is a Monday in the sixth row, followed by December days.
        #expect(weeks[5][0].day == DigestDay(year: 2026, month: 11, day: 30) && weeks[5][0].isInMonth)
        #expect(weeks[5][1].day == DigestDay(year: 2026, month: 12, day: 1) && !weeks[5][1].isInMonth)
        #expect(weeks[5][6].day == DigestDay(year: 2026, month: 12, day: 6))
    }

    @Test func monthStartingOnMondayHasNoLeadingDays() {
        // 1 June 2026 is a Monday.
        let weeks = MonthGrid.weeks(for: DigestMonth(year: 2026, month: 6), calendar: calendar)
        #expect(weeks[0][0].day == DigestDay(year: 2026, month: 6, day: 1) && weeks[0][0].isInMonth)
        #expect(weeks.flatMap { $0 }.filter(\.isInMonth).count == 30)
    }

    @Test func leapFebruaryHasTwentyNineDays() {
        // 1 Feb 2028 is a Tuesday.
        let cells = flat(2028, 2)
        #expect(cells.filter(\.isInMonth).count == 29)
        #expect(cells[0].day == DigestDay(year: 2028, month: 1, day: 31))
        #expect(cells.contains { $0.day == DigestDay(year: 2028, month: 2, day: 29) && $0.isInMonth })
        #expect(flat(2027, 2).filter(\.isInMonth).count == 28)
    }

    @Test func yearBoundariesWrap() {
        let cells = flat(2026, 12)
        #expect(cells.contains { $0.day == DigestDay(year: 2027, month: 1, day: 3) && !$0.isInMonth })
        #expect(MonthGrid.month(DigestMonth(year: 2026, month: 1), adding: -1) == DigestMonth(year: 2025, month: 12))
        #expect(MonthGrid.month(DigestMonth(year: 2026, month: 12), adding: 1) == DigestMonth(year: 2027, month: 1))
        #expect(MonthGrid.month(DigestMonth(year: 2026, month: 3), adding: -15) == DigestMonth(year: 2024, month: 12))
    }

    // MARK: Day label and archive entries

    @Test func dayLabels() {
        let day = DigestDay(year: 2026, month: 11, day: 8)
        #expect(MonthGrid.accessibilityLabel(for: day, entry: CalendarDigestEntry(unreviewed: 2), isToday: false,
                                             calendar: calendar, locale: en) == "Sunday 8 November, digest with 2 unreviewed")
        #expect(MonthGrid.accessibilityLabel(for: day, entry: CalendarDigestEntry(unreviewed: 0), isToday: false,
                                             calendar: calendar, locale: en) == "Sunday 8 November, digest, all reviewed")
        #expect(MonthGrid.accessibilityLabel(for: day, entry: nil, isToday: true,
                                             calendar: calendar, locale: en) == "Sunday 8 November, today")
    }

    private func summary(_ created: Date, pending: Int) -> DigestSummary {
        DigestSummary(id: UUID(), createdAt: created, kind: .daily, emailCount: 3, pendingCount: pending, failedCount: 0)
    }

    @Test func archiveEntriesAndRange() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9))!
        let nov8 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 7))!
        let oct2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7))!
        let archive = DigestArchive(summaries: [summary(nov8, pending: 2), summary(oct2, pending: 0)],
                                    now: now, calendar: calendar)
        #expect(archive.calendarEntry(for: DigestDay(year: 2026, month: 11, day: 8)) == CalendarDigestEntry(unreviewed: 2))
        #expect(archive.calendarEntry(for: DigestDay(year: 2026, month: 10, day: 2)) == CalendarDigestEntry(unreviewed: 0))
        #expect(archive.calendarEntry(for: DigestDay(year: 2026, month: 11, day: 7)) == nil)
        // Today has no digest yet, so no dot.
        #expect(archive.calendarEntry(for: archive.todayDay) == nil)
        #expect(archive.calendarMonthRange == DigestMonth(year: 2026, month: 10)...DigestMonth(year: 2026, month: 11))
    }

    // MARK: Next digest footer

    private func nextText(_ h: Int, _ m: Int, runHour: Int = 6, runMinute: Int = 30) -> String {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: h, minute: m))!
        return NextDigestText.text(now: now, hour: runHour, minute: runMinute, timeZone: zone)
    }

    @Test func footerSaysTodayBeforeRunTimeAndTomorrowAfter() {
        #expect(nextText(5, 0) == "Next digest today at 6:30 am")
        #expect(nextText(6, 29) == "Next digest today at 6:30 am")
        #expect(nextText(6, 30) == "Next digest tomorrow at 6:30 am")
        #expect(nextText(9, 0) == "Next digest tomorrow at 6:30 am")
    }

    @Test func whenTextDropsTheLeadIn() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 0))!
        #expect(NextDigestText.when(now: now, hour: 6, minute: 30, timeZone: zone) == "tomorrow at 6:30 am")
        #expect(NextDigestText.when(now: now, hour: 17, minute: 5, timeZone: zone) == "today at 5:05 pm")
    }

    @Test func footerFormatsTwelveHourTimes() {
        #expect(nextText(9, 0, runHour: 0, runMinute: 5) == "Next digest tomorrow at 12:05 am")
        #expect(nextText(9, 0, runHour: 12, runMinute: 0) == "Next digest today at 12:00 pm")
        #expect(nextText(9, 0, runHour: 18, runMinute: 45) == "Next digest today at 6:45 pm")
        #expect(nextText(9, 0, runHour: 23, runMinute: 59) == "Next digest today at 11:59 pm")
    }

    // MARK: Job actions and row text

    @Test func jobActionsFollowState() {
        let running = BacklogJobActions(state: .running, isLoaded: true, anotherJobRuns: false)
        #expect(running.canPause && running.canStop && !running.canResume && !running.canDelete && running.canRename)
        let paused = BacklogJobActions(state: .paused, isLoaded: true, anotherJobRuns: false)
        #expect(!paused.canPause && paused.canStop && paused.canResume && !paused.canDelete)
        let stopped = BacklogJobActions(state: .stopped, isLoaded: false, anotherJobRuns: false)
        #expect(!stopped.canPause && !stopped.canStop && stopped.canResume && stopped.canDelete)
        let finished = BacklogJobActions(state: .finished, isLoaded: false, anotherJobRuns: false)
        #expect(!finished.canResume && !finished.canStop && finished.canDelete)
        #expect(!BacklogJobActions(state: .stopped, isLoaded: false, anotherJobRuns: true).canResume)
        #expect(BacklogJobActions(state: .paused, isLoaded: false, anotherJobRuns: false).canDelete)
    }

    @Test func rowText() {
        let mailboxes = [MailboxRef(account: "iCloud", name: "Inbox"), MailboxRef(account: "Outlook", name: "Inbox"),
                         MailboxRef(account: "iCloud", name: "Archive")]
        let job = Job(id: UUID(), kind: .backlog, mailboxes: mailboxes, scopeFrom: .distantPast, scopeTo: .now,
                      state: .running, createdAt: .now, totals: JobTotals(queued: 48, done: 52, failed: 0, skipped: 0),
                      autoPaused: false)
        #expect(BacklogRowText.percent(job.totals) == 52)
        #expect(BacklogRowText.percent(JobTotals(queued: 0, done: 0, failed: 0, skipped: 0)) == nil)
    }

    @Test func jobNameDecodesFromOlderData() throws {
        let job = Job(id: UUID(), kind: .backlog, mailboxes: [], scopeFrom: .distantPast, scopeTo: .now,
                      state: .finished, createdAt: .now, totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0),
                      autoPaused: false, name: "October")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object["name"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Job.self, from: old).name == nil)
    }

    @Test func renameKeepsNameAcrossRunnerUpdates() async throws {
        let store = InMemoryDigestStore()
        var job = Job(id: UUID(), kind: .backlog, mailboxes: [], scopeFrom: .distantPast, scopeTo: .now,
                      state: .running, createdAt: .now, totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0),
                      autoPaused: false)
        try await store.createJob(job)
        try await store.renameJob(id: job.id, name: "October")
        job.state = .paused
        try await store.updateJob(job)
        let stored = try #require(try await store.jobs().first)
        #expect(stored.name == "October" && stored.state == .paused)
        try await store.renameJob(id: job.id, name: nil)
        #expect(try await store.jobs().first?.name == nil)
    }
}
