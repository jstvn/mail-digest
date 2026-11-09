import Foundation

/// Errors from editing or acting on suggestions in the review panel.
public enum ReviewError: Error, Equatable {
    case invalidTitle
    case notEditable
    case unknownSuggestion
}

/// The email facts a decision or a Reminders note needs; built by the app from job_item rows.
public struct EmailContext: Sendable, Equatable {
    public var sender: String
    public var subject: String
    public var mailbox: MailboxRef
    /// When the email arrived (Processed tab); nil when unknown.
    public var receivedAt: Date?
    /// Mail's own id for the message, a lookup hint for mail actions (never identity).
    public var storeRowID: Int64?

    public init(sender: String, subject: String, mailbox: MailboxRef, receivedAt: Date? = nil, storeRowID: Int64? = nil) {
        self.sender = sender
        self.subject = subject
        self.mailbox = mailbox
        self.receivedAt = receivedAt
        self.storeRowID = storeRowID
    }

    /// The context a queue item supplies.
    public init(item: JobItem) {
        self.init(sender: item.sender, subject: item.subject, mailbox: item.mailbox,
                  receivedAt: item.receivedAt, storeRowID: item.storeRowID)
    }
}

/// What the review panel is showing: the digest plus the user's unsaved choices.
public struct ReviewState: Sendable, Equatable {
    public var digest: Digest
    public var selection: Set<UUID>

    /// Selects the defaults: pending suggestions the pipeline marked preselected.
    public init(digest: Digest) {
        self.digest = digest
        self.selection = Set(digest.suggestions.filter { $0.status == .pending && $0.preselected }.map(\.id))
    }
}

/// A partial edit of a suggestion; nil means "leave unchanged".
public struct SuggestionEdit: Sendable, Equatable {
    public var title: String?
    /// `.some(nil)` clears the date (the "no date" toggle) and also clears the time flag.
    public var due: Date??
    public var dueHasTime: Bool?
    public var priority: Priority?
    public var category: Category?
    /// `.some(nil)` goes back to the default list from Settings.
    public var reminderListID: String??
    /// Free text; blank clears the notes.
    public var notes: String?

    public init(title: String? = nil, due: Date?? = nil, dueHasTime: Bool? = nil,
                priority: Priority? = nil, category: Category? = nil,
                reminderListID: String?? = nil, notes: String? = nil) {
        self.reminderListID = reminderListID
        self.notes = notes
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.category = category
    }
}

/// The two lists behind "Add selected" and "Dismiss unselected".
public struct ReviewSplit: Sendable, Equatable {
    public var approve: [Suggestion]
    public var dismiss: [Suggestion]
}

/// Result of writing or dismissing suggestions.
public struct ApprovalOutcome: Sendable, Equatable {
    /// The Reminders list used, or nil if the list could not be created (or for dismissals).
    public var listID: String?
    /// Updated suggestions: `.approved` with reminderID, `.failed`, or `.dismissed`.
    public var results: [Suggestion]
    /// Decisions recorded, for successful writes and dismissals only.
    public var decisions: [Decision]
}

/// Pure review-panel logic plus the approve and dismiss flows. Nothing is written unless
/// the caller passes the suggestion in, so only explicit user clicks reach Reminders.
public enum ReviewActions {
    // MARK: Selection

    /// Flips one suggestion's checkbox; only pending or failed suggestions can be selected.
    public static func toggle(_ id: UUID, in state: ReviewState) -> ReviewState {
        var s = state
        if s.selection.contains(id) {
            s.selection.remove(id)
        } else if let sug = s.digest.suggestions.first(where: { $0.id == id }),
                  sug.status == .pending || sug.status == .failed {
            s.selection.insert(id)
        }
        return s
    }

    /// Selects every pending suggestion.
    public static func selectAll(_ state: ReviewState) -> ReviewState {
        var s = state
        s.selection = Set(s.digest.suggestions.filter { $0.status == .pending }.map(\.id))
        return s
    }

    /// Clears the selection.
    public static func selectNone(_ state: ReviewState) -> ReviewState {
        var s = state
        s.selection = []
        return s
    }

    // MARK: Editing

    /// Applies an edit. Only pending or failed suggestions are editable; titles stay 3...80 chars, no URL.
    public static func apply(_ edit: SuggestionEdit, to id: UUID, in state: ReviewState) throws -> ReviewState {
        guard let index = state.digest.suggestions.firstIndex(where: { $0.id == id }) else {
            throw ReviewError.unknownSuggestion
        }
        var s = state
        s.digest.suggestions[index] = try applying(edit, to: s.digest.suggestions[index])
        return s
    }

