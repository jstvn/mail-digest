import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MailDigestCore

private let key = "test-key-123"
private let model = "gemini-3.5-flash-lite"
private let tz = TimeZone(identifier: "Europe/London")!
private let today = Date(timeIntervalSince1970: 1_800_000_000)

private let email = EmailMessage(
    id: "m1", account: "acct", mailbox: "INBOX", sender: "Sam <sam@example.test>",
    subject: "Quarterly plan", receivedAt: Date(timeIntervalSince1970: 1_799_990_000),
    body: "Please send the draft by Friday.", headers: ["To": "secret-recipient@example.test"])

private let validContent = """
    {"summary":"A test.","category":"uni","importance":3,"key_facts":[],"tasks":[
    {"title":"Do it","due":null,"due_has_time":false,"priority":"high","evidence":"Do it.","confidence":0.9}]}
    """

private func reply(_ parts: [String], finish: String = "STOP") -> Data {
    let p: [JSONValue] = parts.map { .object(["text": .string($0)]) }
    let body: JSONValue = .object(["candidates": .array([.object([
        "content": .object(["role": .string("model"), "parts": .array(p)]),
        "finishReason": .string(finish),
    ])])])
    return try! body.stableData()
}

private func errorBody(_ code: Int, status: String, reason: String? = nil) -> Data {
    let details = reason.map { #","details":[{"@type":"x","reason":"\#($0)"}]"# } ?? ""
    return Data(#"{"error":{"code":\#(code),"message":"secret server text \#(key)","status":"\#(status)"\#(details)}}"#.utf8)
}

private func client() -> GeminiClient { GeminiClient(apiKey: key, model: model, session: StubURLProtocol.makeSession()) }

private func extract(_ c: GeminiClient = client(), tier: MailTier = .full) async throws -> ExtractionResult {
    try await c.extract(email, tier: tier, trustedNewsletter: false, today: today, timeZone: tz)
}

private func failure(_ response: StubResponse) async -> GeminiError? {
    StubURLProtocol.install { _ in response }
    do { _ = try await extract(); return nil } catch let e as GeminiError { return e } catch { return nil }
}

@Suite struct GeminiSchemaAdapterTests {
    @Test func adaptedSchemaSnapshot() throws {
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"object","required":["summary","category","importance","key_facts","tasks"],"properties":{
        "summary":{"type":"string"},
        "category":{"enum":\(try categories())},
        "importance":{"type":"integer","minimum":1,"maximum":5},
        "key_facts":{"type":"array","maxItems":4,"items":{"type":"string"}},
        "tasks":{"type":"array","maxItems":8,"items":{"type":"object",
        "required":["title","due","due_has_time","priority","evidence","confidence"],"properties":{
        "title":{"type":"string"},"due":{"type":["string","null"]},"due_has_time":{"type":"boolean"},
        "priority":{"enum":["high","medium","low"]},"evidence":{"type":"string"},"confidence":{"type":"number"}}}}}}
        """.utf8))
        #expect(GeminiSchemaAdapter.adapt() == expected)
    }

    private func categories() throws -> String {
        String(decoding: try JSONEncoder().encode(Category.allCases.map(\.rawValue)), as: UTF8.self)
    }

    @Test func dropsUnsupportedKeywordsButKeepsPropertyNames() {
        let schema: JSONValue = .object([
            "type": .string("object"), "minProperties": .number(1),
            "properties": .object(["minLength": .object(["type": .string("string"), "maxLength": .number(3)])]),
        ])
        let out = GeminiSchemaAdapter.adapt(schema)
        #expect(out == .object([
            "type": .string("object"),
            "properties": .object(["minLength": .object(["type": .string("string")])]),
        ]))
    }

    @Test func convertsAnyOfNullable() {
        let schema: JSONValue = .object(["anyOf": .array([
            .object(["type": .string("string")]), .object(["type": .string("null")])])])
        #expect(GeminiSchemaAdapter.adapt(schema) == .object(["type": .array([.string("string"), .string("null")])]))
    }

    @Test func doesNotChangeSourceSchema() {
        _ = GeminiSchemaAdapter.adapt()
        #expect(ExtractionSchema.json == GeminiSchemaAdapter.adapt())
    }
}

extension StubNetworkTests {
@Suite struct GeminiClientTests {
    @Test func requestShape() async throws {
        StubURLProtocol.install { _ in StubResponse(body: reply([validContent])) }
        _ = try await extract()
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.method == "POST")
        #expect(req.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        #expect(req.url.query == nil)
        #expect(!req.url.absoluteString.contains(key))
        #expect(req.headers["x-goog-api-key"] == key)
        #expect(req.timeout == 60)
        let body = try #require(try JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        let sys = (((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"]) as? String
        #expect(sys == Prompts.extractionSystem(today: today, timeZone: tz, tier: .full))
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
        let user = (contents[0]["parts"] as? [[String: Any]])?.first?["text"] as? String
        #expect(user == Prompts.extractionUser(email, timeZone: tz))
        #expect(user?.contains("secret-recipient") == false)
        let cfg = try #require(body["generationConfig"] as? [String: Any])
        #expect(cfg["responseMimeType"] as? String == "application/json")
        #expect(cfg["maxOutputTokens"] as? Int == 2048)
        let schema = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: try #require(cfg["responseJsonSchema"])))
        #expect(schema == GeminiSchemaAdapter.adapt())
        #expect(!String(decoding: req.body, as: UTF8.self).contains(key))
    }

    @Test func decodesLikeOllamaPath() async throws {
        StubURLProtocol.install { _ in StubResponse(body: reply([validContent])) }
        let result = try await extract()
        let ollamaEnvelope = try JSONValue.object(["message": .object(["content": .string(validContent)])]).stableData()
        #expect(result == (try OllamaClient.decodeExtraction(ollamaEnvelope)))
    }

    @Test func concatenatesParts() async throws {
        let mid = validContent.index(validContent.startIndex, offsetBy: 30)
        StubURLProtocol.install { _ in StubResponse(body: reply([String(validContent[..<mid]), String(validContent[mid...])])) }
        #expect(try await extract().summary == "A test.")
    }

    @Test func infoOnlyTierClearsTasks() async throws {
        StubURLProtocol.install { _ in StubResponse(body: reply([validContent])) }
        #expect(try await extract(tier: .infoOnly).tasks.isEmpty)
    }

    @Test func finishReasons() async {
        #expect(await failure(StubResponse(body: reply([validContent], finish: "MAX_TOKENS"))) == .malformedResponse)
        #expect(await failure(StubResponse(body: reply([validContent], finish: "SAFETY"))) == .blocked)
    }

    @Test func blockReason() async {
        let body = Data(#"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#.utf8)
        #expect(await failure(StubResponse(body: body)) == .blocked)
    }

    @Test func httpErrors() async {
        #expect(await failure(StubResponse(status: 400, body: errorBody(400, status: "INVALID_ARGUMENT", reason: "API_KEY_INVALID"))) == .invalidCredential)
        #expect(await failure(StubResponse(status: 400, body: errorBody(400, status: "INVALID_ARGUMENT"))) == .malformedResponse)
        #expect(await failure(StubResponse(status: 401, body: errorBody(401, status: "UNAUTHENTICATED"))) == .invalidCredential)
        #expect(await failure(StubResponse(status: 403, body: errorBody(403, status: "PERMISSION_DENIED"))) == .invalidCredential)
        #expect(await failure(StubResponse(status: 404, body: errorBody(404, status: "NOT_FOUND"))) == .modelUnavailable)
        #expect(await failure(StubResponse(status: 429, body: errorBody(429, status: "RESOURCE_EXHAUSTED"))) == .rateLimited)
        #expect(await failure(StubResponse(status: 500, body: errorBody(500, status: "INTERNAL"))) == .server(500))
        #expect(StubURLProtocol.requests.count == 1, "no retry")
    }

    @Test func transportFailures() async {
        #expect(await failure(StubResponse(failure: .timedOut)) == .timedOut)
        #expect(await failure(StubResponse(failure: .notConnectedToInternet)) == .network)
    }

    @Test func malformedAnswers() async {
        #expect(await failure(StubResponse(body: Data("nope".utf8))) == .malformedResponse)
        #expect(await failure(StubResponse(body: reply(["not json"]))) == .malformedResponse)
        #expect(await failure(StubResponse(body: reply([#"{"summary":"x"}"#]))) == .malformedResponse)
        #expect(await failure(StubResponse(body: Data(#"{"candidates":[]}"#.utf8))) == .malformedResponse)
    }

    @Test func cancellationPropagates() async {
        StubURLProtocol.install { _ in StubResponse(body: reply([validContent])) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await extract()
        }
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch is CancellationError {}
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func errorsNeverContainKey() async {
        let cases: [GeminiError] = [.invalidCredential, .rateLimited, .modelUnavailable, .server(500),
                                    .timedOut, .network, .blocked, .malformedResponse]
        for e in cases {
            #expect(!String(describing: e).contains(key))
            #expect(!String(reflecting: e).contains(key))
            #expect(!e.code.isEmpty)
        }
        #expect(GeminiError.rateLimited.code == "rateLimited")
    }

    @Test func clientDescriptionsHideKey() {
        let c = GeminiClient(apiKey: key)
        #expect(!String(describing: c).contains(key))
        #expect(!String(reflecting: c).contains(key))
        #expect(!"\(c)".contains(key))
    }
}

@Suite struct GeminiConnectionTesterTests {
    private func run(_ response: StubResponse) async -> GeminiConnectionResult {
        StubURLProtocol.install { _ in response }
        return await GeminiConnectionTester.test(apiKey: key, model: model, session: StubURLProtocol.makeSession())
    }

    private func meta(name: String = "models/\(model)", methods: [String] = ["generateContent", "countTokens"]) -> Data {
        let m = methods.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(#"{"name":"\#(name)","supportedGenerationMethods":[\#(m)]}"#.utf8)
    }

    @Test func connectedAndRequestShape() async throws {
        #expect(await run(StubResponse(body: meta())) == .connected)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.method == "GET")
        #expect(req.body.isEmpty)
        #expect(req.url.query == nil)
        #expect(req.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/\(model)")
        #expect(req.headers["x-goog-api-key"] == key)
    }

    @Test func customModelIsInURLAndKeyOnlyInHeader() async throws {
        StubURLProtocol.install { _ in StubResponse(body: Data(#"{"name":"models/gemini-x-y","supportedGenerationMethods":["generateContent"]}"#.utf8)) }
        let r = await GeminiConnectionTester.test(apiKey: key, model: "gemini-x-y", session: StubURLProtocol.makeSession())
        #expect(r == .connected)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.method == "GET" && req.body.isEmpty)
        #expect(req.url.absoluteString.hasSuffix("/models/gemini-x-y"))
        #expect(!req.url.absoluteString.contains(key))
        #expect(req.headers["x-goog-api-key"] == key)
    }

    @Test func outcomes() async {
        #expect(await run(StubResponse(status: 400, body: errorBody(400, status: "INVALID_ARGUMENT", reason: "API_KEY_INVALID"))) == .invalidKey)
        #expect(await run(StubResponse(status: 403)) == .invalidKey)
        #expect(await run(StubResponse(status: 401)) == .invalidKey)
        #expect(await run(StubResponse(status: 404)) == .modelUnavailable)
        #expect(await run(StubResponse(status: 429)) == .rateLimited)
        #expect(await run(StubResponse(status: 503)) == .server(503))
        #expect(await run(StubResponse(failure: .notConnectedToInternet)) == .network)
        #expect(await run(StubResponse(failure: .timedOut)) == .network)
        #expect(await run(StubResponse(body: meta(methods: ["embedContent"]))) == .generateContentUnsupported)
        #expect(await run(StubResponse(body: meta(name: "models/other"))) == .unexpectedResponse)
        #expect(await run(StubResponse(body: Data("{}".utf8))) == .unexpectedResponse)
        #expect(await run(StubResponse(status: 302)) == .unexpectedResponse)
    }
}
}

@Suite struct CredentialStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.read() == nil)
        try store.save(key)
        #expect(try store.read() == key)
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }
}
