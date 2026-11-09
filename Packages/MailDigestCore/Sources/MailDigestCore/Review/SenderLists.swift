import Foundation

/// The four sender lists in Settings > Senders. Each maps onto one `DigestSettings` array, so the tab, the
/// context menus on suggestion and info cards and the learned-ignore notice all edit settings through the same code.
///
/// A list holds exact addresses ("name@example.com") and whole-domain rules ("@example.com", which also covers
/// subdomains). Within a list an exact address outranks a domain rule; across lists Blocked > VIP > Ignored > Newsletters.
public enum SenderList: String, CaseIterable, Sendable, Identifiable, Hashable {
    case vip, blocked, ignored, newsletters

    public var id: String { rawValue }

    /// Segment title and menu noun.
    public var title: String {
        switch self {
        case .vip: "VIP"
        case .blocked: "Blocked"
        case .ignored: "Ignored"
        case .newsletters: "Newsletters"
        }
    }

    /// The one-line description shown under the segmented control.
    public var summary: String {
        switch self {
        case .vip:
            "VIP senders always get a full summary, even when an email looks like a newsletter. Add a whole domain with @example.com."
        case .blocked:
            "Blocked senders are never read."
        case .ignored:
            "Ignored senders are skipped without a summary."
        case .newsletters:
            "Newsletters from these senders can suggest up to \(MailFilter.trustedNewsletterSuggestionLimit) reminders each. Blocked, VIP and ignored rules still come first."
        }
    }

    /// The context-menu title for adding a sender to this list.
    public var menuTitle: String {
        switch self {
        case .vip: "Add Sender to VIP"
        case .blocked: "Block Sender"
        case .ignored: "Ignore Sender"
        case .newsletters: "Trust as Newsletter"
        }
    }

    /// Matches `MailFilter`: Blocked, then VIP, then Ignored, then Trusted Newsletter.
    public static let precedenceFootnote =
        "When a sender is on more than one list, Blocked wins, then VIP, then Ignored, then Newsletters."

    fileprivate var keyPath: WritableKeyPath<DigestSettings, [String]> {
        switch self {
        case .vip: \.vipSenders
        case .blocked: \.blockedSenders
        case .ignored: \.ignoredSenders
        case .newsletters: \.trustedNewsletterSenders
        }
    }
}

extension DigestSettings {
    /// The addresses on `list`, as stored.
    public func senders(in list: SenderList) -> [String] { self[keyPath: list.keyPath] }

    /// Whether `sender` is already covered by `list`. A bare address or "Name <address>" is covered by an exact
    /// entry or a matching domain rule; a domain entry ("@example.com") is covered only by the same entry.
    public func contains(sender: String, in list: SenderList) -> Bool {
        let entries = self[keyPath: list.keyPath]
        if let rule = SenderRule(sender), rule.kind == .domain {
            return entries.contains { MailFilter.address(from: $0) == rule.text }
        }
        return SenderRuleSet(entries).matches(sender)
    }

    /// Whether `text` is a valid rule: a full email address or a whole domain such as "@example.com".
    public static func isMatchableAddress(_ text: String) -> Bool { SenderRule.isValid(text) }

    /// Adds the normalised entry to `list`. Returns false, changing nothing, when it is not a valid address or
    /// domain or is already covered. Other lists are left alone: `MailFilter` decides conflicts by precedence.
    @discardableResult
    public mutating func add(sender: String, to list: SenderList) -> Bool {
        guard let rule = SenderRule(sender), !contains(sender: sender, in: list) else { return false }
        self[keyPath: list.keyPath].append(rule.text)
        return true
    }

    /// Removes `address` from `list` (compared by normalised address).
    public mutating func remove(_ address: String, from list: SenderList) {
        let target = MailFilter.address(from: address)
        self[keyPath: list.keyPath].removeAll { MailFilter.address(from: $0) == target }
    }
}

/// A sender seen in recent mail, offered by "Add from Recent Senders…". Built only from `job_item` rows already
/// stored on this Mac.
public struct RecentSender: Sendable, Equatable, Identifiable {
    public var address: String
    public var name: String
    public var count: Int
    public var lastReceived: Date
    public var id: String { address }

    /// The most frequent senders first, then the most recent. Skips addresses `excluding` or `excludingRules` (including domain rules) already cover and
    /// anything that is not a full address, and takes the newest display name seen for each address.
    public static func rank(_ items: [JobItem], excluding: Set<String> = [], excludingRules: [String] = [],
                              limit: Int = 50) -> [RecentSender] {
        let rules = SenderRuleSet(excludingRules)
        var byAddress: [String: RecentSender] = [:]
        for item in items {
            let address = MailFilter.address(from: item.sender)
            guard SenderRule(address)?.kind == .address, !excluding.contains(address), !rules.matches(address) else { continue }
            if var existing = byAddress[address] {
                existing.count += 1
                if item.receivedAt > existing.lastReceived {
                    existing.lastReceived = item.receivedAt
                    existing.name = ReviewPresentation.senderName(item.sender)
                }
                byAddress[address] = existing
            } else {
                byAddress[address] = RecentSender(address: address, name: ReviewPresentation.senderName(item.sender),
                                                  count: 1, lastReceived: item.receivedAt)
            }
        }
        let ranked = byAddress.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastReceived != $1.lastReceived { return $0.lastReceived > $1.lastReceived }
            return $0.address < $1.address
        }
        return Array(ranked.prefix(limit))
    }
}
