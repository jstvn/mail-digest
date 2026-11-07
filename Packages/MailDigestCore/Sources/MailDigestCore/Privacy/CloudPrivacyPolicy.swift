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
        TriageModel(tag: "kev:0.8b-q8_0", displayName: "Kev 0.8B (Q8, default)"),
        TriageModel(tag: "tev1:0.8b", displayName: "Tev1 0.8B"),
        TriageModel(tag: "kev:4b-q4_K_M", displayName: "Kev 4B (Q4, larger)"),
    ]

    /// Why cloud is effectively off, or nil when it is on. Checked in the order the user would fix them.
    public static func offReason(settings: DigestSettings, hasKey: Bool) -> LocalReason? {
        if !settings.cloudDigestEnabled { return .cloudDisabled }
        guard let revision = settings.cloudPrivacyAcknowledgedRevision, revision >= currentRevision else {
            return .acknowledgementRequired
        }
        if !hasKey { return .noCredential }
        return nil
    }
}
