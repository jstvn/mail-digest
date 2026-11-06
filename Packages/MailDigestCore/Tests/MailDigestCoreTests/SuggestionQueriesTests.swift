import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func sug(_ email: String, _ status: SuggestionStatus = .pending, decided: Date? = nil,
                 category: Category? = nil) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: "Task \(email)", due: nil, dueHasTime: false, priority: .medium,
               evidence: "e", confidence: 0.9, preselected: true, flags: [], status: status, reminderID: nil,
               category: category, decidedAt: decided)
}

private func job(_ id: UUID, _ kind: JobKind) -> Job {
    Job(id: id, kind: kind, mailboxes: [box], scopeFrom: t0, scopeTo: t0, state: .finished, createdAt: t0,
        totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0), autoPaused: false, lastError: nil)
}

private func header(_ id: String) -> MessageHeader {
    MessageHeader(id: id, account: "iCloud", mailbox: "Inbox", sender: "a@x.com", subject: "S \(id)", receivedAt: t0,
                  sourceReference: MailMessageReference(messageID: id, storeRowID: 5), accountID: nil, mailboxURL: nil)
}

@Suite struct SuggestionQueriesTests {
    @Test func decidedAtDecodesAsNilFromOldJSONAndRoundTrips() throws {
        var s = sug("a")
        let old = try JSONEncoder().encode(s)
        #expect(!String(decoding: old, as: UTF8.self).contains("decidedAt"))
        #expect(try JSONDecoder().decode(Suggestion.self, from: old).decidedAt == nil)
        s.decidedAt = t0
        #expect(try JSONDecoder().decode(Suggestion.self, from: JSONEncoder().encode(s)).decidedAt == t0)
    }

    @Test func approveDismissAndFailureStampDecidedAt() async throws {
        let a = sug("e1"), b = sug("e2"), c = sug("e3")
        var failed = sug("e1", .failed)
        failed.decidedAt = t0 // a stale value must be cleared on failure
        let d = Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 3, suggestions: [a, b, c], info: [], skipped: [])
        let state = ReviewState(digest: d)
        let store = InMemoryDigestStore()
        try await store.save(d)
        let clock = FixedClock(t0.addingTimeInterval(60))
        let emails = ["e1": EmailContext(sender: "x@y.com", subject: "s", mailbox: box)]

        let writer = RecordingReminderWriter(failingSuggestionIDs: [b.id])
        let out = await ReviewActions.approve([a, b], state: state, emails: emails, writer: writer, store: store,
                                              listName: "L", storedListID: nil, clock: clock)
        #expect(out.results.map(\.decidedAt) == [t0.addingTimeInterval(60), nil])
        let dismissed = try await ReviewActions.dismiss([c], state: state, emails: emails, store: store, clock: clock)
        #expect(dismissed.results.first?.decidedAt == t0.addingTimeInterval(60))

        let stored = try #require(await store.digest(id: d.id))
        #expect(stored.suggestions.map(\.decidedAt) == [t0.addingTimeInterval(60), nil, t0.addingTimeInterval(60)])

        // A failed retry of a suggestion that carries a stale decidedAt clears it.
        failed.reminderID = nil
        let retry = await ReviewActions.approve([failed], state: state, emails: emails,
                                                writer: RecordingReminderWriter(failingSuggestionIDs: [failed.id]),
                                                store: store, listName: "L", storedListID: nil, clock: clock)
        #expect(retry.results.first?.status == .failed && retry.results.first?.decidedAt == nil)
    }

    @Test func inMemoryQueriesOrderFilterAndPage() async throws {
        let store = InMemoryDigestStore()
        let dailyID = UUID(), backlogID = UUID(), orphanID = UUID()
        try await store.createJob(job(dailyID, .daily))
        try await store.createJob(job(backlogID, .backlog))
        try await store.enqueue([header("a")], job: dailyID)
        for (id, at) in [(dailyID, t0), (backlogID, t0 - day), (orphanID, t0 - 2 * day)] {
            try await store.save(Digest(id: id, createdAt: at, headline: "h", emailCount: 0, suggestions: [], info: [], skipped: []))
        }
        let a1 = sug("a"), a2 = sug("a", .failed), b = sug("b", .pending, category: .uni)
        let done = sug("a", .approved, decided: t0 + 10), nilDecided = sug("b", .dismissed), old = sug("o", .dismissed, decided: t0 - day)
        let info = InfoItem(id: "a", emailID: "a", category: .finance, importance: 3, summary: "s", keyFacts: [], pinned: false)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: info, suggestions: [a1, a2, done]), to: dailyID)
        try await store.appendEmailResult(EmailResult(emailID: "b", suggestions: [nilDecided]), to: dailyID)
        try await store.appendEmailResult(EmailResult(emailID: "b", suggestions: [b]), to: backlogID)
        try await store.appendEmailResult(EmailResult(emailID: "o", suggestions: [old]), to: orphanID)

        let summaries = try await store.digestSummaries()
        #expect(summaries.map(\.id) == [dailyID, backlogID, orphanID])
        #expect(summaries.map(\.kind) == [.daily, .backlog, .daily])
        #expect(summaries.map(\.pendingCount) == [1, 1, 0] && summaries.map(\.failedCount) == [1, 0, 0])
        #expect(summaries.map(\.emailCount) == [2, 1, 1])

        let actionable = try await store.actionableSuggestions(SuggestionQuery(limit: 10))
        #expect(actionable.map(\.suggestion.id) == [a1.id, a2.id, b.id])
        #expect(actionable.map(\.category) == [.finance, .finance, .uni])
        #expect(actionable[0].email?.storeRowID == 5 && actionable[2].email == nil)
        #expect(try await store.actionableSuggestions(SuggestionQuery(limit: 1, offset: 1)).map(\.suggestion.id) == [a2.id])
        #expect(try await store.actionableSuggestions(SuggestionQuery(kinds: [.backlog], limit: 9)).map(\.suggestion.id) == [b.id])
        #expect(try await store.actionableSuggestions(SuggestionQuery(digestsCreatedBefore: t0, limit: 9)).map(\.suggestion.id) == [b.id])

        // done (t0+10) first, then nilDecided via its digest's createdAt (t0), then old (t0 - day).
        let logbook = try await store.decidedSuggestions(limit: 10, offset: 0)
        #expect(logbook.map(\.suggestion.id) == [done.id, nilDecided.id, old.id])
        #expect(try await store.decidedSuggestions(limit: 1, offset: 2).map(\.suggestion.id) == [old.id])
    }
}
