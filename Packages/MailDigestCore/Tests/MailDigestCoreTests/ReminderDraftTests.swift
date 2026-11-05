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

@Suite struct ReminderDraftTests {
    @Test func dateOnlyDueUsesDayAndNineAMAlarm() {
        // 2026-03-05 00:00 Brisbane (UTC+10) is 2026-03-04 14:00 UTC.
        let d = ReminderDraft(make(due: utc(2026, 3, 4, 14, 0), hasTime: false), category: .finance, email: nil,
                              timeZone: brisbane)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 5))
        // 09:00 Brisbane is 23:00 UTC the previous day.
        #expect(d.alarmDate == utc(2026, 3, 4, 23, 0))
    }

    @Test func timedDueIncludesHourMinuteAndAlarmOneHourBefore() {
        // 2026-03-05 23:30 Brisbane = 13:30 UTC, near midnight local.
        let due = utc(2026, 3, 5, 13, 30)
        let d = ReminderDraft(make(due: due, hasTime: true), category: .other, email: nil, timeZone: brisbane)
        #expect(d.dueComponents == DateComponents(year: 2026, month: 3, day: 5, hour: 23, minute: 30))
        #expect(d.alarmDate == due.addingTimeInterval(-3600))
    }

    @Test func noDueMeansNoComponentsOrAlarm() {
        let d = ReminderDraft(make(due: nil, hasTime: false), category: .other, email: nil, timeZone: brisbane)
        #expect(d.dueComponents == nil)
        #expect(d.alarmDate == nil)
    }

    @Test func priorityMapping() {
        func p(_ x: Priority) -> Int {
            ReminderDraft(make(due: nil, hasTime: false, priority: x), category: .other, email: nil).priority
        }
        #expect(p(.high) == 1 && p(.medium) == 5 && p(.low) == 9)
    }

    @Test func titleNotesAndURL() {
        let email = EmailContext(sender: "a@b.c", subject: "Hi", mailbox: box)
        let d = ReminderDraft(make(due: nil, hasTime: false), category: .finance, email: email)
        #expect(d.title == "Pay fees")
        #expect(d.notes == "From: a@b.c\nSubject: Hi\n\"pay by Friday\"\n#finance")
        #expect(d.url.absoluteString == "message://%3Cid@x.com%3E")
    }
}
