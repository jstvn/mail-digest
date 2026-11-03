import Foundation

/// Errors thrown by `StubLLMClient`.
public enum StubLLMError: Error, Sendable, Equatable {
    case malformed
    case unhealthy
}

/// One recorded `extract` call.
public struct StubExtractCall: Sendable, Equatable {
    public var id: String
    public var tier: MailTier
}

/// Scriptable `LLMClient` for pipeline tests.
public actor StubLLMClient: LLMClient {
    public private(set) var results: [String: ExtractionResult]
    public private(set) var defaultResult: ExtractionResult
    public private(set) var failures: [String: Int]
    public private(set) var headlineText: String
    public private(set) var healthy: Bool
    public private(set) var onExtract: (@Sendable (EmailMessage) async throws -> Void)?
    public private(set) var extractCalls: [StubExtractCall] = []
    public private(set) var headlineCalls = 0

    public init(results: [String: ExtractionResult] = [:],
                defaultResult: ExtractionResult = StubLLMClient.infoOnlyResult,
                failures: [String: Int] = [:],
                headlineText: String = "Stub headline.",
                healthy: Bool = true,
                onExtract: (@Sendable (EmailMessage) async throws -> Void)? = nil) {
        self.results = results
        self.defaultResult = defaultResult
        self.failures = failures
        self.headlineText = headlineText
        self.healthy = healthy
        self.onExtract = onExtract
    }

    /// Info-only answer with no tasks.
    public static let infoOnlyResult = ExtractionResult(
        summary: "An email.", category: .other, importance: 1, keyFacts: [], tasks: [])

    public func setResult(_ result: ExtractionResult, for id: String) { results[id] = result }
    public func setResults(_ new: [String: ExtractionResult]) { results = new }
    public func setDefaultResult(_ result: ExtractionResult) { defaultResult = result }
    public func setFailures(_ new: [String: Int]) { failures = new }
    public func setHeadlineText(_ text: String) { headlineText = text }
    public func setHealthy(_ value: Bool) { healthy = value }
    public func setOnExtract(_ hook: (@Sendable (EmailMessage) async throws -> Void)?) { onExtract = hook }

    public func healthCheck() async throws {
        if !healthy { throw StubLLMError.unhealthy }
    }

    public func extract(_ email: EmailMessage, tier: MailTier, today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        extractCalls.append(StubExtractCall(id: email.id, tier: tier))
        if let hook = onExtract { try await hook(email) }
        try Task.checkCancellation()
        if let remaining = failures[email.id], remaining > 0 {
            if remaining != Int.max { failures[email.id] = remaining - 1 }
            throw StubLLMError.malformed
        }
        var result = results[email.id] ?? defaultResult
        // Mirrors the prompt rule: the info-only tier never returns tasks.
        if tier == .infoOnly { result.tasks = [] }
        return result
    }

    public func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String {
        headlineCalls += 1
        return headlineText
    }
}
