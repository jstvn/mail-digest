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

    /// Ids auto-file moves: every eligible email, handled and blocked, in list order. Pass the moved,
    /// kept and already-tried ids as `excluding` to `entries` first, so nothing is moved twice.
    public func autoFileIDs(_ processed: ProcessedEmails) -> [String] {
        (processed.handled + processed.blocked).map(\.emailID)
    }

    /// Q42: emails of the current digest auto-file should move now. An email qualifies once its result is
    /// persisted (its job item has a finish time) and it is eligible above; pending, in-flight and failed
    /// emails never are. Emails finished before auto-file was switched on are left alone (no sweep), and
    /// moved, kept, already-tried or undone emails (`dispositions`) are never tried again.
    public func autoFileIDs(digest: Digest, emails: [String: EmailContext], dispositions: MailDispositions,
                            finishedAt: [String: Date], enabledAt: Date) -> [String] {
        let processed = entries(digest: digest, emails: emails,
                                excluding: dispositions.hidden.union(dispositions.autoFileAttempted))
        return autoFileIDs(processed).filter { id in finishedAt[id].map { $0 >= enabledAt } ?? false }
    }

    /// Q94: where auto-file puts an email that qualifies. At least one suggestion and every one dismissed
    /// goes to `dismissed`; anything else (a reminder added, no suggestions, blocked/ignored sender) goes to
    /// `handled`. Callers only pass ids `autoFileIDs` returned, so nothing pending or failed gets here.
    public func autoFileDestination(emailID: String, digest: Digest,
                                    handled: AutoFileDestination,
                                    dismissed: AutoFileDestination) -> AutoFileDestination {
        let sugs = digest.suggestions.filter { $0.emailID == emailID }
        let allDismissed = !sugs.isEmpty && sugs.allSatisfy { $0.status == .dismissed }
        return allDismissed ? dismissed : handled
    }

    /// Q94: the single cleanup action for an auto-file pass over `ids`, routing each email by
    /// `autoFileDestination`. One action means one Undo batch, even when the destinations are mixed.
    public func autoFileAction(ids: [String], digest: Digest, handled: AutoFileDestination,
                               dismissed: AutoFileDestination) -> CleanupAction {
        let trashIDs = Set(ids.filter {
            autoFileDestination(emailID: $0, digest: digest, handled: handled, dismissed: dismissed) == .trash
        })
        if trashIDs.isEmpty { return .moveToFolder(MailCleanup.digestFolderName) }
        if trashIDs.count == ids.count { return .trash }
        return .split(folder: MailCleanup.digestFolderName, trashIDs: trashIDs)
    }

    /// Ids for the "Select all newsletters" shortcut.
    public func newsletterIDs(_ entries: [ProcessedEntry]) -> Set<String> {
        Set(entries.filter { $0.category == .newsletters }.map(\.id))
    }
}
