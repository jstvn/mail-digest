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
        var s = DigestSettings()
        #expect(GeminiConnectionMessage.cloudStatusText(settings: s, hasKey: true).hasPrefix("Cloud processing is currently disabled"))
        s.cloudDigestEnabled = true
        #expect(GeminiConnectionMessage.cloudStatusText(settings: s, hasKey: true).contains("privacy notice"))
        s.cloudPrivacyAcknowledgedRevision = CloudPrivacyPolicy.currentRevision
        #expect(GeminiConnectionMessage.cloudStatusText(settings: s, hasKey: false).contains("until an API key is saved"))
        #expect(GeminiConnectionMessage.cloudStatusText(settings: s, hasKey: true).hasPrefix("Only emails that pass"))
    }
}
