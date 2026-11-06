import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func sug(_ email: String, _ status: SuggestionStatus = .pending, preselected: Bool = true,
                 category: Category? = nil) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: "Task \(email)", due: nil, dueHasTime: false, priority: .medium,
               evidence: "e", confidence: 0.9, preselected: preselected, flags: [], status: status, reminderID: nil,
               category: category)
}

private func rec(_ s: Suggestion, digest: UUID, email: EmailContext? = nil, category: Category = .other) -> SuggestionRecord {
    SuggestionRecord(suggestion: s, digestID: digest, digestCreatedAt: t0, kind: .daily, category: category, email: email)
}

private func email(_ sender: String = "boss@x.com") -> EmailContext {
    EmailContext(sender: "Boss <\(sender)>", subject: "Subj", mailbox: box)
}

@Suite struct ReviewSessionTests {
    @Test func defaultSelectionMatchesReviewState() {
        let digest = Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 4,
                            suggestions: [sug("a"), sug("b", preselected: false), sug("c", .failed), sug("d", .approved)],
                            info: [], skipped: [])
        let state = ReviewState(digest: digest)
        let session = ReviewSession()
        for s in digest.suggestions { #expect(session.isSelected(s) == state.selection.contains(s.id)) }
    }

    @Test func toggleOnlyAffectsSelectableSuggestions() {
        var session = ReviewSession()
        let a = sug("a"), done = sug("b", .approved), failed = sug("c", .failed)
        session.toggle(a); #expect(!session.isSelected(a))
        session.toggle(a); #expect(session.isSelected(a))
        session.toggle(done); #expect(!session.isSelected(done))
        session.toggle(failed); #expect(session.isSelected(failed))
    }

    @Test func selectAllAndNoneAreScopedToTheRecordsGiven() {
        let d1 = UUID(), d2 = UUID()
        let s1 = rec(sug("a", preselected: false), digest: d1), s2 = rec(sug("b", preselected: false), digest: d1)
        let other = rec(sug("c", preselected: false), digest: d2)
        var session = ReviewSession()
        session.selectAll([s1, s2])
        #expect(session.selectedCount(in: [s1, s2, other]) == 2)
        #expect(!session.isSelected(other.suggestion))
        session.selectNone([s1])
        #expect(session.selectedCount(in: [s1, s2, other]) == 1)
        #expect(session.unselectedCount(in: [s1, s2, other]) == 2)
    }

    @Test func splitMatchesReviewActionsSplit() {
        let id = UUID()
        let all = [sug("a"), sug("b", preselected: false), sug("c", .failed), sug("d", .approved), sug("e", .dismissed)]
        let digest = Digest(id: id, createdAt: t0, headline: "h", emailCount: 5, suggestions: all, info: [], skipped: [])
        var state = ReviewState(digest: digest)
        var session = ReviewSession()
        let records = all.map { rec($0, digest: id) }
        #expect(session.split(records) == ReviewActions.split(state))
        // Selecting the failed one: approved if selected, never dismissed when not.
        state = ReviewActions.toggle(all[2].id, in: state)
        session.toggle(all[2])
        #expect(session.split(records) == ReviewActions.split(state))
        #expect(!session.split(records).dismiss.contains { $0.status == .failed })
        #expect(session.split(records).approve.map(\.id).contains(all[2].id))
    }

    @Test func applyKeepsFailedSelectedAndClearsTheRest() {
        var session = ReviewSession()
        var failed = sug("a"), ok = sug("b")
        failed.status = .failed; ok.status = .approved
        session.apply([failed, ok])
        #expect(session.isSelected(failed) && !session.isSelected(ok))
        var dismissed = sug("c", preselected: false)
        session.toggle(dismissed)
        dismissed.status = .dismissed
        session.apply([dismissed])
        #expect(!session.isSelected(dismissed))
    }
}

@Suite struct CrossDigestActionsTests {
    private func setup() async throws -> (InMemoryDigestStore, [Digest]) {
        let store = InMemoryDigestStore()
        var digests: [Digest] = []
        for (i, name) in ["x", "y"].enumerated() {
            let d = Digest(id: UUID(), createdAt: t0.addingTimeInterval(Double(i) * 10), headline: "h", emailCount: 2,
                           suggestions: [sug("\(name)1", category: .work), sug("\(name)2", category: .uni)], info: [], skipped: [])
            try await store.save(d)
            digests.append(d)
        }
        return (store, digests)
    }

