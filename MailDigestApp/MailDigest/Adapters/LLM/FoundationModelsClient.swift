import Foundation
import MailDigestCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The `LLMClient` used when the local provider is "Apple Intelligence" but the framework can't be used:
/// macOS older than 26, or an SDK without FoundationModels. Every run fails with the reason; there is never
/// a silent fall back to Ollama (Q100).
struct UnavailableLocalClient: LLMClient {
    let reason: String

    func healthCheck() async throws { throw LLMError.providerUnavailable(reason) }

    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        throw LLMError.providerUnavailable(reason)
    }

    func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String {
        throw LLMError.providerUnavailable(reason)
    }
}

/// Builds the Apple Intelligence client where it can exist, otherwise the unavailable one.
enum FoundationModelsClientFactory {
    static func make() -> any LLMClient {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelsClient() }
        #endif
        return UnavailableLocalClient(reason: HostPlatform.intel.unavailableExplanation ?? "Apple Intelligence isn\u{2019}t available.")
    }
}

#if canImport(FoundationModels)
/// Apple's on-device Foundation Models as the local digest model (Q100). Extraction uses guided generation
/// into `GeneratedExtraction`, which mirrors Core's `ExtractionResult`; prompts, the body budget and the tier
/// rules come from Core. A fresh session per email keeps the 4,096-token context from accumulating.
@available(macOS 26, *)
struct FoundationModelsClient: LLMClient {
    /// Read at call time so Apple Intelligence being switched on while the app runs is noticed.
    var availability: @Sendable () -> FoundationModelsAvailability = { HostPlatformDetector.foundationModelsAvailability() }
    var budget = FoundationModelsBudget()

    // Greedy sampling for repeatable extraction, the counterpart of Ollama's temperature 0.
    private static var greedy: GenerationOptions { GenerationOptions(sampling: .greedy) }

    func healthCheck() async throws {
        if case .unavailable = availability() {
            let platform = HostPlatform(isAppleSilicon: HostPlatformDetector.isAppleSilicon, foundationModels: availability())
            throw LLMError.providerUnavailable(platform.unavailableExplanation ?? "Apple Intelligence isn\u{2019}t available.")
        }
    }

    func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                 today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        try await healthCheck()
        do {
            return try await extract(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                     today: today, timeZone: timeZone, budget: budget)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // One retry with half the body; a second overflow fails this email like any bad answer.
                do {
                    return try await extract(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                             today: today, timeZone: timeZone, budget: budget.halved())
                } catch let retryError as LanguageModelSession.GenerationError {
                    throw Self.map(retryError)
                }
            }
            throw Self.map(error)
        }
    }

    private func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                         today: Date, timeZone: TimeZone, budget: FoundationModelsBudget) async throws -> ExtractionResult {
        // The pipeline passes an already cleaned body; only the budget is applied here.
        var short = email
        short.body = budget.truncate(email.body)
        let prompts = Prompts.extraction(short, tier: tier, trustedNewsletter: trustedNewsletter,
                                         today: today, timeZone: timeZone)
        let session = LanguageModelSession(instructions: prompts.system)
        let response = try await session.respond(to: prompts.user, generating: GeneratedExtraction.self,
                                                 options: Self.greedy)
        return response.content.result.applyingTierRules(tier: tier)
    }

    func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String {
        try await healthCheck()
        let prompts = Prompts.headline(info: info, suggestionCount: suggestionCount)
        do {
            let session = LanguageModelSession(instructions: prompts.system)
            let response = try await session.respond(to: prompts.user, options: Self.greedy)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    /// A guardrail refusal or any other generation failure fails the email like an unusable Ollama answer.
    private static func map(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .exceededContextWindowSize: return .malformedResponse("the email is too long for Apple Intelligence")
        case .guardrailViolation, .refusal: return .malformedResponse("Apple Intelligence declined this email")
        case .assetsUnavailable: return .providerUnavailable("The Apple Intelligence model isn\u{2019}t ready yet.")
        case .unsupportedLanguageOrLocale: return .malformedResponse("Apple Intelligence doesn\u{2019}t support this language")
        default: return .malformedResponse("Apple Intelligence couldn\u{2019}t answer")
        }
    }
}

/// Guided-generation mirror of Core's `ExtractionResult`. A `@Generable` mirror is simpler and sturdier than
/// building a `DynamicGenerationSchema` from `ExtractionSchema.json`: the macro derives the schema, the
/// guides carry the same limits (importance 1 to 5, up to 4 facts and steps, the Trusted Newsletter task
/// maximum), and the mapping below is plain Swift. Unknown enum text falls back to `other` and `medium`.
@available(macOS 26, *)
@Generable
struct GeneratedExtraction {
    @Guide(description: "One sentence, under 25 words.")
    var summary: String
    @Guide(description: "The best-fitting category.", .anyOf(EmailCategory.allCases.map(\.rawValue)))
    var category: String
    @Guide(description: "1 (ignorable) to 5 (urgent).", .range(1...5))
    var importance: Int
    @Guide(description: "Short facts worth remembering.", .maximumCount(4))
    var keyFacts: [String]
    @Guide(description: "Actions the reader must take. Empty when there are none.",
           .maximumCount(MailFilter.trustedNewsletterSuggestionLimit))
    var tasks: [GeneratedTask]

    var result: ExtractionResult {
        ExtractionResult(summary: summary, category: EmailCategory(rawValue: category) ?? .other,
                         importance: min(5, max(1, importance)), keyFacts: keyFacts,
                         tasks: tasks.map(\.task))
    }
}

@available(macOS 26, *)
@Generable
struct GeneratedTask {
    var title: String
    @Guide(description: "The due date or date-time as in the instructions, or an empty string when none.")
    var due: String
    @Guide(description: "True when the due value includes a time of day.")
    var dueHasTime: Bool
    @Guide(description: "Priority.", .anyOf(["high", "medium", "low"]))
    var priority: String
    @Guide(description: "A short quote from the email that supports this task.")
    var evidence: String
    @Guide(description: "Confidence from 0 to 1.", .range(0.0...1.0))
    var confidence: Double
    @Guide(description: "Supporting details of the same goal. Empty when none.", .maximumCount(4))
    var steps: [String]

    var task: ExtractedTask {
        let trimmedDue = due.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractedTask(title: title, due: trimmedDue.isEmpty ? nil : trimmedDue, dueHasTime: dueHasTime,
                             priority: Priority(rawValue: priority) ?? .medium, evidence: evidence,
                             confidence: confidence, steps: steps)
    }
}
#endif
