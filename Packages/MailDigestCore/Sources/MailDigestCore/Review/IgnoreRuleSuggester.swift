import Foundation

/// A sender the user keeps dismissing, offered as a new Ignored sender.
public struct IgnoreSuggestion: Sendable, Equatable {
    /// Normalised lowercase address.
    public var sender: String
    public var dismissedCount: Int

    public init(sender: String, dismissedCount: Int) {
        self.sender = sender
        self.dismissedCount = dismissedCount
    }
}

/// Learned ignore rules: suggests ignoring a sender after repeated dismissals. It only suggests; the user
/// confirms before anything is added to the Ignored list.
public enum IgnoreRuleSuggester {
    /// Dismissals from one sender before the app offers to ignore it.
    public static let threshold = 5

    /// A suggestion for `sender`, or nil below the threshold or when a rule already covers it. Only dismissals
    /// count (approvals neither count nor reset). Blocked and ignored senders are already skipped, and VIP
    /// outranks Ignored (Q9), so suggesting those would do nothing; declined senders are not asked again.
    public static func suggestion(for sender: String, decisions: [Decision], settings: DigestSettings) -> IgnoreSuggestion? {
        let address = MailFilter.address(from: sender)
        guard !address.isEmpty else { return nil }
        func listed(_ list: [String]) -> Bool { list.contains { MailFilter.address(from: $0) == address } }
        guard !listed(settings.ignoredSenders), !listed(settings.blockedSenders), !listed(settings.vipSenders),
              !listed(settings.declinedIgnoreSuggestions) else { return nil }
        // One suggestion can be dismissed only once, so duplicate rows for it count once.
        let dismissed = Set(decisions.filter {
            $0.action == .dismissed && MailFilter.address(from: $0.sender) == address
        }.map(\.suggestionID))
        guard dismissed.count >= threshold else { return nil }
        return IgnoreSuggestion(sender: address, dismissedCount: dismissed.count)
    }
}
