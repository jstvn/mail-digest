import Foundation
import MailDigestCore

/// How JXA addresses a mailbox: the account UUID (nil for On My Mac) and the nested path.
struct JXAMailboxAddress: Sendable, Equatable {
    var accountID: String?
    var path: [String]
}

/// Combines SQLite mailbox rows, the active-account policy and (optionally) the JXA listing into
/// `MailboxInfo`s, and maps a `MailboxRef` to its SQLite URL and JXA address.
struct MailboxResolver: Sendable {
    private let rows: [EnvelopeIndexReader.MailboxRow]
    private let jxaMailboxes: [MailboxInfo]?
    private let policy: ActiveAccountPolicy

    /// - Parameters:
    ///   - rows: Mailbox rows from the Envelope Index.
    ///   - jxaMailboxes: The ListMailboxes.js result, or nil when Automation is unavailable.
    ///   - storeDirectoryNames: Entries of the store root, for the no-automation heuristic.
    init(rows: [EnvelopeIndexReader.MailboxRow], jxaMailboxes: [MailboxInfo]?, storeDirectoryNames: Set<String>) {
        self.rows = rows
        self.jxaMailboxes = jxaMailboxes
        var names: [String: String] = [:]
        for info in jxaMailboxes ?? [] {
            if let id = info.ref.accountID { names[id] = info.ref.account }
        }
        self.policy = ActiveAccountPolicy(
            automationAccountIDs: jxaMailboxes.map { Set($0.compactMap(\.ref.accountID)) },
            automationNames: names,
            storeDirectoryNames: storeDirectoryNames)
    }

    /// Mailboxes of active accounts (plus On My Mac) with live counts, sorted by account then path.
    func mailboxInfos() -> [MailboxInfo] {
        var jxaKinds: [String: MailboxKind] = [:]
        for info in jxaMailboxes ?? [] {
            jxaKinds[Self.key(info.ref.accountID, info.ref.name.split(separator: "/").map(String.init))] = info.kind
        }
        var out: [MailboxInfo] = []
        for row in rows {
            guard let url = MailboxURL(row.url), policy.includes(url) else { continue }
            let accountID: String? = url.isLocal ? nil : url.accountID
            let kind: MailboxKind
            if jxaMailboxes != nil {
                kind = jxaKinds[Self.key(accountID, url.pathComponents)] ?? .custom
            } else {
                // RFC 3501 reserves "INBOX"; any other role would need a localised name, so stay custom.
                kind = (url.scheme == "imap" && url.pathComponents == ["INBOX"]) ? .inbox : .custom
            }
            let ref = MailboxRef(account: policy.displayName(forAccountID: url.accountID, isLocal: url.isLocal),
                                 name: url.displayPath, accountID: accountID, mailboxURL: row.url)
            out.append(MailboxInfo(ref: ref, messageCount: row.liveCount, unreadCount: row.unreadCount, kind: kind))
        }
        return out.sorted {
            let a = $0.ref.account.localizedCaseInsensitiveCompare($1.ref.account)
            if a != .orderedSame { return a == .orderedAscending }
            return $0.ref.name.localizedCaseInsensitiveCompare($1.ref.name) == .orderedAscending
        }
    }

    /// The SQLite mailbox URL for a ref: its own `mailboxURL`, else a match by account ID and path
    /// (local mailboxes match by path alone). Nil when nothing matches.
    func sqliteURL(for ref: MailboxRef) -> String? {
        if let url = ref.mailboxURL { return url }
        let wanted = ref.name
        for row in rows {
            guard let url = MailboxURL(row.url), url.displayPath == wanted else { continue }
            if let id = ref.accountID {
                if url.accountID == id { return row.url }
            } else if url.isLocal {
                return row.url
            }
        }
        return nil
    }

    /// JXA address for a ref; needs no store access.
    static func jxaAddress(for ref: MailboxRef) -> JXAMailboxAddress {
        if let raw = ref.mailboxURL, let url = MailboxURL(raw) {
            return JXAMailboxAddress(accountID: url.isLocal ? nil : url.accountID, path: url.pathComponents)
        }
        return JXAMailboxAddress(accountID: ref.accountID, path: ref.name.split(separator: "/").map(String.init))
    }

    private static func key(_ accountID: String?, _ path: [String]) -> String {
        (accountID ?? "") + "\u{0}" + path.joined(separator: "\u{0}")
    }
}
