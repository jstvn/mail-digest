import Foundation

/// Facts the validator needs from outside the email itself.
public struct ValidationContext: Sendable {
    public var today: Date
    /// Pending and approved suggestions from the last 14 days, supplied by the caller.
    public var recentSuggestions: [Suggestion]
    public var senderHasApprovedDecision: Bool
    /// Rule 5: most suggestions kept from this email (3 for ordinary mail, 8 for a Trusted Newsletter).
    public var maxSuggestions: Int

    public init(today: Date, recentSuggestions: [Suggestion], senderHasApprovedDecision: Bool,
                maxSuggestions: Int = MailFilter.ordinarySuggestionLimit) {
        self.today = today
        self.recentSuggestions = recentSuggestions
        self.senderHasApprovedDecision = senderHasApprovedDecision
        // Never above the schema's maximum, whatever the caller passes.
        self.maxSuggestions = min(max(maxSuggestions, 0), MailFilter.trustedNewsletterSuggestionLimit)
    }
}

/// Applies the spec's eight validation rules to raw model tasks.
public struct SuggestionValidator: Sendable {
    public let timeZone: TimeZone
    private let makeID: @Sendable () -> UUID

    public init(timeZone: TimeZone, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.timeZone = timeZone
        self.makeID = makeID
    }

    // MARK: Word lists

    // Rule 3 keeps a due date only if the evidence itself mentions a date or time, which stops
    // the model inventing deadlines. Everything is case-insensitive and word-bounded.
    // "may" is also a common verb, so it only counts next to a number ("5 May", "May 5").
    private static let dateWordPattern: String = {
        let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun"
        let months = "january|february|march|april|june|july|august|september|october|november|december"
            + "|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec"
        let relative = "today|tonight|tomorrow|yesterday|week|weekend|fortnight|month|year"
            + "|morning|afternoon|evening|noon|midnight|eod|eow"
        let mayWithNumber = #"\d{1,2}(?:st|nd|rd|th)?\s+may|may\s+\d{1,2}"#
        let times = #"\d{1,2}\s?(?:am|pm)|\d{1,2}:\d{2}"#
        let dates = #"\d{1,2}/\d{1,2}(?:/\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:[12]?\d|3[01])(?:st|nd|rd|th)"#
        return #"\b(?:"# + [weekdays, months, relative, mayWithNumber, times, dates].joined(separator: "|") + #")\b"#
    }()

    // Rule 7: money words matched at a word start so "payment" and "banking" count too.
    private static let moneyPattern = #"\b(?:pay|invoice|bank|transfer|gift\s+cards?\b)"#

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Validation

    /// Runs the rules in spec order and returns at most three suggestions, best first.
    /// `email.body` must already be the cleaned body.
    public func validate(_ tasks: [ExtractedTask], email: EmailMessage, context: ValidationContext) -> [Suggestion] {
        let resolver = DateResolver(timeZone: timeZone)
        let body = Self.normaliseEvidence(email.body)
        var built: [Suggestion] = []

        for task in tasks {
            // 8a: low confidence
            guard task.confidence >= 0.4 else { continue }
            // 1: evidence must be quoted from the body
            let evidence = Self.normaliseEvidence(task.evidence)
            guard !evidence.isEmpty, body.contains(evidence) else { continue }
            // 4: title shape
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = title.lowercased()
            guard (3...80).contains(title.count),
                  !["http://", "https://", "www."].contains(where: lower.contains) else { continue }
            // 2: range; a bad date only loses the date, not the task
            var due = resolver.resolve(task.due, today: context.today)
            // 3: a date the evidence never hints at is probably invented
            if due != nil, !Self.matches(Self.dateWordPattern, in: task.evidence) { due = nil }
            // 7: money language from a sender the user never approved
            var flags: [String] = []
            if !context.senderHasApprovedDecision,
               Self.matches(Self.moneyPattern, in: title) || Self.matches(Self.moneyPattern, in: task.evidence) {
                flags.append("money-new-sender")
            }
            built.append(Suggestion(
                id: makeID(), emailID: email.id, title: title, due: due?.date,
                dueHasTime: due?.hasTime ?? false, priority: task.priority, evidence: task.evidence,
                confidence: task.confidence,
                // 8b
                preselected: task.confidence >= 0.75 && flags.isEmpty,
                flags: flags, status: .pending, reminderID: nil))
        }

        // Highest confidence first (stable), so a duplicate pair keeps its better copy.
        let ordered = Self.byConfidence(built)

        // 6: dedupe against recent pending/approved suggestions and within this email
        var known = context.recentSuggestions.filter { $0.status == .pending || $0.status == .approved }
        var kept: [Suggestion] = []
        for s in ordered {
            let key = Self.normaliseTitle(s.title)
            let dup = known.contains { other in
                Self.normaliseTitle(other.title) == key && Self.sameDue(s.due, other.due, resolver)
            }
            if dup { continue }
            kept.append(s)
            known.append(s)
        }
        // 5: at most 3 per ordinary email, 8 per Trusted Newsletter email
        return Array(kept.prefix(context.maxSuggestions))
    }

    /// Keeps the `limit` highest-confidence suggestions, in their original order.
    public func capDigest(_ suggestions: [Suggestion], limit: Int = 25) -> [Suggestion] {
        guard suggestions.count > limit else { return suggestions }
        let keep = Set(suggestions.enumerated()
            .sorted { $0.element.confidence != $1.element.confidence
                ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset }
            .prefix(limit).map(\.offset))
        return suggestions.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    // MARK: Helpers

    private static func byConfidence(_ list: [Suggestion]) -> [Suggestion] {
        list.enumerated()
            .sorted { $0.element.confidence != $1.element.confidence
                ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Lowercases and collapses whitespace so line wrapping doesn't break quote matching.
    static func normaliseEvidence(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func normaliseTitle(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars
        where !CharacterSet.punctuationCharacters.contains(u) && !CharacterSet.symbols.contains(u) {
            scalars.append(u)
        }
        return normaliseEvidence(String(scalars))
    }

    private static func sameDue(_ a: Date?, _ b: Date?, _ resolver: DateResolver) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return resolver.isSameDay(x, y)
        default: return false
        }
    }
}
