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
    /// after the sender's most recent approval count (Q36): an approval resets the count, and nothing expires.
    /// Blocked and ignored senders are already skipped, and VIP outranks Ignored (Q9), so suggesting those
    /// would do nothing; declined senders are not asked again.
    public static func suggestion(for sender: String, decisions: [Decision], settings: DigestSettings) -> IgnoreSuggestion? {
        let address = MailFilter.address(from: sender)
        guard !address.isEmpty else { return nil }
        func listed(_ list: [String]) -> Bool { SenderRuleSet(list).matches(address) }
        guard !listed(settings.ignoredSenders), !listed(settings.blockedSenders), !listed(settings.vipSenders),
              !listed(settings.declinedIgnoreSuggestions) else { return nil }
        let mine = decisions.filter { MailFilter.address(from: $0.sender) == address }
        let lastApproval = mine.filter { $0.action == .approved }.map(\.decidedAt).max()
        // One suggestion can be dismissed only once, so duplicate rows for it count once.
        let dismissed = Set(mine.filter { d in
            d.action == .dismissed && lastApproval.map { d.decidedAt > $0 } ?? true
        }.map(\.suggestionID))
        guard dismissed.count >= threshold else { return nil }
        return IgnoreSuggestion(sender: address, dismissedCount: dismissed.count)
    }
}
