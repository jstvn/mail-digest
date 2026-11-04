import Foundation
import Testing
@testable import MailDigestCore

private func locations(_ n: Int, account: String = "iCloud") -> [String: MailboxRef] {
    Dictionary(uniqueKeysWithValues: (0..<n).map { ("m\($0)", MailboxRef(account: account, name: "Inbox")) })
}

@Suite struct MailCleanupTests {
    @Test func trashRunsInChunksOf25() async throws {
        let rec = RecordingMailActions(locations: locations(60))
        let ids = (0..<60).map { "m\($0)" }
        let batch = try await MailCleanup(actions: rec).perform(.trash, ids: ids)
        let calls = await rec.calls
        #expect(calls.map { $0.messageIDs.count } == [25, 25, 10])
        #expect(batch.results.count == 60)
        #expect(batch.action == .trash)
    }

    @Test func missingIDIsFailedResultNotError() async throws {
        let rec = RecordingMailActions(locations: locations(3), missingIDs: ["m1"])
        let batch = try await MailCleanup(actions: rec).perform(.trash, ids: ["m0", "m1", "m2"])
        #expect(batch.results.map(\.succeeded) == [true, false, true])
    }

    @Test func undoRestoresOnlySucceeded() async throws {
        let rec = RecordingMailActions(locations: locations(3), missingIDs: ["m1"])
        let cleanup = MailCleanup(actions: rec)
        let batch = try await cleanup.perform(.trash, ids: ["m0", "m1", "m2"])
        #expect(await rec.location(of: "m0")?.name == "Trash")
        try await cleanup.undo(batch)
        #expect(await rec.location(of: "m0") == MailboxRef(account: "iCloud", name: "Inbox"))
        #expect(await rec.location(of: "m2") == MailboxRef(account: "iCloud", name: "Inbox"))
        let restored = await rec.restored.flatMap { $0 }.map(\.messageID)
        #expect(restored == ["m0", "m2"])
    }

    @Test func undoChunksLargeBatches() async throws {
        let rec = RecordingMailActions(locations: locations(30))
        let cleanup = MailCleanup(actions: rec)
        let batch = try await cleanup.perform(.trash, ids: (0..<30).map { "m\($0)" })
        try await cleanup.undo(batch)
        #expect(await rec.restored.map(\.count) == [25, 5])
    }

    @Test func moveToFolderStaysInAccount() async throws {
        let rec = RecordingMailActions(locations: ["m0": MailboxRef(account: "Outlook", name: "Inbox")])
        let batch = try await MailCleanup(actions: rec).perform(.moveToFolder("Mail Digest"), ids: ["m0"])
        #expect(await rec.location(of: "m0") == MailboxRef(account: "Outlook", name: "Mail Digest"))
        #expect(batch.action == .moveToFolder("Mail Digest"))
        let call = await rec.calls[0]
        #expect(call.createIfMissing)
    }

    @Test func onlyPassedIDsTouched() async throws {
        let rec = RecordingMailActions(locations: locations(3))
        _ = try await MailCleanup(actions: rec).perform(.trash, ids: ["m1"])
        #expect(await rec.location(of: "m0")?.name == "Inbox")
        #expect(await rec.location(of: "m1")?.name == "Trash")
    }

    @Test func customIDGenerator() async throws {
        let fixed = UUID()
        let rec = RecordingMailActions(locations: locations(1))
        let batch = try await MailCleanup(actions: rec, makeID: { fixed }).perform(.trash, ids: ["m0"])
        #expect(batch.id == fixed)
    }

    @Test func ledgerRecordTakeAndHide() async throws {
        let rec = RecordingMailActions(locations: locations(2))
        let batch = try await MailCleanup(actions: rec).perform(.trash, ids: ["m0", "m1"])
        let ledger = UndoLedger()
        await ledger.record(batch)
        #expect(await ledger.lastBatch == batch)
        #expect(await ledger.movedIDs == ["m0", "m1"])
        #expect(await ledger.take(batch.id) == batch)
        #expect(await ledger.take(batch.id) == nil)
        #expect(await ledger.lastBatch == nil)
        #expect(await ledger.movedIDs.isEmpty)
    }

    @Test func hideDoesNotTouchMail() async {
        let rec = RecordingMailActions(locations: locations(1))
        let ledger = UndoLedger()
        await ledger.hide(["m0"])
        #expect(await ledger.hiddenIDs == ["m0"])
        #expect(await rec.calls.isEmpty)
        #expect(await rec.restored.isEmpty)
    }
}
