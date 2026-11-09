import Foundation

/// True for a mailbox the New Backlog Job window hides by default: an empty one, or a system or
/// list-mirroring folder (Outbox, Drafts, Sent, Junk, Deleted, Notes, Tasks, "Untitled list", ...).
/// Pure; matches on the lowercased name, so a localised system folder is only caught when it is empty.
public func isNoiseMailbox(name: String, messageCount: Int) -> Bool {
    if messageCount == 0 { return true }
    let n = name.lowercased()
    let system = ["outbox", "drafts", "sent", "sent items", "sent messages", "junk", "junk email",
                  "deleted items", "deleted messages", "trash", "recovered messages", "sendlater",
                  "notes", "tasks", "journal", "conversation history", "starred"]
    if system.contains(where: { n == $0 || n.hasPrefix($0 + " (") }) { return true }
    if n.contains("untitled list") || n.hasPrefix("deleted items/") { return true }
    return false
}

/// The mailbox list of the New Backlog Job window: useful mailboxes up front, the rest behind a disclosure.
public struct MailboxPartition: Sendable, Equatable {
    /// Inboxes, Archive and folders that hold mail, grouped by account.
    public var useful: [MailboxTreeAccount]
    /// Empty and system folders, grouped by account.
    public var noise: [MailboxTreeAccount]

    /// How many mailboxes sit behind "Show N Empty and System Folders".
    public var noiseCount: Int { noise.reduce(0) { $0 + $1.rows.count } }
}

extension MailboxTree {
    /// The Mail Digest folder that Mail Cleanup files handled emails into.
    public static func isCleanupFolder(_ row: MailboxTreeRow) -> Bool {
        row.title.caseInsensitiveCompare(MailCleanup.digestFolderName) == .orderedSame && row.info.kind != .inbox
    }

    /// The name to show: IMAP reserves `INBOX` (any case), which Mail's sidebar shows as "Inbox".
    public static func displayTitle(_ row: MailboxTreeRow) -> String {
        row.title.caseInsensitiveCompare("INBOX") == .orderedSame ? "Inbox" : row.title
    }

    /// Secondary label for a row: "Mail Cleanup folder" on the Mail Digest folder, which explains why it exists.
    public static func annotation(_ row: MailboxTreeRow) -> String? {
        isCleanupFolder(row) ? "Mail Cleanup folder" : nil
    }

    /// Splits the mailboxes into useful and noise, keeping `accounts`' ordering. An inbox is never noise,
    /// even when empty, so every account keeps its "All Inboxes" member. `filter` narrows by mailbox or
    /// account name (case and diacritic insensitive); a blank filter keeps everything.
    public static func partition(_ boxes: [MailboxInfo], filter: String = "") -> MailboxPartition {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ row: MailboxTreeRow, account: String) -> Bool {
            query.isEmpty
                || displayTitle(row).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.info.ref.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || account.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var useful: [MailboxTreeAccount] = [], noise: [MailboxTreeAccount] = []
        for account in accounts(boxes, showAll: true) {
            let rows = account.rows.filter { matches($0, account: account.account) }
            func isNoise(_ row: MailboxTreeRow) -> Bool {
                row.info.kind != .inbox
                    && (hiddenKinds.contains(row.info.kind)
                        || isNoiseMailbox(name: row.info.ref.name, messageCount: row.info.messageCount))
            }
            let good = rows.filter { !isNoise($0) }, bad = rows.filter(isNoise)
            if !good.isEmpty { useful.append(MailboxTreeAccount(account: account.account, rows: good)) }
            if !bad.isEmpty { noise.append(MailboxTreeAccount(account: account.account, rows: bad)) }
        }
        return MailboxPartition(useful: useful, noise: noise)
    }
}
