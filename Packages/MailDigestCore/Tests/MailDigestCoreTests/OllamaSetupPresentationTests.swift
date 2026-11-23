import Testing
@testable import MailDigestCore

@Suite struct OllamaSetupPresentationTests {
    @Test func readyIsGreenAndOthersNeedAttention() {
        #expect(OllamaSetupPresentation.make(for: .ready, model: "m").tone == .ready)
        for s in [OllamaSetupState.notInstalled, .notRunning, .versionTooOld(installed: "0.1.0"), .modelMissing("m")] {
            #expect(OllamaSetupPresentation.make(for: s, model: "m").tone == .attention)
        }
    }

    @Test func messagesNameVersionAndModelAndAvoidTerminal() {
        #expect(OllamaSetupPresentation.make(for: .versionTooOld(installed: "0.3.0"), model: "m").message.contains("0.3.0"))
        let missing = OllamaSetupPresentation.make(for: .modelMissing("qwen3:4b"), model: "qwen3:4b")
        #expect(missing.message.contains("qwen3:4b"))
        for s in [OllamaSetupState.notInstalled, .notRunning, .modelMissing("x"), .ready] {
            #expect(!OllamaSetupPresentation.make(for: s, model: "x").message.contains("ollama pull"))
        }
    }

    @Test func pollingStopsWhenReachableOrTimedOut() {
        let p = OllamaStartPolling()
        #expect(p.shouldContinue(after: .notRunning, elapsed: 0))
        #expect(p.shouldContinue(after: .notRunning, elapsed: 28))
        #expect(!p.shouldContinue(after: .notRunning, elapsed: 30))
        #expect(!p.shouldContinue(after: .modelMissing("m"), elapsed: 2))
        #expect(!p.shouldContinue(after: .ready, elapsed: 2))
    }
}
