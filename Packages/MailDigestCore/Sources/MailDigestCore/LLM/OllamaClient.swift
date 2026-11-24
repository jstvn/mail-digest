import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failures from the model server.
public enum LLMError: Error, Equatable, Sendable {
    case unreachable(String)
    /// The server accepted the request but did not answer within the request's timeout.
    case timedOut
    case modelMissing(String)
    case http(status: Int)
    case malformedResponse(String)
    /// The selected local provider can't run (for example Apple Intelligence is off); the text is the reason.
    case providerUnavailable(String)

    /// Short text for the UI, including the fix.
    public var userMessage: String {
        switch self {
        case .unreachable: return "Ollama isn\u{2019}t running. Start Ollama, then try again."
        case .timedOut: return "Ollama did not answer in time."
        case .modelMissing(let m): return "The model \(m) isn\u{2019}t installed. Download it in Settings \u{203A} Models."
        case .http(let s): return "Ollama returned HTTP \(s)."
        case .providerUnavailable(let reason): return reason
        case .malformedResponse(let r): return "The model gave an unusable answer (\(r))."
        }
    }
}

/// `LLMClient` backed by a local Ollama server.
///
/// The pipeline calls this one request at a time (CPU-bound machine), so the client
/// keeps no state and takes no lock.
public struct OllamaClient: LLMClient {
    public let baseURL: URL
    public let model: String
    /// Per-email extraction. Long because prompt evaluation of a long email on an Intel CPU can
    /// take many minutes (Q35: one 7,725-token prompt took 875 s).
    public let extractTimeout: TimeInterval
    /// Digest headline, built from short summaries only.
    public let headlineTimeout: TimeInterval
    /// `GET /api/tags`; kept short so an unreachable server is reported quickly.
    public let healthCheckTimeout: TimeInterval
    private let session: URLSession

    /// Answer-length caps (Q100): a runaway generation can't hold the serial runner for minutes.
    public static let extractionMaxTokens = 1024
    public static let headlineMaxTokens = 256

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen3:4b",
                session: URLSession = .shared, extractTimeout: TimeInterval = 1000,
                headlineTimeout: TimeInterval = 180, healthCheckTimeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.extractTimeout = extractTimeout
        self.headlineTimeout = headlineTimeout
        self.healthCheckTimeout = healthCheckTimeout
    }

    // MARK: Request builders

    /// Builds the `/api/chat` request for an extraction call.
    public func makeExtractionRequest(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool = false,
                                      today: Date, timeZone: TimeZone) throws -> URLRequest {
        let p = Prompts.extraction(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                   today: today, timeZone: timeZone)
        return try chatRequest(system: p.system, user: p.user,
                        format: ExtractionSchema.json, timeout: extractTimeout,
                               maxTokens: Self.extractionMaxTokens)
    }

    /// Builds the `/api/chat` request for the headline call (schema-constrained, Q102).
    public func makeHeadlineRequest(info: [InfoItem], suggestionCount: Int) throws -> URLRequest {
        let p = Prompts.headline(info: info, suggestionCount: suggestionCount)
        return try chatRequest(system: p.system, user: p.user,
                        format: HeadlineSchema.json, timeout: headlineTimeout, maxTokens: Self.headlineMaxTokens)
    }

    private func chatRequest(system: String, user: String, format: JSONValue?, timeout: TimeInterval,
                              maxTokens: Int) throws -> URLRequest {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(user)]),
            ]),
            "think": .bool(false),
            "stream": .bool(false),
            "keep_alive": .string("10m"),
            "options": .object(["temperature": .number(0), "num_ctx": .number(8192),
                                "num_predict": .number(Double(maxTokens))]),
        ]
        if let format { body["format"] = format }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONValue.object(body).stableData()
        return request
    }

    // MARK: LLMClient

    public func healthCheck() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = healthCheckTimeout
        let data = try await send(request)
        struct Tags: Decodable { struct M: Decodable { var name: String }; var models: [M] }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            throw LLMError.malformedResponse("tags list not readable")
        }
        guard Self.isInstalled(model, in: tags.models.map(\.name)) else {
            throw LLMError.modelMissing(model)
        }
    }

    /// Whether `model` is among the installed tags. Ollama lists untagged names as "name:latest".
    public static func isInstalled(_ model: String, in tags: [String]) -> Bool {
        let wanted: Set<String> = model.contains(":") ? [model] : [model, model + ":latest"]
        return tags.contains(where: { wanted.contains($0) })
    }

    public func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                        today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        let request = try makeExtractionRequest(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                                today: today, timeZone: timeZone)
        let result: ExtractionResult
        do {
            result = try await withRetry { try Self.decodeExtraction(try await send(request)) }
        } catch is TruncatedAnswer {
            // Not retried: a second run would hit the same cap and cost the same minutes.
            throw LLMError.malformedResponse("the answer was too long")
        }
        return result.applyingTierRules(tier: tier)
    }

    public func headline(for info: [InfoItem], suggestionCount: Int) async throws -> String {
        let request = try makeHeadlineRequest(info: info, suggestionCount: suggestionCount)
        do {
            let text = try await withRetry { try Self.decodeHeadline(try await send(request)) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is TruncatedAnswer {
            // Not retried, same as extraction: a second run would hit the same cap.
            throw LLMError.malformedResponse("the answer was too long")
        }
    }

    // MARK: Helpers

    /// Runs `body`, retrying once if the answer was malformed. Other errors pass through.
    private func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch LLMError.malformedResponse { return try await body() }
    }

    /// The model stopped at `num_predict`; `withRetry` lets it through so `extract` can map it.
    private struct TruncatedAnswer: Error {}

    private struct Envelope: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
        var done_reason: String?
    }

    /// Reads `{"headline": "..."}` from the reply; a cut-off answer is `TruncatedAnswer`.
    static func decodeHeadline(_ data: Data) throws -> String {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw LLMError.malformedResponse("response envelope not readable") }
        if envelope.done_reason == "length" { throw TruncatedAnswer() }
        struct Payload: Decodable { var headline: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(envelope.message.content.utf8)) else {
            throw LLMError.malformedResponse("content is not valid headline JSON")
        }
        return payload.headline
    }

    static func decodeExtraction(_ data: Data) throws -> ExtractionResult {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw LLMError.malformedResponse("response envelope not readable") }
        if envelope.done_reason == "length" { throw TruncatedAnswer() }
        let content = envelope.message.content
        guard let result = ExtractionResult.decode(jsonText: content) else {
            throw LLMError.malformedResponse("content is not valid extraction JSON")
        }
        return result
    }

    /// Sends the request and returns the body of a 2xx answer.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.perform(request, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timedOut
        } catch {
            throw LLMError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else { throw LLMError.http(status: http.statusCode) }
        return data
    }

    /// Holds the task so the cancellation handler can reach it.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ t: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            task = t
            if cancelled { t.cancel() }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }

    /// Wraps `dataTask` so cancellation behaves the same on Linux and macOS.
    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, let response { cont.resume(returning: (data, response)) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
