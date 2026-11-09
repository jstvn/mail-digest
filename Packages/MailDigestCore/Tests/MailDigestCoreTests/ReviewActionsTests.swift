import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func sug(_ title: String, email: String = "e1", status: SuggestionStatus = .pending,
                 preselected: Bool = true, due: Date? = nil, hasTime: Bool = false) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: title, due: due, dueHasTime: hasTime, priority: .medium,
               evidence: "pay by Friday", confidence: 0.9, preselected: preselected, flags: [],
               status: status, reminderID: nil)
}

private func info(_ email: String, _ cat: Category) -> InfoItem {
    InfoItem(id: email, emailID: email, category: cat, importance: 3, summary: "s", keyFacts: [], pinned: false)
}

private func digest(_ s: [Suggestion], info: [InfoItem] = []) -> Digest {
    Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 2, suggestions: s, info: info, skipped: [])
}

private let emails: [String: EmailContext] = [
    "e1": EmailContext(sender: "Bursar <Bursar@Uni.edu>", subject: "Fees due", mailbox: box),
    "e2": EmailContext(sender: "boss@work.com", subject: "Report", mailbox: box),
]

@Suite struct ReviewSelectionTests {
    @Test func defaultSelectionIsPreselectedPendingOnly() {
        let a = sug("Pay fees"), b = sug("Maybe", preselected: false)
        let c = sug("Done", status: .approved), d = sug("Old", status: .dismissed)
        let state = ReviewState(digest: digest([a, b, c, d]))
        #expect(state.selection == [a.id])
    }

    @Test func toggleAllNone() {
        let a = sug("Pay fees"), b = sug("Maybe", preselected: false), c = sug("Done", status: .approved)
        var state = ReviewState(digest: digest([a, b, c]))
        state = ReviewActions.toggle(b.id, in: state)
        #expect(state.selection == [a.id, b.id])
        state = ReviewActions.toggle(a.id, in: state)
        #expect(state.selection == [b.id])
        state = ReviewActions.toggle(c.id, in: state) // approved cannot be selected
        #expect(state.selection == [b.id])
        state = ReviewActions.selectAll(state)
        #expect(state.selection == [a.id, b.id])
        state = ReviewActions.selectNone(state)
        #expect(state.selection.isEmpty)
    }

    @Test func split() {
        let a = sug("Pay fees"), b = sug("Maybe", preselected: false)
        let f = sug("Retry me", status: .failed), done = sug("Done", status: .approved)
        var state = ReviewState(digest: digest([a, b, f, done]))
        state = ReviewActions.toggle(f.id, in: state)
        let split = ReviewActions.split(state)
        #expect(split.approve.map(\.id) == [a.id, f.id])
        #expect(split.dismiss.map(\.id) == [b.id])
    }
}

