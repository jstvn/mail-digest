import Foundation
import Testing
@testable import MailDigestCore

@Suite struct ReviewCanvasLogicTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = PreviewFixtures.timeZone
        return c
    }

    private func record(_ n: Int, created: Date, confidence: Double = 0.8) -> SuggestionRecord {
        let s = Suggestion(id: UUID(), emailID: "e\(n)", title: "Task \(n)", due: nil, dueHasTime: false,
                           priority: .medium, evidence: "x", confidence: confidence, preselected: true,
                           flags: [], status: .pending, reminderID: nil)
        return SuggestionRecord(suggestion: s, digestID: UUID(), digestCreatedAt: created, kind: .daily,
                                category: .other, email: nil)
    }

    @Test func groupsByDayKeepingOrder() {
        let now = PreviewFixtures.now
        let a = record(1, created: now), b = record(2, created: now.addingTimeInterval(-60))
        let c = record(3, created: now.addingTimeInterval(-3 * 86_400))
        let groups = ReviewCanvasLogic.groupByDay([a, b, c], calendar: calendar)
        #expect(groups.count == 2)
        #expect(groups[0].records.map(\.id) == [a.id, b.id])
        #expect(groups[1].records.map(\.id) == [c.id])
        #expect(groups[0].day > groups[1].day)
    }

    @Test func pageKeepsHighestConfidenceInOrder() {
        let now = PreviewFixtures.now
        let low = record(1, created: now, confidence: 0.5)
        let high = record(2, created: now, confidence: 0.9)
        let mid = record(3, created: now, confidence: 0.7)
        let page = ReviewCanvasLogic.page([low, high, mid], limit: 2, showAll: false)
        #expect(page.visible.map(\.id) == [high.id, mid.id])
        #expect(page.hiddenCount == 1)
        #expect(ReviewCanvasLogic.page([low, high, mid], limit: 2, showAll: true).hiddenCount == 0)
        #expect(ReviewCanvasLogic.page([low, high, mid], limit: nil, showAll: false).visible.count == 3)
    }

    @Test func carriedPinsSkipShownDigestsAndEmails() {
        func pin(_ email: String, digest: UUID) -> PinnedInfo {
            PinnedInfo(item: InfoItem(id: email, emailID: email, category: .other, importance: 3, summary: "s",
                                      keyFacts: [], pinned: true), digestID: digest, digestCreatedAt: PreviewFixtures.now)
        }
        let today = UUID(), old = UUID()
        let pins = [pin("a", digest: today), pin("b", digest: old), pin("c", digest: old)]
        let carried = ReviewCanvasLogic.carriedPins(pins, excludingDigests: [today], shownEmailIDs: ["c"])
        #expect(carried.map(\.item.emailID) == ["b"])
    }

    private func record(_ n: Int, status: SuggestionStatus) -> SuggestionRecord {
        var r = record(n, created: PreviewFixtures.now)
        r.suggestion.status = status
        return r
    }

    @Test func splitKeepsFailedActionable() {
        let all = [record(1, status: .pending), record(2, status: .failed), record(3, status: .approved),
                   record(4, status: .dismissed)]
        let split = ReviewCanvasLogic.split(all)
        #expect(split.actionable.map(\.id) == [all[0].id, all[1].id])
        #expect(split.settled.map(\.id) == [all[2].id, all[3].id])
    }

    @Test func pageReportsScope() {
        let records = (0..<30).map { record($0, created: PreviewFixtures.now) }
        let partial = ReviewCanvasLogic.page(records, limit: 25, showAll: false)
        #expect(partial.shownCount == 25 && partial.totalCount == 30 && partial.isPartial)
        #expect(partial.countText == "25 of 30")
        let all = ReviewCanvasLogic.page(records, limit: 25, showAll: true)
        #expect(all.shownCount == 30 && all.totalCount == 30 && !all.isPartial && all.countText == "30")
    }

    @Test func scopeTexts() {
        #expect(ReviewCanvasLogic.showingText(shown: 50, total: 130) == "Showing 50 of 130")
        #expect(ReviewCanvasLogic.selectionText(selected: 3, shown: 25, isPartial: true) == "3 selected of 25 shown")
        #expect(ReviewCanvasLogic.selectionText(selected: 3, shown: 25, isPartial: false) == "3 selected")
    }

    @Test func nextStartOfDayUsesTheCalendarZone() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let next = ReviewCanvasLogic.nextStartOfDay(after: now, calendar: c)
        #expect(next > now && next.timeIntervalSince(now) <= 86_400 + 3_600)
        #expect(c.startOfDay(for: next) == next)
        // Exactly at midnight, the next one is a day later.
        #expect(ReviewCanvasLogic.nextStartOfDay(after: next, calendar: c) > next)
    }
}
