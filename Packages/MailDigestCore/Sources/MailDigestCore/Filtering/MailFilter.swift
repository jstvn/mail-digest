import Foundation

/// Assigns each email to a processing tier from sender rules and bulk-mail headers.
public struct MailFilter: Sendable {
    public let blockedSenders: Set<String>
    public let ignoredSenders: Set<String>
    public let vipSenders: Set<String>

    /// Entries are email addresses; they are normalised to lowercase.
    public init(blockedSenders: Set<String> = [], ignoredSenders: Set<String> = [], vipSenders: Set<String> = []) {
        self.blockedSenders = Set(blockedSenders.map { $0.lowercased() })
        self.ignoredSenders = Set(ignoredSenders.map { $0.lowercased() })
        self.vipSenders = Set(vipSenders.map { $0.lowercased() })
    }

    /// Extracts the lowercased address from "Name <addr>" or a bare "addr".
    public static func address(from sender: String) -> String {
        var s = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s = String(s[s.index(after: open)..<close])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Tier for a fully loaded email. VIP beats block and bulk rules.
    public func tier(_ email: EmailMessage) -> MailTier {
        let addr = Self.address(from: email.sender)
        if vipSenders.contains(addr) { return .full }
        if blockedSenders.contains(addr) || ignoredSenders.contains(addr) { return .skip }
        return hasBulkHeaders(email.headers) || Self.hasBulkLocalPart(addr) ? .infoOnly : .full
    }

    /// Estimate from the sender alone, for the job preview (headers aren't loaded yet).
    public func estimatedTier(for header: MessageHeader) -> MailTier {
        let addr = Self.address(from: header.sender)
        if vipSenders.contains(addr) { return .full }
        if blockedSenders.contains(addr) || ignoredSenders.contains(addr) { return .skip }
        return Self.hasBulkLocalPart(addr) ? .infoOnly : .full
    }

    /// Why an email is skipped, or nil if it isn't in the skip tier.
    public func skipReason(_ email: EmailMessage) -> String? {
        guard tier(email) == .skip else { return nil }
        let addr = Self.address(from: email.sender)
        return blockedSenders.contains(addr) ? "blocked sender" : "ignored sender"
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
