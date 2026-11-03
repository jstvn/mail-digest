import Foundation

/// Mailbox role, taken from Mail's special mailboxes; never inferred from (localised) names.
public enum MailboxKind: String, Codable, Sendable, Equatable {
    case inbox, archive, sent, drafts, junk, trash, custom
}

/// One mailbox in one account, addressed exactly as ListMailboxes.js returns it.
public struct MailboxRef: Codable, Sendable, Hashable {
    public var account: String        // "iCloud", "Outlook"
    public var name: String           // "Inbox", "Archive", "Starred", nested names as Mail reports them

    public init(account: String, name: String) {
        self.account = account
        self.name = name
    }
}

public struct MailboxInfo: Codable, Sendable, Equatable {
    public var ref: MailboxRef
    public var messageCount: Int
    public var unreadCount: Int
    public var kind: MailboxKind      // inbox, archive, sent, drafts, junk, trash, custom

    public init(ref: MailboxRef, messageCount: Int, unreadCount: Int, kind: MailboxKind) {
        self.ref = ref
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.kind = kind
    }
}
