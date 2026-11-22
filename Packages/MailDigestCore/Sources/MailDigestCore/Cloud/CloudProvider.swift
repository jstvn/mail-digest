import Foundation

/// The cloud service Cloud Digest sends eligible mail to (Q93).
public enum CloudProvider: String, Codable, Sendable, Equatable, CaseIterable {
    // Declaration order drives the Settings picker order.
    case claudeCode, gemini

    /// Name used in labels such as "Claude Code failed → Local Qwen3 4B".
    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claudeCode: return "Claude Code"
        }
    }
}

/// Whether Claude Code can be used right now. The app fills this from detection once per job;
/// Core never looks for the binary.
public enum ClaudeCodeStatus: Sendable, Equatable {
    case ready
    case notFound
    case notSignedIn
    case tooOld
}

/// An extractor that also reports which model actually answered, so labels show the real model.
public protocol ReportedModelExtractor: EmailExtractor {
    /// Same as `extract`, plus the model id the provider reported (nil when it did not say).
    func extractReportingModel(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                               today: Date, timeZone: TimeZone) async throws -> (ExtractionResult, String?)
}
