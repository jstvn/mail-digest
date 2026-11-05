import Foundation

public protocol MailSource: Sendable {
    /// Asks Mail to fetch new mail now.
    func checkForNewMail() async throws
    /// All accounts and their mailboxes with counts, for the job setup picker.
    func listMailboxes() async throws -> [MailboxInfo]
    /// Metadata only, newest first, for messages received in [from, to) in one mailbox.
    func listHeaders(in mailbox: MailboxRef, from: Date, to: Date) async throws -> [MessageHeader]
    /// Full messages (body + filter headers) for up to ~10 references from one mailbox.
    /// `storeRowID` is only a locator hint; matching is by `messageID`.
    func fetchMessages(references: [MailMessageReference], in mailbox: MailboxRef) async throws -> [EmailMessage]
}

extension MailSource {
    /// Convenience for callers that only know Message-IDs (no row-ID hints).
    public func fetchMessages(ids: [String], in mailbox: MailboxRef) async throws -> [EmailMessage] {
        try await fetchMessages(references: ids.map { MailMessageReference(messageID: $0, storeRowID: nil) }, in: mailbox)
    }
}
