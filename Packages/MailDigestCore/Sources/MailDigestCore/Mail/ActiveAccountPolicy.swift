import Foundation

/// Decides which mailboxes belong to accounts that are currently active in Mail (Q33).
public struct ActiveAccountPolicy: Sendable, Equatable {
    /// Account IDs from `Mail.accounts()`, when automation answered.
    public var automationAccountIDs: Set<String>?
    /// Account display names by ID from automation.
    public var automationNames: [String: String]
    /// Directory names found in the active store root.
    public var storeDirectoryNames: Set<String>

    public init(automationAccountIDs: Set<String>?, automationNames: [String: String] = [:],
                storeDirectoryNames: Set<String>) {
        self.automationAccountIDs = automationAccountIDs
        self.automationNames = automationNames
        self.storeDirectoryNames = storeDirectoryNames
    }

    /// Local mailboxes always count; others need automation membership, or (without automation)
    /// a directory named exactly the account ID. `OrphanedAccount - <UUID>` never matches.
    public func includes(_ url: MailboxURL) -> Bool {
        if url.isLocal { return true }
        if let ids = automationAccountIDs { return ids.contains(url.accountID) }
        return storeDirectoryNames.contains(url.accountID)
    }

    /// A friendly account name, never exposing the full UUID.
    public func displayName(forAccountID id: String, isLocal: Bool = false) -> String {
        if let name = automationNames[id], !name.isEmpty { return name }
        if isLocal { return "On My Mac" }
        return "Account (\(id.prefix(8)))"
    }
}
