import Foundation
import Testing
@testable import MailDigestCore

@Suite struct GeminiConnectionMessageTests {
    @Test func successUsesDisplayNameOfTestedModel() {
        let m = GeminiConnectionMessage(result: .connected, modelID: "gemini-3.5-flash-lite")
        #expect(m.isSuccess)
        #expect(m.title == "Connection successful")
        #expect(m.detail == "Gemini 3.5 Flash-Lite is available with this API key.")
        #expect(m.footnote == "No email content was sent during this test.")
        let custom = GeminiConnectionMessage(result: .connected, modelID: "my-custom-model")
        #expect(custom.detail == "my-custom-model is available with this API key.")
    }

    @Test func errorsAreFriendlyAndTechnicalFree() {
        let results: [GeminiConnectionResult] = [.invalidKey, .modelUnavailable, .generateContentUnsupported,
                                                 .rateLimited, .network, .server(503), .unexpectedResponse]
        for r in results {
            let m = GeminiConnectionMessage(result: r, modelID: "gemini-3.5-flash-lite")
            #expect(!m.isSuccess && m.title == nil && m.footnote == nil)
            for banned in ["models.get", "generateContent", "503", "HTTP"] { #expect(!m.detail.contains(banned)) }
        }
        #expect(GeminiConnectionMessage(result: .modelUnavailable, modelID: "gemini-3.5-flash-lite").detail
                == "Gemini 3.5 Flash-Lite isn't available with this API key.")
        #expect(GeminiConnectionMessage(result: .server(500), modelID: "x").detail == "Gemini returned an error. Try again later.")
    }

    @Test func cloudStatusFollowsEffectiveState() {
        func text(_ s: DigestSettings, key: Bool = true, cc: ClaudeCodeStatus = .ready) -> String {
            GeminiConnectionMessage.cloudStatusText(settings: s, hasGeminiKey: key, claudeCode: cc)
        }
        var s = DigestSettings()
        #expect(text(s).hasPrefix("Cloud processing is currently disabled"))
        s.cloudDigestEnabled = true
        #expect(text(s) == "Choose a cloud provider. Until then every email stays on this Mac.")
        s.cloudProvider = .gemini
        #expect(text(s).contains("privacy notice"))
        s.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision
        #expect(text(s, key: false).contains("until an API key is saved"))
        #expect(text(s).hasPrefix("Only emails that pass") && text(s).contains("sent to Gemini"))
        // Claude Code selected: the Gemini key is irrelevant, its own acknowledgement and status decide.
        s.cloudProvider = .claudeCode
        #expect(text(s, key: false).contains("privacy notice"))
        s.claudeCodePrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentClaudeCodeRevision
        #expect(text(s, key: false).contains("sent to Claude Code"))
        #expect(text(s, cc: .notSignedIn).contains("Claude Code is installed"))
    }
}
