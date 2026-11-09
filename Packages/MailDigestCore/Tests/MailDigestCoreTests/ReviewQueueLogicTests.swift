import Foundation
import Testing
@testable import MailDigestCore

private func record(priority: Priority = .medium, category: Category = .other, due: Date? = nil) -> SuggestionRecord {
    let s = Suggestion(id: UUID(), emailID: "e", title: "Title", due: due, dueHasTime: false, priority: priority,
                       evidence: "q", confidence: 0.9, preselected: true, flags: [], status: .pending, reminderID: nil)
    return SuggestionRecord(suggestion: s, digestID: UUID(), digestCreatedAt: Date(timeIntervalSince1970: 0),
                            kind: .daily, category: category, email: nil)
}

@Suite struct ReviewQueueFilterTests {
    @Test func inactiveFilterKeepsEverything() {
        let rs = [record(), record(priority: .high)]
        #expect(!ReviewQueueFilter().isActive)
        #expect(ReviewQueueFilter().apply(to: rs) == rs)
    }

    @Test func criteriaCombine() {
        let due = Date(timeIntervalSince1970: 1000)
        let a = record(priority: .high, category: .events, due: due)
        let b = record(priority: .high, category: .work)
        let c = record(priority: .low, category: .events, due: due)
        #expect(ReviewQueueFilter(priority: .high).apply(to: [a, b, c]) == [a, b])
        #expect(ReviewQueueFilter(category: .events).apply(to: [a, b, c]) == [a, c])
        #expect(ReviewQueueFilter(hasDueDate: true).apply(to: [a, b, c]) == [a, c])
        #expect(ReviewQueueFilter(priority: .high, category: .events, hasDueDate: true).apply(to: [a, b, c]) == [a])
    }
}

@Suite struct ReviewQueueNavigationTests {
    private let ids = (0..<4).map { _ in UUID() }

    @Test func keptWhenStillPresent() {
        #expect(ReviewQueueNavigation.selection(afterChange: ids[1], old: ids, new: [ids[1], ids[3]]) == ids[1])
    }

    @Test func movesToNextThenPreviousThenNil() {
        #expect(ReviewQueueNavigation.selection(afterChange: ids[1], old: ids, new: [ids[0], ids[2], ids[3]]) == ids[2])
        #expect(ReviewQueueNavigation.selection(afterChange: ids[3], old: ids, new: Array(ids[0...2])) == ids[2])
        // The next row is also gone: skip to the next survivor.
        #expect(ReviewQueueNavigation.selection(afterChange: ids[0], old: ids, new: [ids[3]]) == ids[3])
        #expect(ReviewQueueNavigation.selection(afterChange: ids[0], old: ids, new: []) == nil)
        #expect(ReviewQueueNavigation.selection(afterChange: nil, old: ids, new: ids) == nil)
    }

    @Test func stepClampsAndHandlesNoSelection() {
        #expect(ReviewQueueNavigation.step(from: ids[0], by: -1, in: ids) == ids[0])
        #expect(ReviewQueueNavigation.step(from: ids[3], by: 1, in: ids) == ids[3])
        #expect(ReviewQueueNavigation.step(from: ids[1], by: 1, in: ids) == ids[2])
        #expect(ReviewQueueNavigation.step(from: nil, by: 1, in: ids) == ids[0])
        #expect(ReviewQueueNavigation.step(from: nil, by: -1, in: ids) == ids[3])
        #expect(ReviewQueueNavigation.step(from: nil, by: 1, in: []) == nil)
    }

    @Test func positionCountsWithinTheGivenList() {
        #expect(ReviewQueueNavigation.positionText(of: ids[0], in: ids) == "1 of 4")
        #expect(ReviewQueueNavigation.positionText(of: ids[2], in: [ids[2], ids[3]]) == "1 of 2")
        #expect(ReviewQueueNavigation.positionText(of: nil, in: ids) == nil)
        #expect(ReviewQueueNavigation.positionText(of: ids[0], in: [ids[1]]) == nil)
    }
}

@Suite struct EvidenceHighlightTests {
    private func found(_ quote: String, in text: String) -> String? {
        EvidenceHighlight.range(of: quote, in: text).map { String(text[$0]) }
    }

    @Test func findsExactQuote() {
        #expect(found("Friday 20 November", in: "Hi, see you Friday 20 November at 5:30.") == "Friday 20 November")
    }

    @Test func ignoresCase() {
        #expect(found("friday 20 NOVEMBER", in: "see you Friday 20 November.") == "Friday 20 November")
    }

    @Test func toleratesWhitespaceDifferences() {
        #expect(found("Friday 20 November", in: "see you Friday\n  20   November at") == "Friday\n  20   November")
        #expect(found("  Friday   20 November ", in: "Friday 20 November") == "Friday 20 November")
    }

    @Test func nilWhenMissingOrEmpty() {
        #expect(EvidenceHighlight.range(of: "Saturday", in: "see you Friday") == nil)
        #expect(EvidenceHighlight.range(of: "   ", in: "see you Friday") == nil)
        #expect(EvidenceHighlight.range(of: "longer than the text", in: "short") == nil)
    }

    @Test func wholeTextWhenQuoteIsTheExcerpt() {
        let text = "Bring an idea to life."
        #expect(EvidenceHighlight.range(of: text, in: text) == text.startIndex..<text.endIndex)
    }
}
