import Foundation

/// A cross-digest split: records, so each can be acted on against its own digest.
public struct RecordSplit: Sendable, Equatable {
    public var approve: [SuggestionRecord]
    public var dismiss: [SuggestionRecord]
}

/// Session-wide selection across digests. Only explicit overrides are stored on top of the preselected
/// default, so nothing has to be preloaded. Same meaning as `ReviewState.selection`.
public struct ReviewSession: Sendable, Equatable {
    private var overrides: [UUID: Bool] = [:]

    public init() {}

    private static func isSelectable(_ s: Suggestion) -> Bool { s.status == .pending || s.status == .failed }

    /// Selected when overridden, else when pending and preselected (as `ReviewState.init`); settled ones never are.
    public func isSelected(_ suggestion: Suggestion) -> Bool {
        guard Self.isSelectable(suggestion) else { return false }
        return overrides[suggestion.id] ?? (suggestion.status == .pending && suggestion.preselected)
    }

    /// Flips one checkbox; ignored for approved or dismissed suggestions.
    public mutating func toggle(_ suggestion: Suggestion) {
        guard Self.isSelectable(suggestion) else { return }
        overrides[suggestion.id] = !isSelected(suggestion)
    }

    /// Selects the pending records given; like `ReviewActions.selectAll`, failed ones become unselected.
    public mutating func selectAll(_ records: [SuggestionRecord]) {
        for r in records where Self.isSelectable(r.suggestion) { overrides[r.id] = r.suggestion.status == .pending }
    }

    /// Deselects every record given, leaving other sections untouched.
    public mutating func selectNone(_ records: [SuggestionRecord]) {
        for r in records where Self.isSelectable(r.suggestion) { overrides[r.id] = false }
    }

    /// Selected pending or failed records among those given.
    public func selectedCount(in records: [SuggestionRecord]) -> Int { split(records).approve.count }

    /// Unselected pending records among those given (what "Dismiss Unselected" would dismiss).
    public func unselectedCount(in records: [SuggestionRecord]) -> Int { split(records).dismiss.count }

    /// Records for "Add to Reminders" (selected pending or failed) and "Dismiss Unselected" (unselected pending).
    public func recordSplit(_ records: [SuggestionRecord]) -> RecordSplit {
        RecordSplit(
            approve: records.filter { isSelected($0.suggestion) && Self.isSelectable($0.suggestion) },
            dismiss: records.filter { !isSelected($0.suggestion) && $0.suggestion.status == .pending })
    }

    /// Same split as suggestions, matching `ReviewActions.split`.
    public func split(_ records: [SuggestionRecord]) -> ReviewSplit {
        let s = recordSplit(records)
        return ReviewSplit(approve: s.approve.map(\.suggestion), dismiss: s.dismiss.map(\.suggestion))
    }

    /// Records the outcome of approve or dismiss like `ReviewActions.merge`: a failed suggestion stays
    /// selected for retry; anything else drops its override.
    public mutating func apply(_ results: [Suggestion]) {
        for r in results {
            if r.status == .failed { overrides[r.id] = true } else { overrides[r.id] = nil }
        }
    }
}
