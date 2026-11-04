import Foundation

public protocol MailSource: Sendable {
    /// Asks Mail to fetch new mail now.
    func checkForNewMail() async throws
    /// All accounts and their mailboxes with counts, for the job setup picker.
    func listMailboxes() async throws -> [MailboxInfo]
    /// Metadata only, newest first, for messages received in [from, to) in one mailbox.
    func listHeaders(in mailbox: MailboxRef, from: Date, to: Date) async throws -> [MessageHeader]
    /// Full messages (body + filter headers) for up to ~10 ids from one mailbox.
    func fetchMessages(ids: [String], in mailbox: MailboxRef) async throws -> [EmailMessage]
}
