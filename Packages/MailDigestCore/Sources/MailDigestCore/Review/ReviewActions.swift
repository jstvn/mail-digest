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

    public init(sender: String, subject: String, mailbox: MailboxRef) {
        self.sender = sender
        self.subject = subject
        self.mailbox = mailbox
    }
}

/// What the review panel is showing: the digest plus the user's unsaved choices.
public struct ReviewState: Sendable, Equatable {
    public var digest: Digest
    public var selection: Set<UUID>
    /// Category picked in the panel; wins over the email's InfoItem category.
    public var categoryOverrides: [UUID: Category]

    /// Selects the defaults: pending suggestions the pipeline marked preselected.
    public init(digest: Digest) {
        self.digest = digest
        self.selection = Set(digest.suggestions.filter { $0.status == .pending && $0.preselected }.map(\.id))
        self.categoryOverrides = [:]
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

    public init(title: String? = nil, due: Date?? = nil, dueHasTime: Bool? = nil,
                priority: Priority? = nil, category: Category? = nil) {
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
        var sug = s.digest.suggestions[index]
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
        }
        if let hasTime = edit.dueHasTime {
            // A time without a date is meaningless.
            sug.dueHasTime = sug.due == nil ? false : hasTime
        }
        if let priority = edit.priority { sug.priority = priority }
        if let category = edit.category { s.categoryOverrides[id] = category }
        s.digest.suggestions[index] = sug
        return s
    }

    /// Override from the panel, else the email's InfoItem category, else `.other`.
    public static func category(for suggestion: Suggestion, in state: ReviewState) -> Category {
        if let c = state.categoryOverrides[suggestion.id] { return c }
        return state.digest.info.first { $0.emailID == suggestion.emailID }?.category ?? .other
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
        guard !suggestions.isEmpty else { return ApprovalOutcome(listID: storedListID, results: [], decisions: []) }

        let listID: String
        do {
            listID = try await writer.ensureList(named: listName, storedID: storedListID)
        } catch {
            // No list means nothing could be written; all stay retryable.
            var failed: [Suggestion] = []
            for var s in suggestions {
                s.status = .failed
                try? await store.update(s)
                failed.append(s)
            }
            return ApprovalOutcome(listID: nil, results: failed, decisions: [])
        }

        var results: [Suggestion] = []
        var decisions: [Decision] = []
        for var s in suggestions {
            do {
                s.reminderID = try await writer.write(s, category: category(for: s, in: state), toList: listID)
                s.status = .approved
                if let email = emails[s.emailID] {
                    let d = Decision(suggestionID: s.id, sender: MailFilter.address(from: email.sender),
                                     action: .approved, decidedAt: clock.now())
                    try? await store.recordDecision(d)
                    decisions.append(d)
                }
            } catch {
                s.status = .failed
            }
            try? await store.update(s)
            results.append(s)
        }
        return ApprovalOutcome(listID: listID, results: results, decisions: decisions)
    }

    /// Marks suggestions dismissed and records a `.dismissed` decision for each.
    public static func dismiss(_ suggestions: [Suggestion], state: ReviewState, emails: [String: EmailContext],
                               store: DigestStore, clock: Clock) async throws -> ApprovalOutcome {
        var results: [Suggestion] = []
        var decisions: [Decision] = []
        for var s in suggestions {
            s.status = .dismissed
            try await store.update(s)
            if let email = emails[s.emailID] {
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
    public static func reminderNotes(for suggestion: Suggestion, email: EmailContext, category: Category) -> String {
        "From: \(email.sender)\nSubject: \(email.subject)\n\"\(suggestion.evidence)\"\n#\(category.rawValue)"
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
