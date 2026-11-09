import Foundation

/// One entry on a sender list: an exact address ("name@example.com") or a whole domain ("@example.com").
/// Entries stay plain strings in settings; this type is the single place that decides what they mean.
public struct SenderRule: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Matches one address.
        case address
        /// Matches the domain and every subdomain.
        case domain
    }

    public let kind: Kind
    /// The normalised entry: lowercase, no display name.
    public let text: String

    /// Parses a stored or typed entry ("Name <a@b.com>", "a@b.com" or "@b.com"), or nil when it can never match.
    public init?(_ entry: String) {
        let text = MailFilter.address(from: entry)
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        if parts[0].isEmpty {
            // A domain rule needs a real multi-label domain; "@com" would silently cover a whole TLD.
            let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
            kind = .domain
        } else {
            kind = .address
        }
        self.text = text
    }

    /// Whether `entry` is a valid exact-address or whole-domain rule.
    public static func isValid(_ entry: String) -> Bool { SenderRule(entry) != nil }

    /// Whether this rule covers `address` (already normalised with `MailFilter.address(from:)`).
    /// A domain rule covers the domain and its subdomains, but not lookalikes such as "notexample.com".
    public func matches(address: String) -> Bool {
        switch kind {
        case .address:
            return address == text
        case .domain:
            guard let at = address.lastIndex(of: "@") else { return false }
            let domain = address[address.index(after: at)...]
            let rule = text.dropFirst()
            return domain == rule || domain.hasSuffix("." + rule)
        }
    }
}

/// The rules of one sender list, with exact-address rules taking priority over domain rules.
public struct SenderRuleSet: Sendable {
    private let exact: Set<String>
    private let domains: [SenderRule]

    /// Invalid entries are ignored: they can never match.
    public init<S: Sequence>(_ entries: S) where S.Element == String {
        var exact = Set<String>()
        var domains: [SenderRule] = []
        for entry in entries {
            guard let rule = SenderRule(entry) else { continue }
            if rule.kind == .address { exact.insert(rule.text) } else { domains.append(rule) }
        }
        self.exact = exact
        self.domains = domains
    }

    /// The rule that covers `sender` ("Name <a@b.com>" or a bare address): the exact address if listed,
    /// otherwise the first matching domain rule, otherwise nil.
    public func matchedRule(for sender: String) -> SenderRule? {
        let address = MailFilter.address(from: sender)
        if exact.contains(address), let rule = SenderRule(address) { return rule }
        return domains.first { $0.matches(address: address) }
    }

    public func matches(_ sender: String) -> Bool { matchedRule(for: sender) != nil }
}
