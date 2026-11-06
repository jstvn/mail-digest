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
}