    private func records(_ ds: [Digest]) -> [SuggestionRecord] {
        ds.flatMap { SuggestionRecord.records(from: $0, kind: .daily, emails: Dictionary(uniqueKeysWithValues: $0.suggestions.map { ($0.emailID, email()) })) }
    }

    @Test func approveAndDismissPersistToEachOwnDigest() async throws {
        let (store, ds) = try await setup()
        let recs = records(ds)
        let clock = FixedClock(t0.addingTimeInterval(500))
        let writer = RecordingReminderWriter()
        let out = await ReviewActions.approve([recs[0], recs[2]], writer: writer, store: store, listName: "L",
                                              storedListID: nil, clock: clock)
        #expect(out.results.map(\.status) == [.approved, .approved] && out.decisions.count == 2)
        #expect(out.listID != nil)
        let written = await writer.written
        #expect(written.map(\.category) == [.work, .work] && written.allSatisfy { $0.email != nil })
        let dis = try await ReviewActions.dismiss([recs[1], recs[3]], store: store, clock: clock)
        #expect(dis.decisions.map(\.action) == [.dismissed, .dismissed])
        for d in ds {
            let stored = try #require(await store.digest(id: d.id))
            #expect(stored.suggestions.map(\.status) == [.approved, .dismissed])
            #expect(stored.suggestions.allSatisfy { $0.decidedAt == t0.addingTimeInterval(500) })
        }
    }

    @Test func failureLeavesSuggestionFailedAndSelected() async throws {
        let (store, ds) = try await setup()
        let recs = records(ds)
        let writer = RecordingReminderWriter(failingSuggestionIDs: [recs[2].id])
        var session = ReviewSession()
        let out = await ReviewActions.approve(session.recordSplit(recs).approve, writer: writer, store: store,
                                              listName: "L", storedListID: nil, clock: FixedClock(t0))
        session.apply(out.results)
        let failed = try #require(out.results.first { $0.id == recs[2].id })
        #expect(failed.status == .failed && failed.decidedAt == nil)
        #expect(session.isSelected(failed))
        #expect(!session.isSelected(out.results[0]))
        let stored = try #require(await store.digest(id: ds[1].id))
        #expect(stored.suggestions[0].status == .failed)
    }

    @Test func editValidatesLikeApplyAndPersists() async throws {
        let (store, ds) = try await setup()
        let r = records(ds)[0]
        await #expect(throws: ReviewError.invalidTitle) {
            try await ReviewActions.edit(SuggestionEdit(title: "ab"), record: r, store: store)
        }
        await #expect(throws: ReviewError.invalidTitle) {
            try await ReviewActions.edit(SuggestionEdit(title: "see https://x.com now"), record: r, store: store)
        }
        var done = r
        done.suggestion.status = .approved
        await #expect(throws: ReviewError.notEditable) {
            try await ReviewActions.edit(SuggestionEdit(title: "Fine title"), record: done, store: store)
        }
        let edited = try await ReviewActions.edit(SuggestionEdit(title: "  New title ", category: .finance), record: r, store: store)
        #expect(edited.suggestion.title == "New title" && edited.category == .finance)
        let stored = try #require(await store.digest(id: ds[0].id))
        #expect(stored.suggestions[0].title == "New title" && stored.suggestions[0].category == .finance)
    }

    @Test func dayContentMergesDigestsInCreationOrder() {
        let older = Digest(id: UUID(), createdAt: t0, headline: "first", emailCount: 3, suggestions: [sug("a")],
                           info: [InfoItem(id: "i1", emailID: "a", category: .finance, importance: 3, summary: "s", keyFacts: [], pinned: false)],
                           skipped: [])
        let newer = Digest(id: UUID(), createdAt: t0.addingTimeInterval(60), headline: "", emailCount: 2, suggestions: [sug("b")],
                           info: [], skipped: [])
        let latest = Digest(id: UUID(), createdAt: t0.addingTimeInterval(30), headline: "second", emailCount: 1, suggestions: [],
                            info: [], skipped: [])
        let content = DayContent(digests: [newer, older, latest])
        #expect(content.digestIDs == [older.id, latest.id, newer.id])
        #expect(content.emailCount == 6)
        #expect(content.headline == "second")
        #expect(content.records.map(\.suggestion.emailID) == ["a", "b"])
        #expect(content.records[0].category == .finance && content.records[1].category == .other)
        #expect(content.info.count == 1)
    }
}
