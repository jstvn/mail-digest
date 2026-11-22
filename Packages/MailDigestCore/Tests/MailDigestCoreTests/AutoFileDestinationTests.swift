import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sug(_ email: String, _ status: SuggestionStatus) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: "t", due: nil, dueHasTime: false, priority: .medium,
               evidence: "e", confidence: 0.9, preselected: true, flags: [], status: status, reminderID: nil)
}
private func info(_ email: String) -> InfoItem {
    InfoItem(id: email, emailID: email, category: .uni, importance: 3, summary: "s", keyFacts: [], pinned: false)
}
private func digest(_ s: [Suggestion], info: [InfoItem], skipped: [SkippedEmail] = []) -> Digest {
    Digest(id: UUID(), createdAt: t0, headline: "h", emailCount: 1, suggestions: s, info: info, skipped: skipped)
}

@Suite struct AutoFileDestinationTests {
    let sel = ProcessedEmailSelector()

    // MARK: Settings

    @Test func settingsDefaultsAndTolerantDecoding() throws {
        let d = DigestSettings()
        #expect(d.autoFileHandledDestination == .mailDigest && d.autoFileDismissedDestination == .trash)
        let old = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"autoFileProcessed":true}"#.utf8))
        #expect(old.autoFileHandledDestination == .mailDigest && old.autoFileDismissedDestination == .trash)
        let bad = try JSONDecoder().decode(DigestSettings.self, from: Data(
            #"{"autoFileHandledDestination":"shredder","autoFileDismissedDestination":7}"#.utf8))
        #expect(bad.autoFileHandledDestination == .mailDigest && bad.autoFileDismissedDestination == .trash)
        var s = DigestSettings()
        s.autoFileHandledDestination = .trash
        s.autoFileDismissedDestination = .mailDigest
        let round = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(round.autoFileHandledDestination == .trash && round.autoFileDismissedDestination == .mailDigest)
    }

    // MARK: Decision

    @Test func decisionMatrix() {
        let d = digest([sug("alld", .dismissed), sug("alld", .dismissed),
                        sug("mixed", .dismissed), sug("mixed", .approved),
                        sug("appr", .approved)],
                       info: [info("alld"), info("mixed"), info("appr"), info("none")],
                       skipped: [SkippedEmail(id: "blk", sender: "x", subject: "y", reason: "blocked sender")])
        func dest(_ id: String, handled: AutoFileDestination = .mailDigest,
                  dismissed: AutoFileDestination = .trash) -> AutoFileDestination {
            sel.autoFileDestination(emailID: id, digest: d, handled: handled, dismissed: dismissed)
        }
        #expect(dest("alld") == .trash)
        #expect(dest("mixed") == .mailDigest)
        #expect(dest("appr") == .mailDigest)
        #expect(dest("none") == .mailDigest)
        #expect(dest("blk") == .mailDigest)
        // Swapped settings swap the routing.
        #expect(dest("alld", dismissed: .mailDigest) == .mailDigest)
        #expect(dest("appr", handled: .trash) == .trash && dest("blk", handled: .trash) == .trash)
    }

    @Test func pendingAndFailedAreNeverSelectedAtAll() {
        let d = digest([sug("p", .dismissed), sug("p", .pending), sug("f", .failed)], info: [info("p"), info("f")])
        let ctx = EmailContext(sender: "a@b.com", subject: "s", mailbox: MailboxRef(account: "A", name: "Inbox"))
        let ids = sel.autoFileIDs(digest: d, emails: ["p": ctx, "f": ctx], dispositions: MailDispositions(),
                                  finishedAt: ["p": t0, "f": t0], enabledAt: t0)
        #expect(ids.isEmpty)
    }

    @Test func actionIsSingleDestinationOrSplit() {
        let d = digest([sug("a", .dismissed), sug("b", .approved)], info: [info("a"), info("b")])
        #expect(sel.autoFileAction(ids: ["a"], digest: d, handled: .mailDigest, dismissed: .trash) == .trash)
        #expect(sel.autoFileAction(ids: ["b"], digest: d, handled: .mailDigest, dismissed: .trash)
                == .moveToFolder("Mail Digest"))
        #expect(sel.autoFileAction(ids: ["a", "b"], digest: d, handled: .mailDigest, dismissed: .trash)
                == .split(folder: "Mail Digest", trashIDs: ["a"]))
    }

    // MARK: Execution (fake Mail)

    private func inbox(_ ids: String...) -> [String: MailboxRef] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, MailboxRef(account: "iCloud", name: "Inbox")) })
    }

    @Test func splitRoutesEachEmailAndUndoRestoresBoth() async throws {
        let rec = RecordingMailActions(locations: inbox("a", "b", "c"))
        let cleanup = MailCleanup(actions: rec)
        let action = CleanupAction.split(folder: "Mail Digest", trashIDs: ["a"])
        let batch = try await cleanup.perform(action, ids: ["a", "b", "c"])
        #expect(await rec.location(of: "a")?.name == "Trash")
        #expect(await rec.location(of: "b")?.name == "Mail Digest")
        #expect(await rec.location(of: "c")?.name == "Mail Digest")
        #expect(batch.summary == "Moved 3 emails: 2 to Mail Digest, 1 to Trash.")
        try await cleanup.undo(batch)
        for id in ["a", "b", "c"] { #expect(await rec.location(of: id)?.name == "Inbox") }
    }

    @Test func failedTrashIsNotRedirectedToTheFolder() async throws {
        let rec = RecordingMailActions(locations: inbox("a", "b"), missingIDs: ["a"])
        let batch = try await MailCleanup(actions: rec)
            .perform(.split(folder: "Mail Digest", trashIDs: ["a"]), ids: ["a", "b"])
        let calls = await rec.calls
        #expect(calls.filter { $0.messageIDs.contains("a") }.map(\.destination) == ["Trash"])
        #expect(batch.results.first { $0.messageID == "a" }?.succeeded == false)
        #expect(batch.summary == "Moved 1 email to Mail Digest. 1 couldn't be moved.")
    }

    @Test func summariesNameTheDestination() {
        func ok(_ id: String) -> MailActionResult {
            MailActionResult(messageID: id, account: "A", originalMailbox: "Inbox", succeeded: true, error: nil)
        }
        #expect(CleanupBatch(id: UUID(), action: .trash, results: [ok("a")]).summary == "Moved 1 email to Trash.")
        #expect(CleanupBatch(id: UUID(), action: .moveToFolder("Mail Digest"), results: [ok("a"), ok("b")]).summary
                == "Moved 2 emails to Mail Digest.")
        #expect(CleanupBatch(id: UUID(), action: .split(folder: "Mail Digest", trashIDs: ["a", "b"]),
                             results: [ok("a"), ok("b")]).summary == "Moved 2 emails to Trash.")
    }

    // Q39/Q42: an undone email gets an `autoFileAttempted` record and so is never selected again.
    @Test func noReFileAfterUndo() {
        let d = digest([sug("a", .dismissed)], info: [info("a")])
        let ctx = EmailContext(sender: "a@b.com", subject: "s", mailbox: MailboxRef(account: "A", name: "Inbox"))
        let ids = sel.autoFileIDs(digest: d, emails: ["a": ctx],
                                  dispositions: MailDispositions(autoFileAttempted: ["a"]),
                                  finishedAt: ["a": t0], enabledAt: t0)
        #expect(ids.isEmpty)
    }
}
