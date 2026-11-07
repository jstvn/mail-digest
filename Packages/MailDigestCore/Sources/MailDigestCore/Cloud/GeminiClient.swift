import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloud extraction through the Gemini API. Extraction only (never headline); no retry.
/// The key is private and never appears in descriptions.
public struct GeminiClient: EmailExtractor, CustomStringConvertible, CustomDebugStringConvertible {
    public let model: String
    public let timeout: TimeInterval
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, model: String = GeminiDefaults.model, session: URLSession = .shared,
                timeout: TimeInterval = GeminiDefaults.requestTimeout) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    public var description: String { "GeminiClient(model: \(model))" }
    public var debugDescription: String { description }

    /// Builds the `generateContent` request. Uses the same prompts as the Ollama client.
    func makeRequest(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                     today: Date, timeZone: TimeZone) throws -> URLRequest {
        func text(_ s: String) -> JSONValue { .object(["parts": .array([.object(["text": .string(s)])])]) }
        let system = Prompts.extractionSystem(today: today, timeZone: timeZone, tier: tier,
                                              trustedNewsletter: trustedNewsletter)
        let user = Prompts.extractionUser(email, timeZone: timeZone)
        let body: JSONValue = .object([
            "systemInstruction": text(system),
            "contents": .array([.object([
                "role": .string("user"),
                "parts": .array([.object(["text": .string(user)])]),
            ])]),
            "generationConfig": .object([
                "responseMimeType": .string("application/json"),
                "responseJsonSchema": GeminiSchemaAdapter.adapt(),
                "temperature": .number(0),
                "maxOutputTokens": .number(Double(GeminiDefaults.maxOutputTokens)),
            ]),
        ])
        return GeminiTransport.request(url: GeminiTransport.modelURL(model, suffix: ":generateContent"),
                                       method: "POST", apiKey: apiKey, timeout: timeout,
                                       body: try body.stableData())
    }

    public func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                        today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        let request = try makeRequest(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                      today: today, timeZone: timeZone)
        let status: Int
        let data: Data
        do {
            (status, data) = try await GeminiTransport.send(request, session: session)
        } catch GeminiTransport.Failure.timedOut {
            throw GeminiError.timedOut
        } catch is GeminiTransport.Failure {
            throw GeminiError.network
        }
        guard (200..<300).contains(status) else { throw Self.error(status: status, body: data) }
        var result = try Self.decode(data)
        if tier == .infoOnly { result.tasks = [] }
        return result
    }

    static func error(status: Int, body: Data) -> GeminiError {
        switch status {
        case 400: return GeminiTransport.isInvalidKey(body) ? .invalidCredential : .malformedResponse
        case 401, 403: return .invalidCredential
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .malformedResponse
        }
    }

    private struct Envelope: Decodable {
        struct Part: Decodable { var text: String? }
        struct Content: Decodable { var parts: [Part]? }
        struct Candidate: Decodable { var content: Content?; var finishReason: String? }
        struct Feedback: Decodable { var blockReason: String? }
        var candidates: [Candidate]?
        var promptFeedback: Feedback?
    }

    static func decode(_ data: Data) throws -> ExtractionResult {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw GeminiError.malformedResponse
        }
        if env.promptFeedback?.blockReason != nil { throw GeminiError.blocked }
        guard let candidate = env.candidates?.first else { throw GeminiError.malformedResponse }
        switch candidate.finishReason {
        case "STOP": break
        case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION": throw GeminiError.blocked
        default: throw GeminiError.malformedResponse
        }
        let text = (candidate.content?.parts ?? []).compactMap(\.text).joined()
        guard let result = ExtractionResult.decode(jsonText: text) else { throw GeminiError.malformedResponse }
        return result
    }
}
