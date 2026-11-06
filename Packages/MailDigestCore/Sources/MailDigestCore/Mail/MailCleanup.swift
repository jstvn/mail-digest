import Foundation

/// What a cleanup did to the mail.
public enum CleanupAction: Sendable, Equatable {
    case trash
    case moveToFolder(String)
}

/// The results of one cleanup, kept so it can be undone.
public struct CleanupBatch: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var action: CleanupAction
    public var results: [MailActionResult]

    public init(id: UUID, action: CleanupAction, results: [MailActionResult]) {
        self.id = id
        self.action = action
        self.results = results
    }
}

extension CleanupBatch {
    /// Toast text, e.g. "Moved 12 emails to Trash. 2 couldn't be moved."
    public var summary: String {
        let done = results.filter(\.succeeded).count
        let failed = results.count - done
        let noun = done == 1 ? "email" : "emails"
        let place: String
        switch action {
        case .trash: place = "Trash"
        case .moveToFolder(let name): place = name
        }
        var text = "Moved \(done) \(noun) to \(place)."
        if failed > 0 { text += " \(failed) couldn't be moved." }
        return text
    }
}

/// In-memory undo history; undo lasts until the app quits.
public actor UndoLedger {
    private var batches: [CleanupBatch] = []
    private var hidden: Set<String> = []

    public init() {}

    /// Remembers a batch so it can be undone.
    public func record(_ batch: CleanupBatch) { batches.append(batch) }

    public var lastBatch: CleanupBatch? { batches.last }

    /// Removes and returns a batch (call before undoing it).
    public func take(_ id: UUID) -> CleanupBatch? {
        guard let i = batches.firstIndex(where: { $0.id == id }) else { return nil }
        return batches.remove(at: i)
    }

    /// Keep: hides rows without touching any mail.
    public func hide(_ ids: [String]) { hidden.formUnion(ids) }

    public var hiddenIDs: Set<String> { hidden }

    /// Emails currently moved by a recorded (not yet undone) batch.
    public var movedIDs: Set<String> {
        Set(batches.flatMap { $0.results.filter(\.succeeded).map(\.messageID) })
    }
}

/// Moves processed emails to Trash or a folder in batches, and undoes it.
///
/// Only moves are possible: `MailActions` has no API to empty Trash or delete
/// permanently, and this type never needs one.
public struct MailCleanup: Sendable {
    /// The mailbox "Move to Mail Digest folder" and auto-file use, in the message's own account.
    public static let digestFolderName = "Mail Digest"

    private let actions: MailActions
    private let batchSize: Int
    private let makeID: @Sendable () -> UUID

    public init(actions: MailActions, batchSize: Int = 25, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.actions = actions
        self.batchSize = max(1, batchSize)
        self.makeID = makeID
    }

    /// Applies `action` to exactly `ids`, in chunks. A missing message becomes a failed result.
    public func perform(_ action: CleanupAction, ids: [String]) async throws -> CleanupBatch {
        var results: [MailActionResult] = []
        for chunk in chunks(ids) {
            switch action {
            case .trash:
                results += try await actions.moveToTrash(messageIDs: chunk)
            case .moveToFolder(let name):
                results += try await actions.move(messageIDs: chunk, toMailboxNamed: name, createIfMissing: true)
            }
        }
        return CleanupBatch(id: makeID(), action: action, results: results)
    }

    /// Puts the succeeded emails back in their original mailbox; failed ones were never moved.
    /// Throws `MailActionError.restoreFailed` after trying every chunk if some emails could not be restored.
    public func undo(_ batch: CleanupBatch) async throws {
        var failures: [RestoreFailure] = []
        for chunk in chunks(batch.results.filter(\.succeeded)) {
            do {
                try await actions.restore(chunk)
            } catch MailActionError.restoreFailed(let failed) {
                // Keep going: one missing email must not strand the rest of the batch.
                failures += failed
            }
        }
        if !failures.isEmpty { throw MailActionError.restoreFailed(failures) }
    }

    private func chunks<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0..<min($0 + batchSize, items.count)])
        }
    }
}
