import Foundation

/// Anything that can summarise one email into an `ExtractionResult` (local or cloud).
public protocol EmailExtractor: Sendable {
    /// Summarises one email and, for the `full` tier, suggests tasks. `trustedNewsletter` says the
    /// sender is a Trusted Newsletter, which may yield up to 8 tasks instead of 3.
    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult
}

public protocol LLMClient: EmailExtractor {
    /// Throws if the model server is unreachable or the model is missing.
    func healthCheck() async throws
    /// Writes the 1 to 2 sentence digest headline from summaries only (no bodies).
    func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String
}

extension EmailExtractor {
    /// Extraction for an email that isn't from a Trusted Newsletter.
    public func extract(_ email: EmailMessage, tier: MailTier, today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        try await extract(email, tier: tier, trustedNewsletter: false, today: today, timeZone: timeZone)
    }
}
