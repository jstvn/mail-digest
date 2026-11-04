import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!

/// Parses a UTC instant such as "2026-11-03T14:00:00Z".
private func utc(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

@Suite struct DateResolverTests {
    let resolver = DateResolver(timeZone: brisbane)
    // 2026-11-04 06:30 Brisbane
    let today = Date(timeIntervalSince1970: 1_793_737_800)

    @Test func dateOnlyIsLocalMidnightWithoutTime() throws {
        let r = try #require(resolver.resolve("2026-11-09", today: today))
        #expect(r.date == utc("2026-11-08T14:00:00Z"))
        #expect(!r.hasTime)
    }

    @Test func localTimeUsesTimeZone() throws {
        let r = try #require(resolver.resolve("2026-11-09T17:00", today: today))
        #expect(r.date == utc("2026-11-09T07:00:00Z"))
        #expect(r.hasTime)
    }

    @Test func secondsAndOffsetsAreHonoured() throws {
        let z = try #require(resolver.resolve("2026-11-09T17:00:30Z", today: today))
        #expect(z.date == utc("2026-11-09T17:00:30Z"))
        #expect(z.hasTime)
        let plus = try #require(resolver.resolve("2026-11-09T17:00+02:00", today: today))
        #expect(plus.date == utc("2026-11-09T15:00:00Z"))
        let minus = try #require(resolver.resolve("2026-11-09T17:00:00-0500", today: today))
        #expect(minus.date == utc("2026-11-09T22:00:00Z"))
    }

    @Test func garbageIsNil() {
        for s in ["", "tomorrow", "2026-13-01", "2026-02-30", "2026-11-9", "2026-11-09T25:00",
                  "2026-11-09T17", "2026-11-09T17:00+9", "11/09/2026", "2026-11-09Tabc"] {
            #expect(resolver.resolve(s, today: today) == nil, "\(s)")
        }
        #expect(resolver.resolve(nil, today: today) == nil)
    }

    @Test func earlierTodayIsKeptButYesterdayIsNot() {
        #expect(resolver.resolve("2026-11-04T01:00", today: today) != nil)
        #expect(resolver.resolve("2026-11-04", today: today) != nil)
        #expect(resolver.resolve("2026-11-03T23:59", today: today) == nil)
    }

    @Test func midnightBoundaryUsesLocalDay() {
        // 00:00 on 4 Nov in Brisbane, but still 3 Nov in UTC.
        let midnight = utc("2026-11-03T14:00:00Z")
        #expect(resolver.resolve("2026-11-03", today: midnight) == nil)
        #expect(resolver.resolve("2026-11-04", today: midnight) != nil)
    }

    @Test func lastSecondOfLocalDay() {
        let late = utc("2026-11-04T13:59:59Z") // 23:59:59 on 4 Nov Brisbane
        #expect(resolver.resolve("2026-11-04", today: late) != nil)
        #expect(resolver.resolve("2026-11-03", today: late) == nil)
        #expect(resolver.resolve("2027-11-04", today: late) != nil) // 365 days out
        #expect(resolver.resolve("2027-11-05", today: late) == nil) // 366 days out
    }

    @Test func explicitZRangeIsCheckedInLocalDay() {
        // 2026-11-03T20:00Z is 06:00 on 4 Nov in Brisbane, so it is today.
        #expect(resolver.resolve("2026-11-03T20:00Z", today: today) != nil)
        // 2026-11-03T10:00Z is 20:00 on 3 Nov in Brisbane, so it is yesterday.
        #expect(resolver.resolve("2026-11-03T10:00Z", today: today) == nil)
    }

    @Test func isSameDayUsesTimeZone() {
        #expect(resolver.isSameDay(utc("2026-11-03T14:00:00Z"), utc("2026-11-04T13:59:59Z")))
        #expect(!resolver.isSameDay(utc("2026-11-03T13:59:59Z"), utc("2026-11-03T14:00:00Z")))
    }
}
