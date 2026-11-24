import Foundation
import Testing
@testable import MailDigestCore

private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func sug(_ id: String, status: SuggestionStatus = .pending, preselected: Bool = true) -> Suggestion {
    Suggestion(id: UUID(), emailID: id, title: "T \(id)", due: nil, dueHasTime: false, priority: .medium,
               evidence: "x", confidence: 0.9, preselected: preselected, flags: [], status: status, reminderID: nil)
}

@Suite struct AutoAddSelectionTests {
    private func digest(_ suggestions: [Suggestion]) -> Digest {
        Digest(id: UUID(), createdAt: Date(timeIntervalSince1970: 100), headline: "", emailCount: suggestions.count,
               suggestions: suggestions, info: [InfoItem(id: "a", emailID: "a", category: .finance, importance: 3, summary: "s", keyFacts: [], pinned: false)], skipped: [])
    }

    private func items(_ digest: Digest) -> [JobItem] {
        digest.suggestions.map {
            JobItem(id: UUID(), jobID: digest.id, messageID: $0.emailID, mailbox: box, sender: "from-\($0.emailID)@x.com",
                    subject: "Subject \($0.emailID)", receivedAt: Date(timeIntervalSince1970: 50), position: 0, state: .done,
                    outcome: nil, seconds: nil, attempts: 0, lastError: nil)
        }
    }

    @Test func onlyPendingPreselectedOfADailyJob() {
        let d = digest([sug("a"), sug("b", preselected: false), sug("c", status: .failed),
                        sug("d", status: .dismissed), sug("e", status: .approved)])
        let out = AutoAddSelection.candidates(digest: d, jobKind: .daily, items: items(d))
        #expect(out.map(\.suggestion.emailID) == ["a"])
        #expect(out[0].digestID == d.id)
        #expect(out[0].kind == .daily)
        #expect(out[0].email?.sender == "from-a@x.com")
        #expect(out[0].category == .finance)
    }

    @Test func backlogJobsAreNeverAutoAdded() {
        let d = digest([sug("a")])
        #expect(AutoAddSelection.candidates(digest: d, jobKind: .backlog, items: items(d)).isEmpty)
    }

    @Test func missingItemLeavesEmailNil() {
        let d = digest([sug("a")])
        let out = AutoAddSelection.candidates(digest: d, jobKind: .daily, items: [])
        #expect(out.count == 1 && out[0].email == nil)
    }
}
