import Testing
import Foundation
@testable import MailDigestCore

@Suite struct RelativeDueTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        c.firstWeekday = 2
        return c
    }()

    /// Monday 9 Nov 2026, 10:00 in Brisbane.
    static let now = date(2026, 11, 9, 10, 0)

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func make(_ due: Date?, time: Bool = false) -> RelativeDue {
        RelativeDue.make(due: due, hasTime: time, now: Self.now, calendar: Self.calendar)
    }

    @Test func nilDate() {
        #expect(make(nil) == RelativeDue(top: "No date", bottom: nil, isOverdue: false))
    }

    @Test func overdue() {
        let r = make(Self.date(2026, 11, 6, 9, 0))
        #expect(r.top == "3 days overdue")
        #expect(r.isOverdue)
        #expect(r.bottom?.contains("6 Nov") == true)
        #expect(r.bottom?.contains("2026") == false)
    }

    @Test func oneDayOverdueIsSingular() {
        #expect(make(Self.date(2026, 11, 8, 23, 0)).top == "1 day overdue")
    }

    @Test func todayWithAndWithoutTime() {
        let timed = make(Self.date(2026, 11, 9, 17, 30), time: true)
        #expect(timed.top == "Today")
        #expect(timed.bottom == "5:30 pm")
        let untimed = make(Self.date(2026, 11, 9, 17, 30))
        #expect(untimed.top == "Today")
        #expect(untimed.bottom == nil)
        #expect(!untimed.isOverdue)
    }

    @Test func tomorrow() {
        let r = make(Self.date(2026, 11, 10, 9, 0), time: true)
        #expect(r.top == "Tomorrow")
        #expect(r.bottom?.contains("10 Nov") == true)
        #expect(r.bottom?.hasSuffix("· 9:00 am") == true)
    }

    @Test func elevenDays() {
        let r = make(Self.date(2026, 11, 20, 17, 30), time: true)
        #expect(r.top == "In 11 days")
        #expect(r.bottom?.contains("20 Nov") == true)
        #expect(r.bottom?.hasSuffix("· 5:30 pm") == true)
        #expect(r.bottom?.contains("\u{202F}") == false)
    }

    @Test func twentyDaysIsTwoWeeks() {
        #expect(make(Self.date(2026, 11, 29, 9, 0)).top == "In 2 weeks")
    }

    @Test func nextYearShowsYearAndMonths() {
        let r = make(Self.date(2027, 1, 14, 9, 0))
        #expect(r.top == "In 2 months")
        #expect(r.bottom?.contains("2027") == true)
    }

    @Test func labelUsesTheInjectedTimeZone() {
        // 23:30 UTC on 9 Nov is 09:30 on 10 Nov in Brisbane: Tomorrow, not Today.
        let due = ISO8601DateFormatter().date(from: "2026-11-09T23:30:00Z")!
        let r = make(due, time: true)
        #expect(r.top == "Tomorrow")
        #expect(r.bottom?.hasSuffix("· 9:30 am") == true)
    }
}

@Suite struct SenderInitialsTests {
    @Test func twoWordName() { #expect(SenderInitials.make(sender: "Philip Fraser <p@x.com>") == "PF") }
    @Test func threeWordNameUsesFirstTwo() { #expect(SenderInitials.make(sender: "ray white estate") == "RW") }
    @Test func singleWordNameUsesTwoLetters() { #expect(SenderInitials.make(sender: "Letterboxd <hi@l.com>") == "LE") }
    @Test func bareAddressUsesLocalPart() { #expect(SenderInitials.make(sender: "justin.w@example.com") == "JU") }
    @Test func empty() { #expect(SenderInitials.make(sender: "") == "") }
    @Test func singleLetter() { #expect(SenderInitials.make(sender: "A") == "A") }
}
