import Foundation

/// User-facing copy for a Test Connection result. Pure so it can be tested; the view only renders it.
public struct GeminiConnectionMessage: Sendable, Equatable {
    public var title: String?
    public var detail: String
    public var footnote: String?
    public var isSuccess: Bool

    public init(result: GeminiConnectionResult, modelID: String) {
        let name = RoutingPresentation.modelDisplayName(modelID)
        switch result {
        case .connected:
            self.init(title: "Connection successful", detail: "\(name) is available with this API key.",
                      footnote: "No email content was sent during this test.", isSuccess: true)
        case .invalidKey:
            self.init(detail: "Gemini rejected this API key. Check the key and try again.")
        case .modelUnavailable, .generateContentUnsupported:
            self.init(detail: "\(name) isn't available with this API key.")
        case .rateLimited:
            self.init(detail: "Gemini is receiving too many requests from this key. Try again in a moment.")
        case .network:
            self.init(detail: "Couldn't reach Gemini. Check your internet connection and try again.")
        case .server, .unexpectedResponse:
            self.init(detail: "Gemini returned an error. Try again later.")
        }
    }

    private init(title: String? = nil, detail: String, footnote: String? = nil, isSuccess: Bool = false) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.isSuccess = isSuccess
    }

    /// Caption under the Cloud Digest toggle (shown while it is on). Says whether cloud is actually active for
    /// the selected provider, independent of any test.
    public static func cloudStatusText(settings: DigestSettings, hasGeminiKey: Bool,
                                       claudeCode: ClaudeCodeStatus) -> String {
        let provider = settings.cloudProvider
        switch CloudPrivacyPolicy.offReason(settings: settings, hasGeminiKey: hasGeminiKey, claudeCode: claudeCode) {
        case .cloudDisabled?:
            return "Cloud processing is currently disabled. Emails continue to be processed locally."
        case .acknowledgementRequired?:
            return "Cloud processing is inactive until you accept the privacy notice. Emails are processed locally."
        case .providerUnavailable?:
            return "Cloud processing is inactive until Claude Code is installed, up to date and signed in. Emails are processed locally."
        case .noCredential?:
            return "Cloud processing is inactive until an API key is saved. Emails are processed locally."
        default:
            return "Only emails that pass Mail Digest's privacy checks may be sent to \(provider.displayName). Other emails are processed locally on this Mac."
        }
    }
}
