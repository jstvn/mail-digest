import Foundation
import Testing
@testable import MailDigestCore

@Suite struct HostPlatformTests {
    private func platform(_ silicon: Bool, _ fm: FoundationModelsAvailability) -> HostPlatform {
        HostPlatform(isAppleSilicon: silicon, foundationModels: fm)
    }

    @Test func foundationModelsChoiceVisibility() {
        #expect(platform(true, .available).showsFoundationModelsChoice)
        #expect(platform(true, .available).canUseFoundationModels)
        #expect(platform(true, .unavailable(.appleIntelligenceNotEnabled)).showsFoundationModelsChoice)
        #expect(platform(true, .unavailable(.modelNotReady)).showsFoundationModelsChoice)
        #expect(!platform(true, .unavailable(.appleIntelligenceNotEnabled)).canUseFoundationModels)
        #expect(!platform(true, .unavailable(.deviceNotEligible)).showsFoundationModelsChoice)
        #expect(!platform(true, .unavailable(.unsupportedOS)).showsFoundationModelsChoice)
        #expect(!platform(false, .available).showsFoundationModelsChoice)
        #expect(!HostPlatform.intel.showsFoundationModelsChoice)
    }

    @Test func explanations() {
        #expect(HostPlatform.appleSiliconReady.unavailableExplanation == nil)
        #expect(platform(true, .unavailable(.appleIntelligenceNotEnabled)).unavailableExplanation
            == "Turn on Apple Intelligence in System Settings to use this option.")
        #expect(HostPlatform.intel.unavailableExplanation != nil)
    }

    @Test func localProviderCodable() throws {
        var s = DigestSettings()
        #expect(s.localProvider == .ollama)
        s.localProvider = .appleFoundationModels
        let back = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(back.localProvider == .appleFoundationModels)
        let missing = try JSONDecoder().decode(DigestSettings.self, from: Data("{}".utf8))
        #expect(missing.localProvider == .ollama)
        let unknown = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"localProvider":"future"}"#.utf8))
        #expect(unknown.localProvider == .ollama)
    }

    @Test func platformAwareModels() {
        #expect(DigestSettings.suggestedDigestModels(for: .intel) == [DigestSettings.defaultModel])
        #expect(DigestSettings.suggestedDigestModels(for: .appleSiliconReady)
            == [DigestSettings.defaultModel, "qwen3.5:4b-mlx"])
        #expect(CloudPrivacyPolicy.triageModels(for: .intel) == CloudPrivacyPolicy.triageModels)
        let silicon = CloudPrivacyPolicy.triageModels(for: .appleSiliconReady).map(\.tag)
        #expect(silicon == ["kev:4b-q4_K_M", "tev1:0.8b-q8_0", "kev:4b-mlx-bf16"])
        #expect(CloudPrivacyPolicy.triageModelNote(for: "kev:4b-mlx-bf16")?.contains("8.4 GB") == true)
    }

    @Test func mlxDisplayNames() {
        #expect(RoutingPresentation.modelDisplayName("qwen3.5:4b-mlx") == "Qwen3.5 4B MLX")
        #expect(RoutingPresentation.modelDisplayName("qwen3.5:4b") == "Qwen3.5 4B")
        #expect(RoutingPresentation.modelDisplayName("kev:4b-mlx-bf16") == "Kev 4B MLX")
        #expect(RoutingPresentation.modelDisplayName("qwen3.5:weird!") == "qwen3.5:weird!")
    }

    @Test func budgetTruncatesAtBoundaryWithMarker() {
        let budget = FoundationModelsBudget(bodyCharacters: 1_000)
        #expect(budget.truncate("short") == "short")
        let body = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let cut = budget.truncate(body)
        #expect(cut.hasSuffix("\n[truncated]"))
        #expect(cut.count <= 1_000 + "\n[truncated]".count)
        // Cut at a word boundary: the last kept word is whole.
        let kept = String(cut.dropLast("\n[truncated]".count))
        #expect(body.hasPrefix(kept) && body.dropFirst(kept.count).first == " ")
        #expect(FoundationModelsBudget().bodyCharacters == FoundationModelsBudget.defaultBodyCharacters)
        #expect(budget.halved().bodyCharacters == 500)
        #expect(budget.halved().halved().bodyCharacters == FoundationModelsBudget.minimumBodyCharacters)
    }

    @Test func promptPairMatchesBuilders() {
        let tz = TimeZone(identifier: "Australia/Brisbane")!
        let email = EmailMessage(id: "1", account: "a", mailbox: "Inbox", sender: "x@y.com", subject: "Hi",
                                 receivedAt: Date(timeIntervalSince1970: 0), body: "Body", headers: [:])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let p = Prompts.extraction(email, tier: .infoOnly, today: now, timeZone: tz)
        #expect(p.system == Prompts.extractionSystem(today: now, timeZone: tz, tier: .infoOnly))
        #expect(p.user == Prompts.extractionUser(email, timeZone: tz))
        #expect(Prompts.headline(info: [], suggestionCount: 2).system == Prompts.headlineSystem)
    }

    @Test func providerUnavailableError() {
        #expect(LLMError.providerUnavailable("Off.").userMessage == "Off.")
    }

    @Test func unknownFailureKindReadsAsNil() throws {
        let job = Job(id: UUID(), kind: .daily, mailboxes: [], scopeFrom: Date(timeIntervalSince1970: 1),
                      scopeTo: Date(timeIntervalSince1970: 2), state: .failed, createdAt: Date(timeIntervalSince1970: 1),
                      totals: JobTotals(queued: 1, done: 0, failed: 0, skipped: 0), autoPaused: false,
                      failureKind: .localModelUnavailable)
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(Job.self, from: data).failureKind == .localModelUnavailable)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["failureKind"] = "somethingNew"
        let future = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(Job.self, from: future).failureKind == nil)
    }

    @Test func ollamaSetupStateOrdering() {
        let model = "qwen3:4b"
        func state(app: Bool = true, up: Bool = true, version: String? = "0.41.0", tags: [String]? = ["qwen3:4b"],
                   required: String = model) -> OllamaSetupState {
            .evaluate(isAppInstalled: app, reachable: up, version: version, installedTags: tags, requiredModel: required)
        }
        #expect(state(app: false, up: false) == .notInstalled)
        #expect(state(up: false) == .notRunning)
        #expect(state(app: false, up: true) == .ready)
        #expect(state(version: "0.39.9") == .versionTooOld(installed: "0.39.9"))
        #expect(state(version: "0.40.4") == .ready)
        #expect(state(version: nil) == .ready)
        #expect(state(version: "0.30.0", tags: []) == .versionTooOld(installed: "0.30.0"))
        #expect(state(tags: ["other:1b"]) == .modelMissing(model))
        #expect(state(tags: nil) == .modelMissing(model))
        #expect(state(tags: ["qwen3:latest"], required: "qwen3") == .ready)
    }

    @Test func localModelRecordingAndCopy() {
        var settings = DigestSettings()
        #expect(settings.resolvedLocalModel == settings.resolvedModel)
        settings.localProvider = .appleFoundationModels
        #expect(settings.resolvedLocalModel == "apple-foundation-model")
        #expect(RoutingPresentation.modelDisplayName(settings.resolvedLocalModel) == "Apple Foundation Model")
        #expect(LLMError.modelMissing("qwen3:4b").userMessage
                == "The model qwen3:4b isn\u{2019}t installed. Download it in Settings \u{203A} Models.")
        #expect(!LLMError.modelMissing("qwen3:4b").userMessage.contains("ollama pull"))
        #expect(LLMError.unreachable("x").userMessage == "Ollama isn\u{2019}t running. Start Ollama, then try again.")
    }
}
