import Foundation

/// What one email produced; `summaryText` is the short line stored on the job item.
public struct EmailOutcome: Sendable, Equatable {
    public var tier: MailTier
    public var info: InfoItem?
    public var suggestions: [Suggestion]
    public var skipped: SkippedEmail?
    /// For example "2 reminders, info", "info only" or "skipped: blocked sender".
    public var summaryText: String
    /// Privacy assessment and executor; nil when no model ran (skipped mail).
    public var routing: RoutingProvenance?

    public init(tier: MailTier, info: InfoItem?, suggestions: [Suggestion], skipped: SkippedEmail?, summaryText: String,
                routing: RoutingProvenance? = nil) {
        self.routing = routing
        self.tier = tier
        self.info = info
        self.suggestions = suggestions
        self.skipped = skipped
        self.summaryText = summaryText
    }
}

/// Wall-clock fallback for callers that don't inject a clock (the runner always does).
struct SystemWallClock: Clock {
    func now() -> Date { Date() }
}

/// Runs one email through filter, cleaner, model and validator. Stateless; errors propagate to the caller.
public struct DigestPipeline: Sendable {
    public let llm: any LLMClient
    public let filter: MailFilter
    public let cleaner: EmailCleaner
    public let validator: SuggestionValidator
    public let timeZone: TimeZone
    public let router: DigestRouter
    public let localModel: String

    public init(llm: any LLMClient, filter: MailFilter, cleaner: EmailCleaner = EmailCleaner(),
                validator: SuggestionValidator? = nil, timeZone: TimeZone,
                clock: (any Clock)? = nil, localModel: String = DigestSettings.defaultModel) {
        self.router = DigestRouter(clock: clock ?? SystemWallClock())
        self.localModel = localModel
        self.llm = llm
        self.filter = filter
        self.cleaner = cleaner
        self.validator = validator ?? SuggestionValidator(timeZone: timeZone)
        self.timeZone = timeZone
    }

    /// Skip-tier mail never reaches the model. Info-only mail gets a summary but no suggestions.
    public func process(_ email: EmailMessage, today: Date, recentSuggestions: [Suggestion],
                        senderHasApprovedDecision: Bool,
                        routingConfig: CloudRoutingConfig = .localOnly(reason: .cloudDisabled),
                        storedAssessment: PrivacyAssessment? = nil,
                        onAssessment: (@Sendable (PrivacyAssessment) async -> Void)? = nil,
                        onFailedAttempt: (@Sendable (RoutingProvenance) -> Void)? = nil) async throws -> EmailOutcome {
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
        // Nothing left to read (empty, or only tracking/boilerplate removed by the cleaner): never
        // send an empty prompt to the model.
        if cleaned.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reason = "no readable body"
            return EmailOutcome(
                tier: .skip, info: nil, suggestions: [],
                skipped: SkippedEmail(id: email.id, sender: email.sender, subject: email.subject, reason: reason),
                summaryText: "skipped: \(reason)")
        }
        let trusted = tier == .full && filter.isTrustedNewsletter(email)
        // Assess on the full uncleaned email, persist the decision, then generate.
        let assessment = try await router.assess(email, stored: storedAssessment, config: routingConfig)
        if assessment != storedAssessment { await onAssessment?(assessment) }
        let result: ExtractionResult
        let execution: ExecutionRecord
        do {
            (result, execution) = try await router.execute(
                cleaned, tier: tier, trustedNewsletter: trusted, today: today, timeZone: timeZone,
                assessment: assessment, config: routingConfig, local: llm, localModel: localModel)
        } catch let failure as RoutedExecutionFailure {
            // Report the failed attempt, then rethrow the original error so callers classify it as before.
            onFailedAttempt?(RoutingProvenance(assessment: assessment, execution: failure.execution))
            throw failure.underlying
        }

        let info = InfoItem(
            id: email.id, emailID: email.id, category: result.category,
            importance: min(5, max(1, result.importance)), summary: result.summary,
            keyFacts: Array(result.keyFacts.prefix(4)), pinned: false)

        var suggestions: [Suggestion] = []
        if tier == .full {
            // Validate against the cleaned body: evidence must come from text the model actually saw.
            let context = ValidationContext(today: today, recentSuggestions: recentSuggestions,
                                            senderHasApprovedDecision: senderHasApprovedDecision,
                                            maxSuggestions: filter.suggestionLimit(for: email))
            suggestions = validator.validate(result.tasks, email: cleaned, context: context)
                .map { var s = $0; s.category = info.category; return s }
        }

        let text = suggestions.isEmpty
            ? "info only"
            : "\(suggestions.count) \(suggestions.count == 1 ? "reminder" : "reminders"), info"
        return EmailOutcome(tier: tier, info: info, suggestions: suggestions, skipped: nil, summaryText: text,
                            routing: RoutingProvenance(assessment: assessment, execution: execution))
    }

    /// The digest headline. Never throws: a model failure falls back to a plain count sentence.
    public func headline(for digest: Digest) async -> String {
        let pending = digest.suggestions.filter { $0.status == .pending }.count
        if digest.info.isEmpty && digest.suggestions.isEmpty { return Self.fallbackHeadline(emails: digest.emailCount, suggestions: pending) }
        if let text = try? await llm.headline(for: digest.info, suggestionCount: pending) {
            if let valid = HeadlineValidator.validated(text) { return valid }
        }
        return Self.fallbackHeadline(emails: digest.emailCount, suggestions: pending)
    }

    static func fallbackHeadline(emails: Int, suggestions: Int) -> String {
        "\(emails) \(emails == 1 ? "email" : "emails"), \(suggestions) \(suggestions == 1 ? "suggestion" : "suggestions")."
    }

    /// Whether `text` is exactly what `fallbackHeadline` would write for some counts. The counts are read back
    /// and the sentence is rebuilt, so the two cannot drift apart.
    static func isFallbackHeadline(_ text: String) -> Bool {
        let pattern = #"^(\d+) emails?, (\d+) suggestions?\.$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return false }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        return fallbackHeadline(emails: numbers[0], suggestions: numbers[1]) == text
    }
}
