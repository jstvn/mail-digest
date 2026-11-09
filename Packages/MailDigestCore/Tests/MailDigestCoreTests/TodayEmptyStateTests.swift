import Foundation
import Testing
@testable import MailDigestCore

@Suite struct TodayEmptyStateTests {
    static let zone = TimeZone(identifier: "Australia/Brisbane")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    static func at(_ h: Int, _ m: Int = 0, _ s: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }

    static func state(_ now: Date, ever: Bool = true, problem: TodayEmptyState.Problem? = nil) -> TodayEmptyState {
        TodayEmptyState(now: now, runHour: 6, runMinute: 30, timeZone: zone, hasEverRun: ever, problem: problem)
    }

    @Test func firstLaunchWinsOverTheTimeOfDay() {
        for now in [Self.at(5, 40), Self.at(9)] {
            let s = Self.state(now, ever: false)
            #expect(s.title == "No Digest Yet")
            #expect(s.description == "Your first digest runs at 6:30 am.")
        }
    }

    @Test func beforeTheScheduledTime() {
        let s = Self.state(Self.at(6, 29, 59))
        #expect(s.title == "Not Ready Yet")
        #expect(s.description == "Today's digest runs at 6:30 am. You can run it now instead.")
    }

    @Test func exactlyAtTheScheduledTimeCountsAsAfter() {
        #expect(Self.state(Self.at(6, 30)).title == "Today's Digest Didn't Run")
    }

    @Test func afterTheTimeWithNoKnownReason() {
        let s = Self.state(Self.at(8))
        #expect(s.title == "Today's Digest Didn't Run")
        #expect(s.description == "Your Mac may have been asleep or Mail Digest wasn't open at 6:30 am.")
    }

    @Test func afternoonRunTimeIsTwelveHour() {
        let s = TodayEmptyState(now: Self.at(9), runHour: 18, runMinute: 5, timeZone: Self.zone, hasEverRun: true, problem: nil)
        #expect(s.description == "Today's digest runs at 6:05 pm. You can run it now instead.")
    }

    @Test func realReasonsAreUsedAfterTheTime() {
        let now = Self.at(8)
        #expect(Self.state(now, problem: .failed(reason: "Ollama isn't running")).description
                == "The digest stopped before it finished. Ollama isn't running.")
        #expect(Self.state(now, problem: .failed(reason: "Ollama stopped responding.")).description
                == "The digest stopped before it finished. Ollama stopped responding.")
        #expect(Self.state(now, problem: .failed(reason: nil)).description == "The digest stopped before it finished.")
        #expect(Self.state(now, problem: .paused(.battery)).description
                == "The digest is paused (battery power).")
        #expect(Self.state(now, problem: .paused(nil)).description == "The digest is paused.")
        #expect(Self.state(now, problem: .stopped).description
                == "The digest was stopped before it finished.")
        #expect(Self.state(now, problem: .startFailed(reason: "Ollama isn't running.")).description
                == "Mail Digest couldn't start the digest. Ollama isn't running.")
        #expect(Self.state(now, problem: .unfinished).title == "Today's Digest Didn't Run")
    }

    @Test func aKnownProblemOutranksFirstLaunchAndBeforeSchedule() {
        let first = Self.state(Self.at(9), ever: false, problem: .failed(reason: "Ollama isn't running"))
        #expect(first.title == "Today's Digest Didn't Run")
        #expect(first.description == "The digest stopped before it finished. Ollama isn't running.")
        let early = Self.state(Self.at(5), problem: .paused(.battery))
        #expect(early.title == "Today's Digest Didn't Run")
        #expect(early.description == "The digest is paused (battery power).")
        #expect(Self.state(Self.at(5), ever: false, problem: .stopped).title == "Today's Digest Didn't Run")
    }

    @Test func aRunningJobIsNotReportedAsMissed() {
        #expect(Self.state(Self.at(8), problem: .running).title == "Today's Digest Is Running")
        #expect(Self.state(Self.at(5), problem: .running).title == "Today's Digest Is Running")
    }

    @Test func nextChangeIsTheEarlierOfRunTimeAndTheHour() {
        func next(_ now: Date) -> Date {
            TodayEmptyState.nextChange(after: now, runHour: 6, runMinute: 30, calendar: Self.calendar, runTimeZone: Self.zone)
        }
        #expect(next(Self.at(5, 40)) == Self.at(6))
        #expect(next(Self.at(6)) == Self.at(6, 30))
        #expect(next(Self.at(6, 30)) == Self.at(7))
        #expect(next(Self.at(6, 29, 59)) == Self.at(6, 30))
        #expect(next(Self.at(23, 30)) == Self.at(0, day: 11))
    }

    @Test func nextChangeIsTheNextHourEvenWhenTheRunTimeIsTomorrow() {
        let next = TodayEmptyState.nextChange(after: Self.at(23, 50), runHour: 0, runMinute: 30,
                                              calendar: Self.calendar, runTimeZone: Self.zone)
        #expect(next == Self.at(0, day: 11))
    }
}