    /// The edited copy of one suggestion; the single implementation behind `apply` and `edit(_:record:store:)`.
    public static func applying(_ edit: SuggestionEdit, to suggestion: Suggestion) throws -> Suggestion {
        var sug = suggestion
        guard sug.status == .pending || sug.status == .failed else { throw ReviewError.notEditable }

        if let title = edit.title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = t.lowercased()
            // Same title rule as SuggestionValidator, so edits can't smuggle in links.
            guard (3...80).contains(t.count),
                  !["http://", "https://", "www."].contains(where: lower.contains) else {
                throw ReviewError.invalidTitle
            }
            sug.title = t
        }
        if let due = edit.due {
            sug.due = due
            if due == nil { sug.dueHasTime = false }
            // Every date edit passes through here, so this is the one place the date becomes the user's.
            sug.dueSource = due == nil ? nil : .user
        }
        if let hasTime = edit.dueHasTime {
            // A time without a date is meaningless.
            sug.dueHasTime = sug.due == nil ? false : hasTime
            if sug.due != nil { sug.dueSource = .user }
        }
        if let priority = edit.priority { sug.priority = priority }
        if let category = edit.category { sug.category = category }
        if let list = edit.reminderListID { sug.reminderListID = list }
        if let notes = edit.notes {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            sug.notes = trimmed.isEmpty ? nil : trimmed
        }
        return sug
    }

    /// Cross-digest edit: validates like `apply`, persists the whole suggestion and returns the updated record
    /// (its category follows an edited category). Nothing is written when the edit is invalid.
    public static func edit(_ edit: SuggestionEdit, record: SuggestionRecord, store: DigestStore) async throws -> SuggestionRecord {
        let sug = try applying(edit, to: record.suggestion)
        try await store.update(sug)
        var out = record
        out.suggestion = sug
        if let c = sug.category { out.category = c }
        return out
    }

    /// Applies an edit and persists the whole edited suggestion (Q19), so title, date, priority and
    /// category survive a restart. The store is only written when the edit is valid.
    public static func edit(_ edit: SuggestionEdit, id: UUID, state: ReviewState,
                            store: DigestStore) async throws -> ReviewState {
        let updated = try apply(edit, to: id, in: state)
        if let sug = updated.digest.suggestions.first(where: { $0.id == id }) {
            try await store.update(sug)
        }
        return updated
    }

    /// The suggestion's own category, else the email's InfoItem category (older records), else `.other`.
    public static func category(for suggestion: Suggestion, in state: ReviewState) -> Category {
        category(for: suggestion, info: state.digest.info)
    }

    /// Same rule from a bare info list, shared with records built from a loaded digest.
    public static func category(for suggestion: Suggestion, info: [InfoItem]) -> Category {
        if let c = suggestion.category { return c }
        return info.first { $0.emailID == suggestion.emailID }?.category ?? .other
    }

    // MARK: Split

    /// "Add selected" approves selected pending or failed (retry) suggestions;
    /// "Dismiss unselected" dismisses unselected pending ones.
    public static func split(_ state: ReviewState) -> ReviewSplit {
        let all = state.digest.suggestions
        return ReviewSplit(
            approve: all.filter { state.selection.contains($0.id) && ($0.status == .pending || $0.status == .failed) },
            dismiss: all.filter { !state.selection.contains($0.id) && $0.status == .pending })
    }

    /// Copies updated suggestions back into the state and drops them from the selection
    /// unless they failed (so a retry stays one click away).
    public static func merge(_ results: [Suggestion], into state: ReviewState) -> ReviewState {
        var s = state
        for r in results {
            if let i = s.digest.suggestions.firstIndex(where: { $0.id == r.id }) {
                s.digest.suggestions[i] = r
            }
            if r.status != .failed { s.selection.remove(r.id) }
        }
        return s
    }

    // MARK: Approve and dismiss

    /// Writes the given suggestions to Reminders. Never touches anything outside `suggestions`.
    public static func approve(_ suggestions: [Suggestion], state: ReviewState, emails: [String: EmailContext],
                               writer: ReminderWriter, store: DigestStore, listName: String,
                               storedListID: String?, clock: Clock) async -> ApprovalOutcome {
        await approve(suggestions.map { Entry(suggestion: $0, category: category(for: $0, in: state), email: emails[$0.emailID]) },
                      writer: writer, store: store, listName: listName, storedListID: storedListID, clock: clock)
    }

    /// Cross-digest approve: each record is written with its own category and email, and persisted
    /// against its own digest. Behaves exactly like the per-digest overload.
    public static func approve(_ records: [SuggestionRecord], writer: ReminderWriter, store: DigestStore,
                               listName: String, storedListID: String?, clock: Clock) async -> ApprovalOutcome {
        await approve(records.map { Entry(suggestion: $0.suggestion, category: $0.category, email: $0.email) },
                      writer: writer, store: store, listName: listName, storedListID: storedListID, clock: clock)
    }

    /// Marks suggestions dismissed and records a `.dismissed` decision for each.
    public static func dismiss(_ suggestions: [Suggestion], state: ReviewState, emails: [String: EmailContext],
                               store: DigestStore, clock: Clock) async throws -> ApprovalOutcome {
        try await dismiss(suggestions.map { Entry(suggestion: $0, category: category(for: $0, in: state), email: emails[$0.emailID]) },
                          store: store, clock: clock)
    }

    /// Cross-digest dismiss over records from any number of digests.
    public static func dismiss(_ records: [SuggestionRecord], store: DigestStore, clock: Clock) async throws -> ApprovalOutcome {
        try await dismiss(records.map { Entry(suggestion: $0.suggestion, category: $0.category, email: $0.email) },
                          store: store, clock: clock)
    }

    /// What one approve or dismiss needs per suggestion, whichever API it came through.
    private struct Entry {
        var suggestion: Suggestion
        var category: Category
        var email: EmailContext?
    }

    private static func approve(_ entries: [Entry], writer: ReminderWriter, store: DigestStore, listName: String,
                                storedListID: String?, clock: Clock) async -> ApprovalOutcome {
        guard !entries.isEmpty else { return ApprovalOutcome(listID: storedListID, results: [], decisions: []) }

        let listID: String
        do {
            listID = try await writer.ensureList(named: listName, storedID: storedListID)
        } catch {
            // No list means nothing could be written; all stay retryable.
            var failed: [Suggestion] = []
            for var s in entries.map(\.suggestion) {
                s.status = .failed
                s.decidedAt = nil
                try? await store.update(s)
                failed.append(s)
            }
            return ApprovalOutcome(listID: nil, results: failed, decisions: [])
        }

        var results: [Suggestion] = []
        var decisions: [Decision] = []
        for entry in entries {
            var s = entry.suggestion
            do {
                // A list chosen in the inspector wins, unless it was deleted since: then the default list is used.
                var target = listID
                if let chosen = s.reminderListID, chosen != listID, await writer.listExists(id: chosen) { target = chosen }
                s.reminderID = try await writer.write(s, category: entry.category, email: entry.email, toList: target)
                s.status = .approved
                s.decidedAt = clock.now()
                if let email = entry.email {
                    let d = Decision(suggestionID: s.id, sender: MailFilter.address(from: email.sender),
                                     action: .approved, decidedAt: clock.now())
                    try? await store.recordDecision(d)
                    decisions.append(d)
                }
            } catch {
                s.status = .failed
                s.decidedAt = nil
            }
            try? await store.update(s)
            results.append(s)
        }
        return ApprovalOutcome(listID: listID, results: results, decisions: decisions)
    }

    private static func dismiss(_ entries: [Entry], store: DigestStore, clock: Clock) async throws -> ApprovalOutcome {
        var results: [Suggestion] = []
        var decisions: [Decision] = []
        for entry in entries {
            var s = entry.suggestion
            s.status = .dismissed
            s.decidedAt = clock.now()
            try await store.update(s)
            if let email = entry.email {
                let d = Decision(suggestionID: s.id, sender: MailFilter.address(from: email.sender),
                                 action: .dismissed, decidedAt: clock.now())
                try await store.recordDecision(d)
                decisions.append(d)
            }
            results.append(s)
        }
        return ApprovalOutcome(listID: nil, results: results, decisions: decisions)
    }

    // MARK: Reminders content

    /// The Reminders `notes` text; the trailing `#category` is a searchable hashtag (EventKit has no tag API).
    /// Without email context the From and Subject lines are left out.
    public static func reminderNotes(for suggestion: Suggestion, email: EmailContext?, category: Category) -> String {
        var lines: [String] = []
        // The user's own words come first, set apart from the email details.
        if let notes = suggestion.notes, !notes.isEmpty {
            lines.append(notes)
            lines.append("")
        }
        if let email {
            lines.append("From: \(email.sender)")
            lines.append("Subject: \(email.subject)")
        }
        lines.append("\"\(suggestion.evidence)\"")
        lines.append("#\(category.rawValue)")
        return lines.joined(separator: "\n")
    }

    /// `message://%3C<id>%3E`, which opens the email in Mail.
    public static func messageURL(for emailID: String) -> URL {
        // Keep "@" readable; everything else unsafe is percent-encoded.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        let encoded = emailID.addingPercentEncoding(withAllowedCharacters: allowed) ?? emailID
        return URL(string: "message://%3C\(encoded)%3E")!
    }
}
