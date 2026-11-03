import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func ctx(_ account: String = "iCloud") -> EmailContext {
    EmailContext(sender: "a@b.com", subject: "s", mailbox: MailboxRef(account: account, name: "Inbox"))
}
private func sug(_ email: String, _ status: SuggestionStatus) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: "t", due: nil, dueHasTime: false, priority: .medium,
               evidence: "e", confidence: 0.9, preselected: true, flags: [], status: status, reminderID: nil)
}
private func info(_ email: String, _ cat: Category = .uni) -> InfoItem {
    InfoItem(id: email, emailID: email, category: cat, importance: 3, summary: "sum \(email)", keyFacts: [], pinned: false)
}
private func skip(_ id: String, _ reason: String) -> SkippedEmail {
    SkippedEmail(id: id, sender: "x", subject: "y", reason: reason)
}
private func digest(_ s: [Suggestion] = [], info: [InfoItem] = [], skipped: [SkippedEmail] = []) -> Digest {
    Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 1, suggestions: s, info: info, skipped: skipped)
}
private func all(_ ids: String...) -> [String: EmailContext] { Dictionary(uniqueKeysWithValues: ids.map { ($0, ctx()) }) }

@Suite struct ProcessedEmailSelectorTests {
    let sel = ProcessedEmailSelector()

    @Test func onlyFullyProcessedAreEligible() {
        let d = digest([sug("e1", .approved), sug("e2", .pending), sug("e3", .failed)],
                       info: [info("e1"), info("e2"), info("e3"), info("e4")])
        let r = sel.entries(digest: d, emails: all("e1", "e2", "e3", "e4"))
        #expect(r.handled.map(\.id) == ["e1", "e4"])
        #expect(r.handled.allSatisfy { $0.selected })
    }

    @Test func mixedPendingBlocksEvenWithApproved() {
        let d = digest([sug("e1", .approved), sug("e1", .pending)], info: [info("e1")])
        #expect(sel.entries(digest: d, emails: all("e1")).handled.isEmpty)
    }

    @Test func outcomeText() {
        let d = digest([sug("e1", .approved), sug("e1", .approved), sug("e2", .approved),
                        sug("e3", .dismissed), sug("e3", .dismissed)],
                       info: [info("e1"), info("e2"), info("e3"), info("e4")])
        let r = sel.entries(digest: d, emails: all("e1", "e2", "e3", "e4"))
        #expect(r.handled.map(\.outcome) == ["2 reminders added", "1 reminder added", "info only", "info only"])
        #expect(r.handled[0].summary == "sum e1")
    }

    @Test func failedAndNotFoundNeverEligible() {
        let d = digest(info: [info("e1")],
                       skipped: [skip("e1", "failed: timeout"), skip("e2", "failed: x"), skip("e3", "not found in Mail")])
        let r = sel.entries(digest: d, emails: all("e1", "e2", "e3"))
        #expect(r.handled.isEmpty)
        #expect(r.blocked.isEmpty)
    }

    @Test func blockedListedSeparately() {
        let d = digest(info: [info("e1")], skipped: [skip("b1", "blocked sender"), skip("b2", "ignored sender")])
        let r = sel.entries(digest: d, emails: all("e1", "b1", "b2"))
        #expect(r.handled.map(\.id) == ["e1"])
        #expect(r.blocked.map(\.id) == ["b1", "b2"])
        #expect(r.blocked[0].outcome == "blocked sender")
        #expect(r.blocked[0].summary == nil)
    }

    @Test func missingContextLeftOut() {
        let d = digest(info: [info("e1"), info("e2")], skipped: [skip("b1", "blocked sender")])
        let r = sel.entries(digest: d, emails: all("e2"))
        #expect(r.handled.map(\.id) == ["e2"])
        #expect(r.blocked.isEmpty)
    }

    @Test func excludingDropsIDs() {
        let d = digest(info: [info("e1"), info("e2")], skipped: [skip("b1", "blocked sender")])
        let r = sel.entries(digest: d, emails: all("e1", "e2", "b1"), excluding: ["e1", "b1"])
        #expect(r.handled.map(\.id) == ["e2"])
        #expect(r.blocked.isEmpty)
    }

    @Test func groupsByAccountKeepingOrder() {
        let d = digest(info: [info("e1"), info("e2"), info("e3")])
        let emails = ["e1": ctx("Outlook"), "e2": ctx("iCloud"), "e3": ctx("Outlook")]
        let groups = sel.grouped(sel.entries(digest: d, emails: emails).handled)
        #expect(groups.map(\.account) == ["iCloud", "Outlook"])
        #expect(groups.first { $0.account == "Outlook" }?.entries.map(\.id) == ["e1", "e3"])
    }

    @Test func newsletterShortcut() {
        let d = digest(info: [info("e1", .newsletters), info("e2", .uni), info("e3", .newsletters)])
        let h = sel.entries(digest: d, emails: all("e1", "e2", "e3")).handled
        #expect(sel.newsletterIDs(h) == ["e1", "e3"])
    }
}
