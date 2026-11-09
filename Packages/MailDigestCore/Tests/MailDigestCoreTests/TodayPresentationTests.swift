import Foundation
import Testing
@testable import MailDigestCore

@Suite struct TodayPresentationTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return c
    }()

    static func date(_ h: Int, _ m: Int = 0, day: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    // MARK: Greeting

    @Test func greetingBoundaries() {
        let cal = Self.calendar
        #expect(TodayGreeting.greeting(at: Self.date(0), calendar: cal) == "Good morning")
        #expect(TodayGreeting.greeting(at: Self.date(11, 59), calendar: cal) == "Good morning")
        #expect(TodayGreeting.greeting(at: Self.date(12), calendar: cal) == "Good afternoon")
        #expect(TodayGreeting.greeting(at: Self.date(17, 59), calendar: cal) == "Good afternoon")
        #expect(TodayGreeting.greeting(at: Self.date(18), calendar: cal) == "Good evening")
    }

    @Test func firstNameFromFullName() {
        #expect(TodayGreeting.firstName(fromFullName: "Justin Wang") == "Justin")
        #expect(TodayGreeting.firstName(fromFullName: "  Justin  ") == "Justin")
        #expect(TodayGreeting.firstName(fromFullName: "") == nil)
        #expect(TodayGreeting.firstName(fromFullName: "   ") == nil)
    }

    @Test func titleOmitsCommaWithoutName() {
        let now = Self.date(7)
        #expect(TodayGreeting.title(now: now, calendar: Self.calendar, fullName: "Justin Wang") == "Good morning, Justin")
        #expect(TodayGreeting.title(now: now, calendar: Self.calendar, fullName: "") == "Good morning")
    }

    @Test func greetingFollowsTheCalendarTimeZone() {
        // 20:00 UTC on 8 Nov is 06:00 on 9 Nov in Brisbane, so still morning there.
        let utc = Date(timeIntervalSince1970: Self.date(6).timeIntervalSince1970)
        #expect(TodayGreeting.greeting(at: utc, calendar: Self.calendar) == "Good morning")
    }

    @Test func dateOverline() {
        #expect(TodayGreeting.dateOverline(now: Self.date(7), calendar: Self.calendar) == "MONDAY 9 NOVEMBER")
    }

    // MARK: Run line

    private func job(start: Date?, end: Date?) -> Job {
        Job(id: UUID(), kind: .daily, mailboxes: [], scopeFrom: start ?? Self.date(0), scopeTo: Self.date(23), state: .finished,
            createdAt: start ?? Self.date(0), totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0),
            autoPaused: false, startedAt: start, endedAt: end)
    }

    private func item(_ provider: ExecutionProvider?, model: String = "qwen3:4b") -> JobItem {
        var routing: RoutingProvenance?
        if let provider {
            let assessment = PrivacyAssessment(verdict: .public, method: .rule, assessedAt: Self.date(7))
            routing = RoutingProvenance(assessment: assessment, execution: ExecutionRecord(
                provider: provider, model: model, cloudAttempted: provider == .cloud, startedAt: Self.date(7), finishedAt: Self.date(7)))
        }
        return JobItem(id: UUID(), jobID: UUID(), messageID: UUID().uuidString, mailbox: MailboxRef(account: "a", name: "Inbox"),
                       sender: "x", subject: "y", receivedAt: Self.date(6), position: 1, state: .done, outcome: nil, seconds: nil,
                       attempts: 1, lastError: nil, routing: routing, provider: provider)
    }

    @Test func localRunUsesTheRecordedModel() {
        let info = RunInfo.make(jobs: [job(start: Self.date(6, 42), end: Self.date(7, 28))],
                                items: [item(.local), item(.local), item(nil)])
        #expect(info.localEmails == 2)
        #expect(RunLine.processingText(info) == "Processed on this Mac with Qwen3 4B")
        #expect(RunLine.timingText(info, calendar: Self.calendar) == "Finished 7:28 am · 46 min")
    }

    @Test func mixedRunNamesGeminiWithItsEmailCount() {
        let items = [item(.local), item(.cloud, model: "gemini-3.5-flash-lite"), item(.cloud, model: "gemini-3.5-flash-lite"),
                     item(.cloud, model: "gemini-3.5-flash-lite")]
        let info = RunInfo.make(jobs: [job(start: Self.date(6), end: Self.date(7))], items: items)
        #expect(RunLine.processingText(info) == "On this Mac and Gemini (3 emails)")
    }

    @Test func cloudOnlyAndSingularCount() {
        let info = RunInfo.make(jobs: [], items: [item(.cloud, model: "gemini-3.5-flash-lite")])
        #expect(RunLine.processingText(info) == "Processed with Gemini 3.5 Flash-Lite (1 email)")
    }

    @Test func nothingRecordedGivesNoProcessingText() {
        let info = RunInfo.make(jobs: [], items: [item(nil)])
        #expect(RunLine.processingText(info) == nil)
    }

    @Test func provenanceWithoutAModelOmitsIt() {
        var plain = item(nil)
        plain.provider = .local
        #expect(RunLine.processingText(RunInfo.make(jobs: [], items: [plain])) == "Processed on this Mac")
    }

    @Test func mostCommonLocalModelWins() {
        let info = RunInfo.make(jobs: [], items: [item(.local, model: "qwen3:8b"), item(.local), item(.local)])
        #expect(info.localModel == "qwen3:4b")
    }

    @Test func runningJobHasNoFinishTime() {
        let info = RunInfo.make(jobs: [job(start: Self.date(6), end: nil)], items: [item(.local)])
        #expect(info.finishedAt == nil)
        #expect(RunLine.timingText(info, calendar: Self.calendar) == nil)
    }

    @Test func severalRunsSumTheirDurations() {
        let info = RunInfo.make(jobs: [job(start: Self.date(6), end: Self.date(6, 30)), job(start: Self.date(7), end: Self.date(7, 40))],
                                items: [])
        #expect(info.duration == TimeInterval(4200))
        #expect(info.finishedAt == Self.date(7, 40))
        #expect(RunLine.timingText(info, calendar: Self.calendar) == "Finished 7:40 am · 1 h 10 min")
    }

    @Test func durationText() {
        #expect(RunLine.durationText(20) == "under a minute")
        #expect(RunLine.durationText(46 * 60) == "46 min")
        #expect(RunLine.durationText(2 * 3600) == "2 h")
    }
}
