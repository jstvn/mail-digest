import Foundation

/// The suggestions the panel shows first, plus how many more are behind "Show all" (Q16).
public struct SuggestionPage: Sendable, Equatable {
    public var visible: [Suggestion]
    public var hiddenCount: Int
}

/// One category block of the INFO section.
public struct InfoGroup: Sendable, Equatable, Identifiable {
    public var category: Category
    /// Sorted by importance, highest first.
    public var items: [InfoItem]
    /// Newsletters start collapsed; everything else starts open.
    public var collapsedByDefault: Bool

    public var id: Category { category }
    public var maxImportance: Int { items.map(\.importance).max() ?? 0 }
}

/// Pure formatting and grouping for the review panel, the progress strip and the menu.
/// Everything is Foundation-only so it can be unit-tested; time and locale are injected.
public enum ReviewPresentation {
    // MARK: Suggestions

    /// Suggestions the user can still act on, in digest order.
    public static func actionable(_ suggestions: [Suggestion]) -> [Suggestion] {
        suggestions.filter { $0.status == .pending || $0.status == .failed }
    }

    /// Pending suggestions, for the menu bar badge.
    public static func pendingCount(_ digest: Digest?) -> Int {
        digest?.suggestions.filter { $0.status == .pending }.count ?? 0
    }

    /// Presentation threshold (Q16). With a `limit`, shows the highest-confidence suggestions first (kept in
    /// digest order) and reports how many are hidden; `showAll` or a nil limit (Backlog) shows everything.
    /// Nothing is dropped from the data, only from this page.
    public static func page(_ suggestions: [Suggestion], limit: Int?, showAll: Bool) -> SuggestionPage {
        guard let limit, !showAll, suggestions.count > limit else {
            return SuggestionPage(visible: suggestions, hiddenCount: 0)
        }
        let keep = Set(suggestions.enumerated()
            .sorted { $0.element.confidence != $1.element.confidence
                ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset }
            .prefix(limit).map(\.offset))
        let visible = suggestions.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        return SuggestionPage(visible: visible, hiddenCount: suggestions.count - visible.count)
    }

    /// Info grouped by category; groups with the most important item come first, ties follow `Category` order.
    public static func infoGroups(_ info: [InfoItem]) -> [InfoGroup] {
        let order = Category.allCases
        return Dictionary(grouping: info, by: \.category)
            .map { category, items in
                InfoGroup(category: category,
                          items: items.enumerated()
                              .sorted { $0.element.importance != $1.element.importance
                                  ? $0.element.importance > $1.element.importance : $0.offset < $1.offset }
                              .map(\.element),
                          collapsedByDefault: category == .newsletters)
            }
            .sorted {
                $0.maxImportance != $1.maxImportance
                    ? $0.maxImportance > $1.maxImportance
                    : (order.firstIndex(of: $0.category) ?? 0) < (order.firstIndex(of: $1.category) ?? 0)
            }
    }

    /// Readable text for a validator flag id; unknown ids fall back to a tidied version of the id.
    public static func flagDescription(_ flag: String) -> String {
        switch flag {
        case "money-new-sender": return "Payment request from a new sender"
        default: return flag.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// "Ray White" from "Ray White <a@b.com>"; the bare address when there is no name.
    public static func senderName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<") {
            let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
            if !name.isEmpty { return name }
        }
        return MailFilter.address(from: sender)
    }

    // MARK: Header

    /// "Today · Wed 4 Nov · 23 emails". Uses "Today" only when the digest was created on `now`'s day.
    public static func headerTitle(_ digest: Digest, now: Date, calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        let day = formatter.string(from: digest.createdAt)
        let prefix = calendar.isDate(digest.createdAt, inSameDayAs: now) ? "Today" : "Last digest"
        let noun = digest.emailCount == 1 ? "email" : "emails"
        return "\(prefix) · \(day) · \(digest.emailCount) \(noun)"
    }

