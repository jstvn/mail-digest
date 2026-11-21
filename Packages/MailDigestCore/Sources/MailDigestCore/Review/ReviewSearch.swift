import Foundation

/// The local, in-memory filter behind a canvas's search field. It never persists anything.
public enum ReviewSearch {
    /// True when every whitespace-separated term of `query` appears in some field, ignoring case and accents.
    /// A blank query matches everything.
    public static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = fields.joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Title, sender and evidence of a suggestion.
    public static func fields(for record: SuggestionRecord) -> [String] {
        [record.suggestion.title, record.suggestion.evidence] + senderFields(record.email)
    }

    /// Summary, key facts, sender and subject of an info item.
    public static func fields(for item: InfoItem, email: EmailContext?) -> [String] {
        [item.summary] + item.keyFacts + senderFields(email) + [email?.subject ?? ""]
    }

    /// Sender, subject and reason of a skipped email.
    public static func fields(for skipped: SkippedEmail) -> [String] {
        [skipped.sender, ReviewPresentation.senderName(skipped.sender), skipped.subject, skipped.reason]
    }

    private static func senderFields(_ email: EmailContext?) -> [String] {
        guard let sender = email?.sender else { return [] }
        return [ReviewPresentation.senderName(sender), MailFilter.address(from: sender)]
    }
}

/// The spoken form of a suggestion card, so VoiceOver reads it as one element.
public enum SuggestionAccessibility {
    /// "Attend Tanda AI Hackathon. High priority. Needs review. Due in 11 days, Friday 20 November at 5:30 pm.
    /// From Philip Fraser. Selected."
    public static func label(for record: SuggestionRecord, isSelected: Bool, now: Date, calendar: Calendar,
                             locale: Locale = Locale(identifier: "en_AU")) -> String {
        let s = record.suggestion
        var parts = [s.title]
        if !s.steps.isEmpty { parts.append("Steps: " + s.steps.joined(separator: ", ")) }
        if s.priority == .high { parts.append("High priority") }
        if !s.flags.isEmpty { parts.append("Needs review") }
        if let due = s.due { parts.append(dueText(due, hasTime: s.dueHasTime, now: now, calendar: calendar, locale: locale)) }
        else { parts.append("No date") }
        if let sender = record.email?.sender { parts.append("From \(ReviewPresentation.senderName(sender))") }
        switch s.status {
        case .approved: parts.append("Added to Reminders")
        case .dismissed: parts.append("Dismissed")
        case .failed: parts.append("Couldn't be added to Reminders"); if isSelected { parts.append("Selected") }
        case .pending: parts.append(isSelected ? "Selected" : "Not selected")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// "Due in 11 days, Friday 20 November at 5:30 pm", "Due tomorrow", "3 days overdue, Friday 6 November".
    static func dueText(_ due: Date, hasTime: Bool, now: Date, calendar: Calendar, locale: Locale) -> String {
        let relative = RelativeDue.make(due: due, hasTime: hasTime, now: now, calendar: calendar, locale: locale)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).day().month(.wide)
        if !calendar.isDate(due, equalTo: now, toGranularity: .year) { style = style.year() }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: ",", with: "")
        }
        var date = clean(due.formatted(style))
        if hasTime {
            let time = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
            date += " at " + clean(due.formatted(time)).lowercased()
        }
        let lead = relative.isOverdue ? relative.top : "Due " + relative.top.prefix(1).lowercased() + relative.top.dropFirst()
        return "\(lead), \(date)"
    }
}
