import Foundation

public protocol LLMClient: Sendable {
    /// Throws if the model server is unreachable or the model is missing.
    func healthCheck() async throws
    /// Summarises one email and, for the `full` tier, suggests tasks.
    func extract(_ email: EmailMessage, tier: MailTier, today: Date, timeZone: TimeZone) async throws -> ExtractionResult
    /// Writes the 1 to 2 sentence digest headline from summaries only (no bodies).
    func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String
}
