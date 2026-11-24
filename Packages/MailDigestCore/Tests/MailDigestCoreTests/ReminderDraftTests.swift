import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func make(due: Date?, hasTime: Bool, priority: Priority = .medium) -> Suggestion {
    Suggestion(id: UUID(), emailID: "id@x.com", title: "Pay fees", due: due, dueHasTime: hasTime,
               priority: priority, evidence: "pay by Friday", confidence: 0.9, preselected: true, flags: [],
               status: .pending, reminderID: nil)
}

/// A Brisbane (UTC+10, no daylight saving) wall-clock moment.
private func bris(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = brisbane
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Mon 2 Mar 2026 12:00 Brisbane.
private let noon = bris(2026, 3, 2, 12, 0)
private let deadlineMode = ReminderDatePolicy(mode: .emailDeadline)
private let planMode = ReminderDatePolicy(mode: .planToday)

private func draft(_ s: Suggestion, _ policy: ReminderDatePolicy, now: Date) -> ReminderDraft {
    ReminderDraft(s, category: .other, email: nil, policy: policy, now: now, timeZone: brisbane)
}

@Suite struct ReminderDraftTests {
    @Test func dateOnlyDueUsesDayAndNineAMAlarm() {
        // 2026-03-05 00:00 Brisbane (UTC+10) is 2026-03-04 14:00 UTC.
        let d = ReminderDraft(make(due: utc(2026, 3, 4, 14, 0), hasTime: false), category: .finance, email: nil,
                              policy: deadlineMode, now: noon, timeZone: brisbane)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 5))
        // 09:00 Brisbane is 23:00 UTC the previous day.
        #expect(d.alarmDate == utc(2026, 3, 4, 23, 0))
    }

    @Test func timedDueIncludesHourMinuteAndAlarmOneHourBefore() {
        // 2026-03-05 23:30 Brisbane = 13:30 UTC, near midnight local.
        let due = utc(2026, 3, 5, 13, 30)
        let d = ReminderDraft(make(due: due, hasTime: true), category: .other, email: nil, policy: deadlineMode,
                              now: noon, timeZone: brisbane)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 5, hour: 23, minute: 30))
        #expect(d.alarmDate == due.addingTimeInterval(-3600))
    }

    @Test func undatedAlwaysGetsADate() {
        let d = ReminderDraft(make(due: nil, hasTime: false), category: .other, email: nil, policy: deadlineMode,
                              now: noon, timeZone: brisbane)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
        #expect(d.alarmDate == bris(2026, 3, 2, 20, 0))
    }

    @Test func priorityMapping() {
        func p(_ x: Priority) -> Int {
            ReminderDraft(make(due: nil, hasTime: false, priority: x), category: .other, email: nil, now: noon).priority
        }
        #expect(p(.high) == 1 && p(.medium) == 5 && p(.low) == 9)
    }

    @Test func titleNotesAndURL() {
        let email = EmailContext(sender: "a@b.c", subject: "Hi", mailbox: box)
        let d = ReminderDraft(make(due: nil, hasTime: false), category: .finance, email: email, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.notes == "From a@b.c · Hi\n\"pay by Friday\"\n#finance")
        #expect(d.url.absoluteString == "message://%3Cid@x.com%3E")
    }

    // MARK: Q101 plan-ahead mode

    @Test func planTodayBeforePlanTimeLandsToday() {
        let d = draft(make(due: bris(2026, 3, 20, 0, 0), hasTime: false), planMode, now: noon)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
        #expect(d.alarmDate == bris(2026, 3, 2, 20, 0))
    }

    @Test func planTodayAtOrAfterPlanTimeLandsTomorrow() {
        let after = draft(make(due: nil, hasTime: false), planMode, now: bris(2026, 3, 2, 21, 30))
        #expect(after.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 20, minute: 0))
        #expect(after.alarmDate == bris(2026, 3, 3, 20, 0))
        // Exactly at the plan time counts as passed.
        let exact = draft(make(due: nil, hasTime: false), planMode, now: bris(2026, 3, 2, 20, 0))
        #expect(exact.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 20, minute: 0))
        // One minute before does not.
        let before = draft(make(due: nil, hasTime: false), planMode, now: bris(2026, 3, 2, 19, 59))
        #expect(before.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
    }

    @Test func planTodayTimedDueLaterThanTargetGetsSuffixWithTime() {
        let d = draft(make(due: bris(2026, 12, 1, 15, 0), hasTime: true), planMode, now: noon)
        #expect(d.title == "Pay fees (due Tue 1 Dec, 3:00 pm)")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
        #expect(d.alarmDate == bris(2026, 3, 2, 20, 0))
    }

    @Test func planTodayTimedDueEarlierThanTargetIsWrittenAsDeadline() {
        let due = bris(2026, 3, 2, 15, 0)
        let d = draft(make(due: due, hasTime: true), planMode, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 15, minute: 0))
        #expect(d.alarmDate == due.addingTimeInterval(-3600))
    }

    @Test func planTodayTimedDueExactlyAtTargetHasNoSuffix() {
        let d = draft(make(due: bris(2026, 3, 2, 20, 0), hasTime: true), planMode, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
        #expect(d.alarmDate == bris(2026, 3, 2, 20, 0))
    }

    @Test func planTodayTimedDueSameDayLaterTimeKeepsSuffix() {
        let d = draft(make(due: bris(2026, 3, 2, 22, 0), hasTime: true), planMode, now: noon)
        #expect(d.title == "Pay fees (due Mon 2 Mar, 10:00 pm)")
        #expect(d.dueComponents?.hour == 20)
    }

    @Test func planTodayDateOnlyDueTodayBeforePlanTimeHasNoSuffix() {
        // End of today is after 20:00 today, so the plan time applies and the dates match.
        let d = draft(make(due: bris(2026, 3, 2, 0, 0), hasTime: false), planMode, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
        #expect(d.alarmDate == bris(2026, 3, 2, 20, 0))
    }

    @Test func planTodayDateOnlyDueTodayAfterPlanTimeIsWrittenAsDeadline() {
        // Target is tomorrow 20:00, later than the end of today: date-only rules, nine AM alarm.
        let d = draft(make(due: bris(2026, 3, 2, 0, 0), hasTime: false), planMode, now: bris(2026, 3, 2, 21, 0))
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2))
        #expect(d.alarmDate == bris(2026, 3, 2, 9, 0))
    }

    @Test func planTodayDateOnlyDueTomorrowAfterPlanTimeHasNoSuffix() {
        let d = draft(make(due: bris(2026, 3, 3, 0, 0), hasTime: false), planMode, now: bris(2026, 3, 2, 21, 0))
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 20, minute: 0))
    }

    @Test func planTodayDateOnlyDueTomorrowBeforePlanTimeGetsDateSuffix() {
        let d = draft(make(due: bris(2026, 3, 3, 0, 0), hasTime: false), planMode, now: noon)
        #expect(d.title == "Pay fees (due Tue 3 Mar)")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
    }

    @Test func planTodayDateOnlyDueLaterGetsDateSuffix() {
        let d = draft(make(due: bris(2026, 12, 1, 0, 0), hasTime: false), planMode, now: noon)
        #expect(d.title == "Pay fees (due Tue 1 Dec)")
    }

    @Test func planTodayUndatedHasNoSuffix() {
        let d = draft(make(due: nil, hasTime: false), planMode, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 20, minute: 0))
    }

    @Test func emailDeadlineNeverAddsSuffix() {
        let d = draft(make(due: bris(2026, 12, 1, 15, 0), hasTime: true), deadlineMode, now: noon)
        #expect(d.title == "Pay fees")
        #expect(d.dueComponents == DateComponents(year: 2026, month: 12, day: 1, hour: 15, minute: 0))
    }

    @Test func emailDeadlineUndatedUsesCustomPlanTimeAndTomorrowRollover() {
        let policy = ReminderDatePolicy(mode: .emailDeadline, planHour: 7, planMinute: 45)
        let early = draft(make(due: nil, hasTime: false), policy, now: bris(2026, 3, 2, 6, 0))
        #expect(early.dueComponents == DateComponents(year: 2026, month: 3, day: 2, hour: 7, minute: 45))
        #expect(early.alarmDate == bris(2026, 3, 2, 7, 45))
        let late = draft(make(due: nil, hasTime: false), policy, now: bris(2026, 3, 2, 8, 0))
        #expect(late.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 7, minute: 45))
    }

    @Test func customPlanTimeAppliesInPlanMode() {
        let policy = ReminderDatePolicy(mode: .planToday, planHour: 9, planMinute: 15)
        let d = draft(make(due: bris(2026, 3, 9, 0, 0), hasTime: false), policy, now: bris(2026, 3, 2, 9, 30))
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 9, minute: 15))
        #expect(d.title == "Pay fees (due Mon 9 Mar)")
    }

    @Test func midnightPlanTimeAndTimeZoneEdge() {
        // 23:50 Brisbane is 13:50 UTC the same day; the plan day follows Brisbane, not UTC.
        let policy = ReminderDatePolicy(mode: .planToday, planHour: 0, planMinute: 0)
        let d = draft(make(due: nil, hasTime: false), policy, now: bris(2026, 3, 2, 23, 50))
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 0, minute: 0))
        // 05:00 Brisbane on 3 Mar is still 2 Mar in UTC; plan time is today (3 Mar) in Brisbane.
        let morning = draft(make(due: nil, hasTime: false), ReminderDatePolicy(), now: bris(2026, 3, 3, 5, 0))
        #expect(morning.dueComponents == DateComponents(year: 2026, month: 3, day: 3, hour: 20, minute: 0))
    }

    @Test func policyClampsOutOfRangeTime() {
        let p = ReminderDatePolicy(planHour: 30, planMinute: -5)
        #expect(p.planHour == 23 && p.planMinute == 0)
    }
}
