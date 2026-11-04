import Foundation

/// What one email produced; `summaryText` is the short line stored on the job item.
public struct EmailOutcome: Sendable, Equatable {
    public var tier: MailTier
    public var info: InfoItem?
    public var suggestions: [Suggestion]
    public var skipped: SkippedEmail?
    /// For example "2 reminders, info", "info only" or "skipped: blocked sender".
    public var summaryText: String

    public init(tier: MailTier, info: InfoItem?, suggestions: [Suggestion], skipped: SkippedEmail?, summaryText: String) {
        self.tier = tier
        self.info = info
        self.suggestions = suggestions
        self.skipped = skipped
        self.summaryText = summaryText
    }
}

/// Runs one email through filter, cleaner, model and validator. Stateless; errors propagate to the caller.
public struct DigestPipeline: Sendable {
    public let llm: any LLMClient
    public let filter: MailFilter
    public let cleaner: EmailCleaner
    public let validator: SuggestionValidator
    public let timeZone: TimeZone

    public init(llm: any LLMClient, filter: MailFilter, cleaner: EmailCleaner = EmailCleaner(),
                validator: SuggestionValidator? = nil, timeZone: TimeZone) {
        self.llm = llm
        self.filter = filter
        self.cleaner = cleaner
        self.validator = validator ?? SuggestionValidator(timeZone: timeZone)
        self.timeZone = timeZone
    }

    /// Skip-tier mail never reaches the model. Info-only mail gets a summary but no suggestions.
    public func process(_ email: EmailMessage, today: Date, recentSuggestions: [Suggestion],
                        senderHasApprovedDecision: Bool) async throws -> EmailOutcome {
        let tier = filter.tier(email)
        if tier == .skip {
            let reason = filter.skipReason(email) ?? "skipped sender"
            return EmailOutcome(
                tier: .skip, info: nil, suggestions: [],
                skipped: SkippedEmail(id: email.id, sender: email.sender, subject: email.subject, reason: reason),
                summaryText: "skipped: \(reason)")
        }

        var cleaned = email
        cleaned.body = cleaner.clean(email.body)
        let result = try await llm.extract(cleaned, tier: tier, today: today, timeZone: timeZone)

        let info = InfoItem(
            id: email.id, emailID: email.id, category: result.category,
            importance: min(5, max(1, result.importance)), summary: result.summary,
            keyFacts: Array(result.keyFacts.prefix(4)), pinned: false)

        var suggestions: [Suggestion] = []
        if tier == .full {
            // Validate against the cleaned body: evidence must come from text the model actually saw.
            let context = ValidationContext(today: today, recentSuggestions: recentSuggestions,
                                            senderHasApprovedDecision: senderHasApprovedDecision)
            suggestions = validator.validate(result.tasks, email: cleaned, context: context)
        }

        let text = suggestions.isEmpty
            ? "info only"
            : "\(suggestions.count) \(suggestions.count == 1 ? "reminder" : "reminders"), info"
        return EmailOutcome(tier: tier, info: info, suggestions: suggestions, skipped: nil, summaryText: text)
    }

    /// The digest headline. Never throws: a model failure falls back to a plain count sentence.
    public func headline(for digest: Digest) async -> String {
        let pending = digest.suggestions.filter { $0.status == .pending }.count
        if digest.info.isEmpty && digest.suggestions.isEmpty { return Self.fallbackHeadline(emails: digest.emailCount, suggestions: pending) }
        if let text = try? await llm.headline(for: digest.info, suggestionCount: pending) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Self.fallbackHeadline(emails: digest.emailCount, suggestions: pending)
    }

    static func fallbackHeadline(emails: Int, suggestions: Int) -> String {
        "\(emails) \(emails == 1 ? "email" : "emails"), \(suggestions) \(suggestions == 1 ? "suggestion" : "suggestions")."
    }
}
