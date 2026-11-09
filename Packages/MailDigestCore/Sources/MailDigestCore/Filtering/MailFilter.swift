import Foundation

/// Assigns each email to a processing tier from sender rules and bulk-mail headers.
public struct MailFilter: Sendable {
    public let blockedSenders: Set<String>
    public let ignoredSenders: Set<String>
    public let vipSenders: Set<String>
    /// Newsletter senders whose mail may produce task suggestions despite bulk headers (Q16, Q9).
    public let trustedNewsletterSenders: Set<String>

    /// Per-email suggestion limit for ordinary mail, including VIP mail.
    public static let ordinarySuggestionLimit = 3
    /// Per-email suggestion limit for a Trusted Newsletter sender.
    public static let trustedNewsletterSuggestionLimit = 8

    private let rules: [SenderList: SenderRuleSet]

    /// Entries are exact addresses or whole domains ("@example.com"); they are normalised to lowercase.
    public init(blockedSenders: Set<String> = [], ignoredSenders: Set<String> = [], vipSenders: Set<String> = [],
                trustedNewsletterSenders: Set<String> = []) {
        self.blockedSenders = Set(blockedSenders.map { $0.lowercased() })
        self.ignoredSenders = Set(ignoredSenders.map { $0.lowercased() })
        self.vipSenders = Set(vipSenders.map { $0.lowercased() })
        self.trustedNewsletterSenders = Set(trustedNewsletterSenders.map { $0.lowercased() })
        rules = [.blocked: SenderRuleSet(self.blockedSenders), .ignored: SenderRuleSet(self.ignoredSenders),
                 .vip: SenderRuleSet(self.vipSenders), .newsletters: SenderRuleSet(self.trustedNewsletterSenders)]
    }

    /// The rule on `list` that covers `sender` (exact address before domain), or nil. The one place every
    /// sender-list check goes through.
    public func matchedRule(for sender: String, in list: SenderList) -> SenderRule? {
        rules[list]?.matchedRule(for: sender)
    }

    /// Whether any rule on `list` covers `sender`.
    public func matches(_ sender: String, in list: SenderList) -> Bool {
        matchedRule(for: sender, in: list) != nil
    }

    /// Extracts the lowercased address from "Name <addr>" or a bare "addr".
    public static func address(from sender: String) -> String {
        var s = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s = String(s[s.index(after: open)..<close])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Tier for a fully loaded email, in Q9 order:
    /// Blocked → VIP → Ignored → Trusted Newsletter → ordinary bulk/newsletter → normal mail.
    public func tier(_ email: EmailMessage) -> MailTier {
        let addr = Self.address(from: email.sender)
        return senderTier(addr) ?? (hasBulkHeaders(email.headers) || Self.hasBulkLocalPart(addr) ? .infoOnly : .full)
    }

    /// Estimate from the sender alone, for the job preview (headers aren't loaded yet).
    /// Uses the same sender precedence as `tier(_:)`.
    public func estimatedTier(for header: MessageHeader) -> MailTier {
        let addr = Self.address(from: header.sender)
        return senderTier(addr) ?? (Self.hasBulkLocalPart(addr) ? .infoOnly : .full)
    }

    /// True when the email gets Trusted Newsletter treatment: the sender is on the allowlist and no
    /// higher-precedence rule (block, VIP, ignore) applies. VIP mail keeps the ordinary limit.
    public func isTrustedNewsletter(_ email: EmailMessage) -> Bool {
        let addr = Self.address(from: email.sender)
        return matches(addr, in: .newsletters) && !matches(addr, in: .blocked)
            && !matches(addr, in: .vip) && !matches(addr, in: .ignored)
    }

    /// The most task suggestions this email may produce: 8 for a Trusted Newsletter, otherwise 3.
    public func suggestionLimit(for email: EmailMessage) -> Int {
        isTrustedNewsletter(email) ? Self.trustedNewsletterSuggestionLimit : Self.ordinarySuggestionLimit
    }

    /// The tier decided by sender rules alone, or nil when the bulk checks decide.
    private func senderTier(_ addr: String) -> MailTier? {
        if matches(addr, in: .blocked) { return .skip }
        if matches(addr, in: .vip) { return .full }
        if matches(addr, in: .ignored) { return .skip }
        if matches(addr, in: .newsletters) { return .full }
        return nil
    }

    /// Why an email is skipped, or nil if it isn't in the skip tier.
    public func skipReason(_ email: EmailMessage) -> String? {
        guard tier(email) == .skip else { return nil }
        let addr = Self.address(from: email.sender)
        return matches(addr, in: .blocked) ? "blocked sender" : "ignored sender"
    }

    private func hasBulkHeaders(_ headers: [String: String]) -> Bool {
        // Lookup is case-insensitive in case a source doesn't use canonical spellings.
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?
                .value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let v = value("List-Unsubscribe"), !v.isEmpty { return true }
        if let v = value("Precedence")?.lowercased(), v == "bulk" || v == "list" { return true }
        // RFC 3834: "no" means a human sent it.
        if let v = value("Auto-Submitted"), !v.isEmpty, v.lowercased() != "no" { return true }
        return false
    }

    private static func hasBulkLocalPart(_ address: String) -> Bool {
        let local = address.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? address
        return ["no-reply", "noreply", "newsletter"].contains { local.contains($0) }
    }
}
