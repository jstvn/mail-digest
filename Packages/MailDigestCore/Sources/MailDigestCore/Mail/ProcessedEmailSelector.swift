import Foundation

/// One row in the Processed tab.
public struct ProcessedEntry: Sendable, Equatable, Identifiable {
    /// Same as the email id.
    public var id: String { emailID }
    public var emailID: String
    public var email: EmailContext
    /// One-line summary; nil for blocked-sender emails (they were never summarised).
    public var summary: String?
    public var category: Category?
    /// "2 reminders added", "1 reminder added", "info only" or "blocked sender".
    public var outcome: String
    /// Ticked by default.
    public var selected: Bool

    public init(emailID: String, email: EmailContext, summary: String?, category: Category?,
                outcome: String, selected: Bool = true) {
        self.emailID = emailID
        self.email = email
        self.summary = summary
        self.category = category
        self.outcome = outcome
        self.selected = selected
    }
}

/// Fully handled emails, and blocked-sender emails listed separately.
public struct ProcessedEmails: Sendable, Equatable {
    public var handled: [ProcessedEntry]
    public var blocked: [ProcessedEntry]

    public init(handled: [ProcessedEntry], blocked: [ProcessedEntry]) {
        self.handled = handled
        self.blocked = blocked
    }
}

/// Entries of one account, in digest order.
public struct ProcessedAccountGroup: Sendable, Equatable {
    public var account: String
    public var entries: [ProcessedEntry]
}

/// Decides which emails of a digest are safe to offer for cleanup.
public struct ProcessedEmailSelector: Sendable {
    public init() {}

    /// Builds the Processed list.
    ///
    /// Handled: has an InfoItem, is not in `skipped`, and every suggestion is approved or dismissed.
    /// The outcome counts approved suggestions; "all dismissed" and "no suggestions" both read "info only".
    /// Blocked: skipped entries with reason "blocked sender" or "ignored sender" (what
    /// `MailFilter.skipReason` produces). Failed and "not found in Mail" entries are never eligible.
    /// Emails without an `EmailContext` are omitted because they can't be located in Mail.
    /// `excluding` drops ids already moved or hidden with Keep.
    public func entries(digest: Digest, emails: [String: EmailContext],
                        excluding: Set<String> = []) -> ProcessedEmails {
        let skippedIDs = Set(digest.skipped.map(\.id))
        let byEmail = Dictionary(grouping: digest.suggestions, by: \.emailID)

        var handled: [ProcessedEntry] = []
        for item in digest.info {
            let id = item.emailID
            guard !excluding.contains(id), !skippedIDs.contains(id), let ctx = emails[id] else { continue }
            let sugs = byEmail[id] ?? []
            // Any pending or failed suggestion still needs the user, so the email stays in the inbox.
            guard sugs.allSatisfy({ $0.status == .approved || $0.status == .dismissed }) else { continue }
            let added = sugs.filter { $0.status == .approved }.count
            let outcome = added == 0 ? "info only" : (added == 1 ? "1 reminder added" : "\(added) reminders added")
            handled.append(ProcessedEntry(emailID: id, email: ctx, summary: item.summary,
                                          category: item.category, outcome: outcome))
        }

        var blocked: [ProcessedEntry] = []
        for s in digest.skipped where s.reason == "blocked sender" || s.reason == "ignored sender" {
            guard !excluding.contains(s.id), let ctx = emails[s.id] else { continue }
            blocked.append(ProcessedEntry(emailID: s.id, email: ctx, summary: nil, category: nil,
                                          outcome: "blocked sender"))
        }
        return ProcessedEmails(handled: handled, blocked: blocked)
    }

    /// Groups by account name (ascending), keeping the given order inside each group.
    public func grouped(_ entries: [ProcessedEntry]) -> [ProcessedAccountGroup] {
        Dictionary(grouping: entries, by: { $0.email.mailbox.account })
            .map { ProcessedAccountGroup(account: $0.key, entries: $0.value) }
            .sorted { $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending }
    }

    /// Ids for the "Select all newsletters" shortcut.
    public func newsletterIDs(_ entries: [ProcessedEntry]) -> Set<String> {
        Set(entries.filter { $0.category == .newsletters }.map(\.id))
    }
}