@Suite struct ReviewEditTests {
    @Test func titleValidation() throws {
        let a = sug("Pay fees")
        let state = ReviewState(digest: digest([a]))
        let ok = try ReviewActions.apply(SuggestionEdit(title: "  Pay the fees  "), to: a.id, in: state)
        #expect(ok.digest.suggestions[0].title == "Pay the fees")
        for bad in ["ab", "  a ", String(repeating: "x", count: 81), "see https://x.com", "go to WWW.x.com"] {
            #expect(throws: ReviewError.invalidTitle) {
                try ReviewActions.apply(SuggestionEdit(title: bad), to: a.id, in: state)
            }
        }
        _ = try ReviewActions.apply(SuggestionEdit(title: String(repeating: "x", count: 80)), to: a.id, in: state)
    }

    @Test func dueAndPriorityEdits() throws {
        let a = sug("Pay fees", due: t0, hasTime: true)
        var state = ReviewState(digest: digest([a]))
        state = try ReviewActions.apply(SuggestionEdit(priority: .high), to: a.id, in: state)
        #expect(state.digest.suggestions[0].priority == .high)
        state = try ReviewActions.apply(SuggestionEdit(due: .some(nil)), to: a.id, in: state)
        #expect(state.digest.suggestions[0].due == nil)
        #expect(state.digest.suggestions[0].dueHasTime == false)
        let later = t0.addingTimeInterval(3600)
        state = try ReviewActions.apply(SuggestionEdit(due: .some(later), dueHasTime: true), to: a.id, in: state)
        #expect(state.digest.suggestions[0].due == later)
        #expect(state.digest.suggestions[0].dueHasTime)
    }

    @Test func editableStatesAndUnknown() throws {
        let done = sug("Done", status: .approved), failed = sug("Failed", status: .failed)
        let state = ReviewState(digest: digest([done, failed]))
        #expect(throws: ReviewError.notEditable) {
            try ReviewActions.apply(SuggestionEdit(priority: .low), to: done.id, in: state)
        }
        _ = try ReviewActions.apply(SuggestionEdit(priority: .low), to: failed.id, in: state)
        #expect(throws: ReviewError.unknownSuggestion) {
            try ReviewActions.apply(SuggestionEdit(priority: .low), to: UUID(), in: state)
        }
    }

    @Test func categoryEditSetsSuggestionAndResolutionOrder() throws {
        let a = sug("Pay fees", email: "e1"), b = sug("Other", email: "zz")
        var state = ReviewState(digest: digest([a, b], info: [info("e1", .finance)]))
        // Fallbacks: no own category -> InfoItem category -> .other.
        #expect(ReviewActions.category(for: a, in: state) == .finance)
        #expect(ReviewActions.category(for: b, in: state) == .other)
        state = try ReviewActions.apply(SuggestionEdit(category: .uni), to: a.id, in: state)
        #expect(state.digest.suggestions[0].category == .uni)
        #expect(ReviewActions.category(for: state.digest.suggestions[0], in: state) == .uni)
        #expect(state.digest.suggestions[0].title == "Pay fees")
        // The suggestion's own category wins over the InfoItem even when they differ.
        #expect(ReviewActions.category(for: state.digest.suggestions[0], in: state) != .finance)
    }

    @Test func editPersistsAndSurvivesReload() async throws {
        let a = sug("Pay fees", email: "e1")
        let state = ReviewState(digest: digest([a], info: [info("e1", .finance)]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let edited = try await ReviewActions.edit(
            SuggestionEdit(title: "Pay uni fees", due: .some(t0), priority: .high, category: .uni),
            id: a.id, state: state, store: store)
        #expect(edited.digest.suggestions[0].category == .uni)

        let reloaded = ReviewState(digest: try #require(await store.latestDigest()))
        let s = reloaded.digest.suggestions[0]
        #expect(s.title == "Pay uni fees")
        #expect(s.due == t0)
        #expect(s.priority == .high)
        #expect(s.category == .uni)
        #expect(ReviewActions.category(for: s, in: reloaded) == .uni)
    }

    @Test func invalidEditIsNotPersisted() async throws {
        let a = sug("Pay fees")
        let state = ReviewState(digest: digest([a]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        await #expect(throws: ReviewError.invalidTitle) {
            try await ReviewActions.edit(SuggestionEdit(title: "x", category: .uni), id: a.id, state: state, store: store)
        }
        #expect(try await store.latestDigest()?.suggestions[0].category == nil)
    }
}

@Suite struct ReviewFlowTests {
    @Test func approveUsesEditedCategory() async throws {
        let a = sug("Pay fees", email: "e1")
        var state = ReviewState(digest: digest([a], info: [info("e1", .finance)]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        state = try await ReviewActions.edit(SuggestionEdit(category: .uni), id: a.id, state: state, store: store)
        let writer = RecordingReminderWriter()
        let out = await ReviewActions.approve(ReviewActions.split(state).approve, state: state, emails: emails,
                                              writer: writer, store: store, listName: "Mail Digest",
                                              storedListID: nil, clock: FixedClock(t0))
        #expect(out.results.map(\.status) == [.approved])
        #expect(await writer.written.map(\.category) == [.uni])
        #expect(try await store.latestDigest()?.suggestions[0].category == .uni)
    }

    @Test func approveWritesOnlyPassedItemsWithCategory() async throws {
        let a = sug("Pay fees", email: "e1"), b = sug("Report", email: "e2"), c = sug("Untouched", email: "e2")
        let state = ReviewState(digest: digest([a, b, c], info: [info("e1", .finance), info("e2", .work)]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let writer = RecordingReminderWriter()
        let clock = FixedClock(t0)

        let out = await ReviewActions.approve([a, b], state: state, emails: emails, writer: writer,
                                              store: store, listName: "Mail Digest", storedListID: nil, clock: clock)
        #expect(out.listID == "list-1")
        #expect(await writer.createdLists.count == 1)
        let written = await writer.written
        #expect(written.map(\.suggestion.id) == [a.id, b.id])
        #expect(written.map(\.category) == [.finance, .work])
        #expect(out.results.map(\.status) == [.approved, .approved])
        #expect(out.results.allSatisfy { $0.reminderID != nil })
        #expect(out.decisions.map(\.sender) == ["bursar@uni.edu", "boss@work.com"])
        #expect(out.decisions.allSatisfy { $0.action == .approved && $0.decidedAt == t0 })

        let stored = try #require(await store.latestDigest())
        #expect(stored.suggestions.map(\.status) == [.approved, .approved, .pending])
        #expect(try await store.decisions(for: "bursar@uni.edu").count == 1)

        let merged = ReviewActions.merge(out.results, into: state)
        #expect(merged.digest.suggestions.map(\.status) == [.approved, .approved, .pending])
        #expect(!merged.selection.contains(a.id))
    }

    @Test func listReusedAndRecreated() async throws {
        let a = sug("One"), b = sug("Two"), c = sug("Three")
        let state = ReviewState(digest: digest([a, b, c]))
        let store = InMemoryDigestStore()
        let writer = RecordingReminderWriter()
        let clock = FixedClock(t0)
        let first = await ReviewActions.approve([a], state: state, emails: emails, writer: writer, store: store,
                                                listName: "L", storedListID: nil, clock: clock)
        let second = await ReviewActions.approve([b], state: state, emails: emails, writer: writer, store: store,
                                                 listName: "L", storedListID: first.listID, clock: clock)
        #expect(second.listID == first.listID)
        #expect(await writer.createdLists.count == 1)
        await writer.deleteList(id: first.listID!)
        let third = await ReviewActions.approve([c], state: state, emails: emails, writer: writer, store: store,
                                                listName: "L", storedListID: first.listID, clock: clock)
        #expect(third.listID != first.listID)
        #expect(await writer.createdLists.count == 2)
    }

    @Test func failedWriteStaysRetryableWithoutDecision() async throws {
        let a = sug("Pay fees"), b = sug("Report", email: "e2")
        var state = ReviewState(digest: digest([a, b]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let writer = RecordingReminderWriter(failingSuggestionIDs: [a.id])
        let clock = FixedClock(t0)

        let out = await ReviewActions.approve([a, b], state: state, emails: emails, writer: writer, store: store,
                                              listName: "L", storedListID: nil, clock: clock)
        #expect(out.results.map(\.status) == [.failed, .approved])
        #expect(out.decisions.count == 1)
        #expect(try await store.decisions(for: "bursar@uni.edu").isEmpty)
        state = ReviewActions.merge(out.results, into: state)
        #expect(state.selection.contains(a.id)) // still selected for retry

        await writer.setFailingSuggestionIDs([])
        let retry = ReviewActions.split(state).approve
        #expect(retry.map(\.id) == [a.id])
        let again = await ReviewActions.approve(retry, state: state, emails: emails, writer: writer, store: store,
                                                listName: "L", storedListID: out.listID, clock: clock)
        #expect(again.results[0].status == .approved)
        #expect(again.decisions.count == 1)
    }

    @Test func ensureListFailureFailsAllWithoutDecisions() async throws {
        struct Boom: Error {}
        struct BadWriter: ReminderWriter {
            func ensureList(named name: String, storedID: String?) async throws -> String { throw Boom() }
            func renameList(id: String, to name: String) async throws {}
            func write(_ suggestion: Suggestion, category: Category, email: EmailContext?, toList listID: String) async throws -> String { "x" }
        }
        let a = sug("Pay fees")
        let state = ReviewState(digest: digest([a]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let out = await ReviewActions.approve([a], state: state, emails: emails, writer: BadWriter(), store: store,
                                              listName: "L", storedListID: nil, clock: FixedClock(t0))
        #expect(out.listID == nil)
        #expect(out.results.map(\.status) == [.failed])
        #expect(out.decisions.isEmpty)
        #expect(try await store.latestDigest()?.suggestions[0].status == .failed)
    }

    @Test func dismissRecordsDecisions() async throws {
        let a = sug("Pay fees"), b = sug("Report", email: "e2")
        let state = ReviewState(digest: digest([a, b]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let out = try await ReviewActions.dismiss([a, b], state: state, emails: emails, store: store, clock: FixedClock(t0))
        #expect(out.results.map(\.status) == [.dismissed, .dismissed])
        #expect(out.decisions.map(\.action) == [.dismissed, .dismissed])
        let d = try await store.decisions(for: "bursar@uni.edu")
        #expect(d.count == 1 && d[0].action == .dismissed && d[0].suggestionID == a.id)
        #expect(try await store.latestDigest()?.suggestions.map(\.status) == [.dismissed, .dismissed])
    }
}

@Suite struct ReviewContentTests {
    @Test func notesString() {
        let s = sug("Pay fees")
        let notes = ReviewActions.reminderNotes(for: s, email: emails["e1"], category: .finance)
        #expect(notes == "From: Bursar <Bursar@Uni.edu>\nSubject: Fees due\n\"pay by Friday\"\n#finance")
    }

    @Test func notesWithoutEmailOmitHeaderLines() {
        let notes = ReviewActions.reminderNotes(for: sug("Pay fees"), email: nil, category: .finance)
        #expect(notes == "\"pay by Friday\"\n#finance")
    }

    @Test func approvePassesEmailContextToWriter() async throws {
        let a = sug("Pay fees"), b = sug("Orphan", email: "missing")
        let state = ReviewState(digest: digest([a, b]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let writer = RecordingReminderWriter()
        _ = await ReviewActions.approve([a, b], state: state, emails: emails, writer: writer, store: store,
                                        listName: "L", storedListID: nil, clock: FixedClock(t0))
        let written = await writer.written
        #expect(written.map(\.email) == [emails["e1"], nil])
    }

    @Test func messageURL() {
        #expect(ReviewActions.messageURL(for: "abc123@mail.example.com").absoluteString
                == "message://%3Cabc123@mail.example.com%3E")
        #expect(ReviewActions.messageURL(for: "a b/c+d").absoluteString == "message://%3Ca%20b%2Fc%2Bd%3E")
    }
}

@Suite struct ReviewInspectorEditTests {
    @Test func dueEditsMarkTheDateAsUserSet() throws {
        let a = sug("Pay fees", due: t0)
        #expect(a.effectiveDueSource == .email) // older data with a date reads as found in the email
        let dated = try ReviewActions.applying(SuggestionEdit(due: .some(t0.addingTimeInterval(86_400))), to: a)
        #expect(dated.dueSource == .user && dated.effectiveDueSource == .user)
        let timed = try ReviewActions.applying(SuggestionEdit(dueHasTime: true), to: a)
        #expect(timed.dueSource == .user)
        // Other edits leave the source alone.
        #expect(try ReviewActions.applying(SuggestionEdit(priority: .high), to: a).dueSource == nil)
        // No date, no source.
        let cleared = try ReviewActions.applying(SuggestionEdit(due: .some(nil)), to: dated)
        #expect(cleared.dueSource == nil && cleared.effectiveDueSource == nil)
        #expect(DueSource.email.hintText == "found in email" && DueSource.user.hintText == "set by you")
    }

    @Test func listAndNotesEdits() throws {
        let a = sug("Pay fees")
        let listed = try ReviewActions.applying(SuggestionEdit(reminderListID: .some("L1"), notes: "  Bring ID \n"), to: a)
        #expect(listed.reminderListID == "L1" && listed.notes == "Bring ID")
        let reset = try ReviewActions.applying(SuggestionEdit(reminderListID: .some(nil), notes: " "), to: listed)
        #expect(reset.reminderListID == nil && reset.notes == nil)
        // Nil means unchanged.
        #expect(try ReviewActions.applying(SuggestionEdit(priority: .low), to: listed).reminderListID == "L1")
    }

    @Test func notesLeadTheReminderText() {
        var s = sug("Pay fees")
        s.notes = "Bring ID"
        let text = ReviewActions.reminderNotes(for: s, email: emails["e1"], category: .finance)
        #expect(text == "Bring ID\n\nFrom: Bursar <Bursar@Uni.edu>\nSubject: Fees due\n\"pay by Friday\"\n#finance")
    }

    @Test func chosenListIsWrittenToAndDeletedListFallsBack() async throws {
        var chosen = sug("Pay fees"), gone = sug("Report")
        chosen.reminderListID = "uni"
        gone.reminderListID = "deleted"
        let state = ReviewState(digest: digest([chosen, gone]))
        let store = InMemoryDigestStore()
        try await store.save(state.digest)
        let writer = RecordingReminderWriter(lists: ["uni": "Uni"])
        let out = await ReviewActions.approve([chosen, gone], state: state, emails: emails, writer: writer,
                                              store: store, listName: "Mail Digest", storedListID: nil, clock: FixedClock(t0))
        #expect(out.results.map(\.status) == [.approved, .approved])
        let written = await writer.written
        #expect(written[0].listID == "uni")
        #expect(written[1].listID == out.listID) // the default list
    }
}