    /// "8 emails processed · 2 suggestions"; the suggestions part is left out when there are none.
    /// `suggestionCount` is every suggestion in the content whatever its status, so it stays put while triaging.
    public static func countsSubtitle(emailCount: Int, suggestionCount: Int) -> String {
        var text = "\(emailCount) \(emailCount == 1 ? "email" : "emails") processed"
        if suggestionCount > 0 { text += " · \(suggestionCount) \(suggestionCount == 1 ? "suggestion" : "suggestions")" }
        return text
    }

    /// True for the count-only sentence the pipeline writes when the model gave no headline
    /// ("12 emails, 3 suggestions."); the header already shows those counts, so it hides this one.
    public static func isCountOnlyHeadline(_ headline: String) -> Bool {
        DigestPipeline.isFallbackHeadline(headline.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "now", "5m ago", "21h ago", "3d ago" or "2w ago": the short age the system's relative formatter doesn't give.
    public static func compactAge(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        case ..<604_800: return "\(seconds / 86_400)d ago"
        default: return "\(seconds / 604_800)w ago"
        }
    }

    // MARK: Key facts

    /// Key facts worth showing: drops a fact that is only the sender (or the sender with a corporate suffix), the reader or a bare date, because the
    /// row already shows (or implies) those. Compared whole-string, case-insensitively, after trimming
    /// whitespace, leading bullets and surrounding punctuation. "Due 2026-12-01" and "Total $17.45" stay.
    /// `userNames` are full names; the full name and each single word of it count as the reader.
    public static func displayFacts(_ facts: [String], sender: String?, userNames: [String]) -> [String] {
        var banned = Set<String>()
        if let sender {
            banned.insert(factKey(sender))
            banned.insert(factKey(senderName(sender)))
            banned.insert(factKey(MailFilter.address(from: sender)))
        }
        for name in userNames {
            banned.insert(factKey(name))
            for token in name.split(whereSeparator: \.isWhitespace) { banned.insert(factKey(String(token))) }
        }
        banned.remove("")
        let senderWords = sender.map { factWords(senderName($0)) } ?? []
        return facts.filter { fact in
            let key = factKey(fact)
            return !key.isEmpty && !banned.contains(key) && !isBareISODate(key) && !isBareReadableDate(key)
                && !isSenderVariant(key, senderWords: senderWords)
        }
    }

    private static let corporateSuffixes: Set<String> = ["hq", "team", "inc", "ltd", "pty", "llc", "co", "support"]

    private static func factWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// True when the fact and the sender's display name differ only by corporate suffixes ("Letterboxd HQ"
    /// for sender "Letterboxd", or the reverse). A fact with any other extra word ("Letterboxd Pro") is kept.
    private static func isSenderVariant(_ key: String, senderWords: [String]) -> Bool {
        let fact = factWords(key)
        guard !fact.isEmpty, !senderWords.isEmpty else { return false }
        let nonSuffix: ([String]) -> [String] = { $0.filter { !corporateSuffixes.contains($0) } }
        let (f, s) = (nonSuffix(fact), nonSuffix(senderWords))
        // Equal once suffixes are removed: one side is the other plus suffix words only.
        return !f.isEmpty && f == s
    }

    /// "8 Nov, 2026 at 10:36 am", "8 Nov 2026", "Nov 8, 2026", "Friday, November 8 2026 10:36 AM" on their own.
    private static func isBareReadableDate(_ key: String) -> Bool {
        let weekday = #"((mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s+)?"#
        let month = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#
        let time = #"(,?\s+(at\s+)?\d{1,2}:\d{2}(:\d{2})?(\s*[ap]\.?m\.?)?)?"#
        let dayFirst = "^\(weekday)\\d{1,2}(st|nd|rd|th)?\\s+\(month),?\\s+\\d{4}\(time)$"
        let monthFirst = "^\(weekday)\(month)\\s+\\d{1,2}(st|nd|rd|th)?,?\\s+\\d{4}\(time)$"
        return [dayFirst, monthFirst].contains { key.range(of: $0, options: .regularExpression) != nil }
    }

    private static func factKey(_ text: String) -> String {
        var junk = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        junk.insert(charactersIn: "\u{2022}\u{25CF}\u{25E6}\u{00B7}")
        return text.trimmingCharacters(in: junk).lowercased()
    }

    /// 2026-12-01 or 2026-12-01T17:00[:00][Z|+10:00] on its own.
    private static func isBareISODate(_ key: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}([t ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(z|[+-]\d{2}:?\d{2})?)?$"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Progress strip

    /// "Daily digest" or "Backlog".
    public static func jobName(_ kind: JobKind) -> String {
        kind == .daily ? "Daily digest" : "Backlog"
    }

    /// "412 of 1,081 · 6 failed · about 3 h 50 min left".
    public static func counts(_ p: JobProgress, locale: Locale = .current) -> String {
        var parts = ["\(number(p.done, locale)) of \(number(p.total, locale))"]
        if p.failed > 0 { parts.append("\(number(p.failed, locale)) failed") }
        if p.state == .running || p.state == .pausing, let eta = p.eta, let text = etaText(eta) {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    /// Compact line for the States table: "Reading 12 of 23 emails · 2 failed · about 4 min left".
    public static func readingSummary(_ p: JobProgress, locale: Locale = .current) -> String {
        var text = "Reading \(number(min(p.done + 1, max(p.total, 1)), locale)) of \(number(p.total, locale)) emails"
        if p.failed > 0 { text += " · \(number(p.failed, locale)) failed" }
        if let eta = p.eta, let left = etaText(eta) { text += " · \(left)" }
        return text
    }

    /// "about 3 h 50 min left", "about 4 min left", or nil when the estimate is under a minute.
    public static func etaText(_ eta: TimeInterval) -> String? {
        guard eta >= 60 else { return nil }
        let minutes = Int((eta / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min left" }
        let (h, m) = minutes.quotientAndRemainder(dividingBy: 60)
        return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
    }

    /// "Summarising · Ray White · Rent due Friday · Outlook Inbox", or nil when no email is active.
    public static func nowLine(_ p: JobProgress) -> String? {
        guard let c = p.current else { return nil }
        return ([stageVerb(p.stage), senderName(c.sender), c.subject, "\(c.mailbox.account) \(c.mailbox.name)"])
            .joined(separator: " · ")
    }

    /// Where a paused job stopped:
    /// "Paused after #412 · Ray White · Rent due Friday. Next: #413 · QUT Canvas · Assessment 2 reminder".
    /// Falls back to "Paused · 412 of 2,960" when there is no finished email yet. `reason` is the auto-pause
    /// reason (battery, Low Power Mode, heat, quiet hours, Daily job), when one exists.
    public static func pausedText(_ p: JobProgress, reason: String? = nil, locale: Locale = .current) -> String {
        var text: String
        if let last = p.lastFinished {
            text = "Paused after #\(last.position) · \(senderName(last.sender)) · \(last.subject)"
            if let next = p.nextUp {
                text += ". Next: #\(next.position) · \(senderName(next.sender)) · \(next.subject)"
            }
        } else {
            text = "Paused · \(number(p.done, locale)) of \(number(p.total, locale))"
        }
        if let reason, !reason.isEmpty { text += " (\(reason))" }
        return text
    }

    private static func stageVerb(_ stage: JobStage) -> String {
        switch stage {
        case .listing: return "Listing"
        case .fetching: return "Fetching"
        case .summarising: return "Summarising"
        case .validating: return "Checking"
        case .saving: return "Saving"
        }
    }

    private static func number(_ n: Int, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

extension ReviewState {
    /// Brings in a freshly loaded digest while a job is still running. The user's choices on suggestions
    /// already on screen are kept; new pending suggestions get the pipeline's default selection; selection
    /// of suggestions that are no longer pending is dropped.
    public func refreshed(with digest: Digest) -> ReviewState {
        let known = Set(self.digest.suggestions.map(\.id))
        var next = ReviewState(digest: digest)
        let pending = Set(digest.suggestions.filter { $0.status == .pending || $0.status == .failed }.map(\.id))
        let kept = selection.intersection(pending)
        let fresh = next.selection.filter { !known.contains($0) }
        next.selection = kept.union(fresh)
        return next
    }
}
