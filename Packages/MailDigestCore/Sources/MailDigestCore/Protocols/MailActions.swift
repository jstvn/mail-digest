import Foundation

public protocol MailActions: Sendable {
    /// Moves messages to their account's Trash; never deletes permanently.
    func moveToTrash(messageIDs: [String]) async throws -> [MailActionResult]
    /// Moves messages to a mailbox in the same account, optionally creating it.
    func move(messageIDs: [String], toMailboxNamed name: String, createIfMissing: Bool) async throws -> [MailActionResult]
    /// Undo: puts messages back in their original mailbox. Throws `MailActionError.restoreFailed` when some
    /// could not be found; the others are still restored.
    func restore(_ results: [MailActionResult]) async throws
}
