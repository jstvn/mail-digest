import Foundation

/// The Review Queue's local filter menu: priority, category and "has a due date". It lives in memory only and is
/// applied to the loaded pages, so records it hides stay untouched by bulk actions.
public struct ReviewQueueFilter: Sendable, Equatable {
    public var priority: Priority?
    public var category: Category?
    public var hasDueDate = false

    public init(priority: Priority? = nil, category: Category? = nil, hasDueDate: Bool = false) {
        self.priority = priority
        self.category = category
        self.hasDueDate = hasDueDate
    }

    /// Whether any criterion is set.
    public var isActive: Bool { priority != nil || category != nil || hasDueDate }

    public func matches(_ record: SuggestionRecord) -> Bool {
        if let priority, record.suggestion.priority != priority { return false }
        if let category, record.category != category { return false }
        if hasDueDate, record.suggestion.due == nil { return false }
        return true
    }

    public func apply(to records: [SuggestionRecord]) -> [SuggestionRecord] {
        isActive ? records.filter(matches) : records
    }
}

/// Selection movement for the Review Queue's list and inspector.
public enum ReviewQueueNavigation {
    /// The id to select after the visible ids changed from `old` to `new`. A selection that is still there is kept.
    /// One that left (added, dismissed, filtered out) moves to the next surviving row, else the previous one,
    /// else nil, which shows the empty inspector.
    public static func selection(afterChange selected: UUID?, old: [UUID], new: [UUID]) -> UUID? {
        guard let selected else { return nil }
        let survivors = Set(new)
        if survivors.contains(selected) { return selected }
        guard let index = old.firstIndex(of: selected) else { return nil }
        if let next = old[(index + 1)...].first(where: survivors.contains) { return next }
        return old[..<index].last(where: survivors.contains)
    }

    /// The id `offset` rows from `current`, clamped to the list. Without a current row, a forward step lands on the
    /// first and a backward step on the last.
    public static func step(from current: UUID?, by offset: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return offset >= 0 ? ids.first : ids.last }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// "1 of 10", counted within the ids given (the filtered list); nil when nothing is selected.
    public static func positionText(of current: UUID?, in ids: [UUID]) -> String? {
        guard let current, let index = ids.firstIndex(of: current) else { return nil }
        return "\(index + 1) of \(ids.count)"
    }
}

/// Finds where an extracted quote sits in the text it came from, so the inspector can highlight it.
public enum EvidenceHighlight {
    /// The range of `quote` in `excerpt`, ignoring case and differences in whitespace (a line break or double space
    /// in the email still matches a single space in the quote). Nil when the quote is empty or not found.
    public static func range(of quote: String, in excerpt: String) -> Range<String.Index>? {
        let needle = fold(quote).folded
        guard !needle.isEmpty else { return nil }
        let hay = fold(excerpt)
        guard hay.folded.count >= needle.count else { return nil }
        let chars = hay.folded
        var start = 0
        while start + needle.count <= chars.count {
            if Array(chars[start..<(start + needle.count)]) == needle {
                let first = hay.origins[start]
                let last = hay.origins[start + needle.count - 1]
                // The matched character may itself be several scalars; end after it.
                let end = excerpt.index(after: last)
                return first..<end
            }
            start += 1
        }
        return nil
    }

    /// Lower-cased characters with whitespace runs collapsed to one space and trimmed, each remembering which
    /// character of the original it came from.
    private static func fold(_ text: String) -> (folded: [Character], origins: [String.Index]) {
        var out: [Character] = []
        var origins: [String.Index] = []
        var pendingSpace: String.Index?
        for index in text.indices {
            let ch = text[index]
            if ch.isWhitespace {
                if pendingSpace == nil { pendingSpace = index }
                continue
            }
            if let space = pendingSpace, !out.isEmpty {
                out.append(" ")
                origins.append(space)
            }
            pendingSpace = nil
            for lowered in ch.lowercased() {
                out.append(lowered)
                origins.append(index)
            }
        }
        return (out, origins)
    }
}
