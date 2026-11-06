import Foundation
import Testing
@testable import MailDigestCore

private func digest(emails: [String]) -> Digest {
    let suggestions = emails.map { id in
        Suggestion(id: UUID(), emailID: id, title: "Task \(id)", due: nil, dueHasTime: false, priority: .medium,
                   evidence: "x", confidence: 0.9, preselected: true, flags: [], status: .pending, reminderID: nil)
    }
    return Digest(id: UUID(), createdAt: PreviewFixtures.now, headline: "H", emailCount: emails.count,
                  suggestions: suggestions, info: [], skipped: [])
}

@Suite struct BacklogBatchingTests {
    private let order = (1...120).map { "m\($0)" }

    @Test func groupsResultsIntoBatchesOf50InJobOrder() {
        let b = BacklogBatching(jobOrder: order, resultIDs: Set(order))
        #expect(b.batchCount == 3)
        #expect(b.ids(inBatch: 0) == Set(order[0..<50]))
        #expect(b.ids(inBatch: 1) == Set(order[50..<100]))
        #expect(b.ids(inBatch: 2) == Set(order[100...]))
        #expect(b.title(batch: 1) == "Batch 2 of 3 · emails 51 to 100")
        #expect(b.title(batch: 2) == "Batch 3 of 3 · emails 101 to 120")
    }

    @Test func onlyEmailsWithResultsCountSoBatchesFillLive() {
        // 3,000 queued emails but only 52 finished so far: two batches, the second has two emails.
        let b = BacklogBatching(jobOrder: (1...3000).map { "m\($0)" }, resultIDs: Set((1...52).map { "m\($0)" }))
        #expect(b.batchCount == 2)
        #expect(b.ids(inBatch: 1) == ["m51", "m52"])
        // A new result lands in the last batch without moving the earlier ones.
        let more = BacklogBatching(jobOrder: (1...3000).map { "m\($0)" }, resultIDs: Set((1...53).map { "m\($0)" }))
        #expect(more.ids(inBatch: 0) == b.ids(inBatch: 0))
        #expect(more.ids(inBatch: 1) == ["m51", "m52", "m53"])
    }

    @Test func emptyAndSingleBatchTitlesAndClamping() {
        let none = BacklogBatching(jobOrder: [], resultIDs: [])
        #expect(none.batchCount == 1 && none.ids(inBatch: 0).isEmpty && none.title(batch: 0) == "No results yet")
        let few = BacklogBatching(jobOrder: ["a", "b", "c"], resultIDs: ["a", "b", "c"])
        #expect(few.title(batch: 0) == "Emails 1 to 3")
        #expect(few.clamped(9) == 0 && few.clamped(-1) == 0)
        let one = BacklogBatching(jobOrder: ["a"], resultIDs: ["a"])
        #expect(one.title(batch: 0) == "Email 1")
    }

    @Test func duplicateIdsCountOnce() {
        let b = BacklogBatching(jobOrder: ["a", "a", "b"], resultIDs: ["a", "b"])
        #expect(b.emailIDs == ["a", "b"])
    }

    @Test func slicesADigestToOneBatch() {
        let ids = order
        let d = digest(emails: ids)
        let b = BacklogBatching(jobOrder: ids, resultIDs: Set(ids), size: 50)
        let second = b.digest(d, batch: 1)
        #expect(second.suggestions.count == 50 && second.emailCount == 50 && second.id == d.id)
        #expect(second.suggestions.first?.emailID == "m51" && second.suggestions.last?.emailID == "m100")
        #expect(second.headline == "H")
        // Nothing is removed from the source digest.
        #expect(d.suggestions.count == 120)
    }
}
