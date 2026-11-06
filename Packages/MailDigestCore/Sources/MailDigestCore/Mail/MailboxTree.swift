import Foundation

/// One mailbox row in the job setup tree.
public struct MailboxTreeRow: Sendable, Equatable, Identifiable {
    public var info: MailboxInfo
    /// 0 for a top-level mailbox; nested folders ("Projects/2026") are indented one level per component.
    public var depth: Int
    /// The last path component, as Mail's sidebar shows it.
    public var title: String

    public var id: MailboxRef { info.ref }
}

/// An account and its mailboxes, in sidebar-like order.
public struct MailboxTreeAccount: Sendable, Equatable, Identifiable {
    public var account: String
    public var rows: [MailboxTreeRow]

    public var id: String { account }
}

/// Groups the mailboxes from `listMailboxes()` by account for the job setup sheet. Pure.
public enum MailboxTree {
    /// Kinds hidden until "Show all mailboxes": processing them rarely makes sense.
    public static let hiddenKinds: Set<MailboxKind> = [.sent, .drafts, .junk, .trash]

    /// Accounts sorted by name; inbox first within an account, then folders by path so children follow
    /// their parent. Hidden kinds are dropped unless `showAll`.
    public static func accounts(_ boxes: [MailboxInfo], showAll: Bool) -> [MailboxTreeAccount] {
        let visible = boxes.filter { showAll || !hiddenKinds.contains($0.kind) }
        return Dictionary(grouping: visible, by: { $0.ref.account })
            .map { account, list in
                let sorted = list.sorted {
                    if ($0.kind == .inbox) != ($1.kind == .inbox) { return $0.kind == .inbox }
                    return $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending
                }
                return MailboxTreeAccount(account: account, rows: sorted.map { info in
                    let parts = info.ref.name.split(separator: "/").map(String.init)
                    return MailboxTreeRow(info: info, depth: max(parts.count - 1, 0),
                                          title: parts.last ?? info.ref.name)
                })
            }
            .sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
    }

    /// The "All Inboxes" shortcut: every account's inbox.
    public static func inboxes(_ boxes: [MailboxInfo]) -> [MailboxRef] {
        boxes.filter { $0.kind == .inbox }.map(\.ref)
    }
}
