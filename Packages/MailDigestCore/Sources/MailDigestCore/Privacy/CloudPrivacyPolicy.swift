import Foundation

/// Fixed facts and the on/off rule for Cloud Digest (Q63).
public enum CloudPrivacyPolicy {
    /// Bump when the disclosure changes materially; users are then asked again.
    public static let currentRevision = 1
    public static let termsURL = URL(string: "https://ai.google.dev/gemini-api/terms")!

    public struct TriageModel: Sendable, Equatable, Identifiable {
        public let tag: String
        public let displayName: String
        public var id: String { tag }
    }

    /// System One models the user can pick for triage.
    public static let triageModels: [TriageModel] = [
        TriageModel(tag: "kev:4b-q4_K_M", displayName: "Kev 4B (Q4, default)"),
        TriageModel(tag: "tev1:0.8b-q8_0", displayName: "Tev1 0.8B (Q8, low memory)"),
    ]

    /// MLX build of Kev 4B (bf16), offered on Apple silicon only (Q100).
    public static let mlxTriageModel = TriageModel(tag: "kev:4b-mlx-bf16", displayName: "Kev 4B (MLX, Apple silicon)")

    /// The triage models for this Mac; Intel gets the same list as `triageModels`.
    public static func triageModels(for platform: HostPlatform) -> [TriageModel] {
        platform.isAppleSilicon ? triageModels + [mlxTriageModel] : triageModels
    }

    /// A short caption for the model picker; nil for an unknown tag.
    public static func triageModelNote(for tag: String) -> String? {
        switch tag {
        case "kev:4b-q4_K_M":
            return "Uses about 8.5 GB of memory while loaded, on top of the digest model. On a Mac with 16 GB, choose Tev1 0.8B if the system starts swapping."
        case "tev1:0.8b-q8_0":
            return "Uses much less memory than Kev 4B, but keeps more public emails on this Mac."
        case "kev:4b-mlx-bf16":
            return "Full-precision (bf16) build, an 8.4 GB download that needs more memory than Kev 4B Q4. A Mac with 24 GB or more is suggested."
        default: return nil
        }
    }

    /// Bump when the Claude Code disclosure changes materially (Q93).
    public static let currentClaudeCodeRevision = 1

    /// Why cloud is effectively off for Gemini, or nil when it is on. Equivalent to the provider-aware
    /// overload with Gemini selected.
    public static func offReason(settings: DigestSettings, hasKey: Bool) -> LocalReason? {
        if !settings.cloudDigestEnabled { return .cloudDisabled }
        return providerReason(provider: .gemini, settings: settings, hasGeminiKey: hasKey, claudeCode: .notFound)
    }

    /// Why cloud is effectively off for the selected provider, or nil when it is on. Checked in the order the
    /// user would fix them: master switch, acknowledgement, then the provider's own readiness.
    /// A missing Gemini key matters only while Gemini is selected.
    public static func offReason(settings: DigestSettings, hasGeminiKey: Bool,
                                 claudeCode: ClaudeCodeStatus) -> LocalReason? {
        if !settings.cloudDigestEnabled { return .cloudDisabled }
        guard let provider = settings.cloudProvider else { return .noProvider }
        return providerReason(provider: provider, settings: settings,
                              hasGeminiKey: hasGeminiKey, claudeCode: claudeCode)
    }

    private static func providerReason(provider: CloudProvider, settings: DigestSettings, hasGeminiKey: Bool,
                                       claudeCode: ClaudeCodeStatus) -> LocalReason? {
        switch provider {
        case .gemini:
            guard let r = settings.cloudPrivacyAcknowledgedRevision, r >= currentRevision else {
                return .acknowledgementRequired
            }
            return hasGeminiKey ? nil : .noCredential
        case .claudeCode:
            guard let r = settings.claudeCodePrivacyAcknowledgedRevision, r >= currentClaudeCodeRevision else {
                return .acknowledgementRequired
            }
            return claudeCode == .ready ? nil : .providerUnavailable
        }
    }
}
