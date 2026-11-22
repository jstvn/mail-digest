import Foundation
import Testing
@testable import MailDigestCore

private let tz = TimeZone(identifier: "Europe/London")!
private let today = Date(timeIntervalSince1970: 1_800_000_000)
private let secretBody = "Please send the draft by Friday. SECRET-BODY-TEXT"
private let email = EmailMessage(
    id: "m1", account: "acct", mailbox: "INBOX", sender: "Sam <sam@example.test>",
    subject: "Quarterly plan", receivedAt: Date(timeIntervalSince1970: 1_799_990_000), body: secretBody, headers: [:],
    contentInspection: .complete)
private let exe = URL(fileURLWithPath: "/usr/local/bin/claude")

private let structured = """
    {"summary":"A test.","category":"uni","importance":3,"key_facts":[],"tasks":[
    {"title":"Do it","due":null,"due_has_time":false,"priority":"high","evidence":"Do it.","confidence":0.9}]}
    """

private func success(model: String? = "claude-haiku-5-5", structured s: String? = structured) -> ProcessOutput {
    let usage = model.map { #","modelUsage":{"\#($0)":{"inputTokens":10}}"# } ?? ""
    let so = s.map { #","structured_output":\#($0)"# } ?? ""
    let json = #"{"type":"result","subtype":"success","is_error":false,"result":"","total_cost_usd":0.01,"session_id":"s","stop_reason":"end_turn"\#(so)\#(usage)}"#
    return ProcessOutput(exitStatus: 0, stdout: Data(json.utf8))
}

private func client(_ runner: FakeProcessRunner, env: [String: String] = [:]) -> ClaudeCodeClient {
    ClaudeCodeClient(executable: exe, model: "haiku", runner: runner, environment: env)
}

private func extract(_ c: ClaudeCodeClient, tier: MailTier = .full) async throws -> (ExtractionResult, String?) {
    try await c.extractReportingModel(email, tier: tier, trustedNewsletter: false, today: today, timeZone: tz)
}

private func failure(_ out: ProcessOutput) async -> ClaudeCodeError? {
    do { _ = try await extract(client(FakeProcessRunner(.output(out)))); return nil }
    catch let e as ClaudeCodeError { return e } catch { return nil }
}

@Suite struct ClaudeCodeClientTests {
    @Test func argumentsSnapshotAndEmailOnStdinOnly() async throws {
        let runner = FakeProcessRunner(.output(success()))
        _ = try await extract(client(runner))
        let call = try #require(runner.calls.first)
        let a = call.arguments
        #expect(call.executable == exe)
        #expect(Array(a[0..<14]) == ["-p", "--output-format", "json", "--model", "haiku", "--tools", "",
                                      "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
                                      "--no-session-persistence", "--system-prompt", a[13]])
        #expect(a[13] == Prompts.extractionSystem(today: today, timeZone: tz, tier: .full, trustedNewsletter: false))
        #expect(a[14] == "--json-schema")
        #expect(a[15] == String(decoding: try ExtractionSchema.json.stableData(), as: UTF8.self))
        #expect(a.count == 16)
        #expect(!a.contains { $0.contains("SECRET-BODY-TEXT") || $0.contains("Quarterly plan") || $0.contains("sam@example.test") })
        #expect(String(decoding: call.stdin, as: UTF8.self) == Prompts.extractionUser(email, timeZone: tz))
        #expect(call.timeout == 120)
    }

    @Test func workingDirectoryIsFreshEmptyAndRemoved() async throws {
        let runner = FakeProcessRunner(.output(success()))
        _ = try await extract(client(runner))
        let call = try #require(runner.calls.first)
        #expect(call.workingDirectoryWasEmpty)
        #expect(!FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }

    @Test func workingDirectoryRemovedAfterFailure() async throws {
        let runner = FakeProcessRunner(.error(.timedOut))
        _ = try? await extract(client(runner))
        let call = try #require(runner.calls.first)
        #expect(!FileManager.default.fileExists(atPath: call.workingDirectory.path))
    }

    @Test func environmentStripsAnthropicCredentialsOnly() async throws {
        let runner = FakeProcessRunner(.output(success()))
        let env = ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "u",
                   "HOME": "/Users/x", "PATH": "/usr/bin"]
        _ = try await extract(client(runner, env: env))
        #expect(try #require(runner.calls.first).environment == ["HOME": "/Users/x", "PATH": "/usr/bin"])
    }

    @Test func successDecodesAndReportsModel() async throws {
        let (result, model) = try await extract(client(FakeProcessRunner(.output(success()))))
        #expect(result.summary == "A test.")
        #expect(result.tasks.count == 1)
        #expect(model == "claude-haiku-5-5")
    }

    @Test func missingModelUsageFallsBackToAlias() async throws {
        let (_, model) = try await extract(client(FakeProcessRunner(.output(success(model: nil)))))
        #expect(model == "haiku")
    }

    @Test func infoOnlyTierDropsTasks() async throws {
        let (result, _) = try await extract(client(FakeProcessRunner(.output(success()))), tier: .infoOnly)
        #expect(result.tasks.isEmpty)
    }

    @Test func notLoggedIn() async {
        let json = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(await failure(ProcessOutput(exitStatus: 1, stdout: Data(json.utf8))) == .notSignedIn)
    }

    @Test func isErrorIsProcessFailure() async {
        let json = #"{"type":"result","is_error":true,"result":"Overloaded SECRET-BODY-TEXT"}"#
        #expect(await failure(ProcessOutput(exitStatus: 0, stdout: Data(json.utf8))) == .processFailed)
    }

    @Test func nonZeroExitIsProcessFailure() async {
        #expect(await failure(ProcessOutput(exitStatus: 2, stderr: Data("boom".utf8))) == .processFailed)
    }

    @Test func missingStructuredOutputAndBadJSONAreMalformed() async {
        #expect(await failure(success(structured: nil)) == .malformedResponse)
        #expect(await failure(ProcessOutput(exitStatus: 0, stdout: Data("not json".utf8))) == .malformedResponse)
        #expect(await failure(success(structured: #"{"summary":1}"#)) == .malformedResponse)
    }

    @Test func timeoutIsTypedError() async {
        let runner = FakeProcessRunner(.error(.timedOut))
        await #expect(throws: ClaudeCodeError.timedOut) { _ = try await extract(client(runner)) }
    }

    @Test func launchFailureIsTypedError() async {
        let runner = FakeProcessRunner(.error(.launchFailed))
        await #expect(throws: ClaudeCodeError.launchFailed) { _ = try await extract(client(runner)) }
    }

    @Test func cancellationPropagatesAsCancellationError() async {
        let runner = FakeProcessRunner(.waitForCancellation)
        let task = Task { try await extract(client(runner)) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch is CancellationError {} catch { Issue.record("wrong error \(error)") }
    }

    @Test func errorDescriptionsHoldNoEmailText() {
        for e in [ClaudeCodeError.notSignedIn, .launchFailed, .timedOut, .processFailed, .malformedResponse] {
            #expect(!"\(e)".contains("SECRET"))
        }
    }
}

@Suite struct ClaudeCodeParsingTests {
    @Test func authStatusReadsOnlyThreeFields() throws {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.c","orgName":"Org","subscriptionType":"max"}"#
        let s = try #require(ClaudeAuthStatus.parse(Data(json.utf8)))
        #expect(s == ClaudeAuthStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max"))
        #expect(ClaudeAuthStatus.parse(Data(#"{"loggedIn":false}"#.utf8))?.loggedIn == false)
        #expect(ClaudeAuthStatus.parse(Data("nope".utf8)) == nil)
        #expect(ClaudeAuthStatus.parse(Data(#"{"email":"a@b.c"}"#.utf8)) == nil)
    }

    @Test func versionParsingAndMinimum() throws {
        let v = try #require(ClaudeCodeVersion.parse("2.1.323 (Claude Code)\n"))
        #expect(v == ClaudeCodeVersion.minimum && v.meetsMinimum && v.description == "2.1.323")
        #expect(ClaudeCodeVersion.parse("2.1.322 (Claude Code)")?.meetsMinimum == false)
        #expect(ClaudeCodeVersion.parse("2.2.0")?.meetsMinimum == true)
        #expect(ClaudeCodeVersion.parse("10.0.1 (Claude Code)")?.meetsMinimum == true)
        #expect(ClaudeCodeVersion.parse("2.0.999")?.meetsMinimum == false)
        #expect(ClaudeCodeVersion.parse("claude") == nil)
        #expect(ClaudeCodeVersion.parse("") == nil)
    }

    @Test func modelDisplayNames() {
        #expect(RoutingPresentation.modelDisplayName("claude-haiku-5-5") == "Claude Haiku 5.5")
        #expect(RoutingPresentation.modelDisplayName("claude-sonnet-5-5") == "Claude Sonnet 5.5")
        #expect(RoutingPresentation.modelDisplayName("claude-opus-4-1-20250805") == "claude-opus-4-1-20250805")
        #expect(RoutingPresentation.modelDisplayName("mystery") == "mystery")
    }
}

@Suite struct CloudProviderSettingsTests {
    private func settings(enabled: Bool = true, provider: CloudProvider, gemini: Int? = 1, claude: Int? = 1) -> DigestSettings {
        DigestSettings(cloudDigestEnabled: enabled, cloudPrivacyAcknowledgedRevision: gemini,
                       cloudProvider: provider, claudeCodePrivacyAcknowledgedRevision: claude)
    }

    @Test func oldJSONDecodesToDefaults() throws {
        let s = try JSONDecoder().decode(DigestSettings.self, from: Data(#"{"cloudDigestEnabled":true,"cloudPrivacyAcknowledgedRevision":1}"#.utf8))
        #expect(s.cloudProvider == .gemini && s.claudeCodeModel == "haiku")
        #expect(s.claudeCodePrivacyAcknowledgedRevision == nil && s.cloudPrivacyAcknowledgedRevision == 1)
    }

    @Test func roundTrip() throws {
        let s = settings(provider: .claudeCode, claude: 1)
        let back = try JSONDecoder().decode(DigestSettings.self, from: JSONEncoder().encode(s))
        #expect(back.cloudProvider == .claudeCode && back.claudeCodePrivacyAcknowledgedRevision == 1)
    }

    @Test func readinessRules() {
        func reason(_ s: DigestSettings, key: Bool = true, status: ClaudeCodeStatus = .ready) -> LocalReason? {
            CloudPrivacyPolicy.offReason(settings: s, hasGeminiKey: key, claudeCode: status)
        }
        #expect(reason(settings(enabled: false, provider: .claudeCode)) == .cloudDisabled)
        #expect(reason(settings(provider: .gemini)) == nil)
        #expect(reason(settings(provider: .gemini), key: false) == .noCredential)
        #expect(reason(settings(provider: .gemini, gemini: nil)) == .acknowledgementRequired)
        // Each provider checks only its own acknowledgement.
        #expect(reason(settings(provider: .gemini, claude: nil)) == nil)
        #expect(reason(settings(provider: .claudeCode, gemini: nil)) == nil)
        #expect(reason(settings(provider: .claudeCode, claude: nil)) == .acknowledgementRequired)
        // The Gemini key is irrelevant to Claude Code.
        #expect(reason(settings(provider: .claudeCode), key: false) == nil)
        for status in [ClaudeCodeStatus.notFound, .notSignedIn, .tooOld] {
            #expect(reason(settings(provider: .claudeCode), status: status) == .providerUnavailable)
        }
        // Claude Code status is irrelevant to Gemini.
        #expect(reason(settings(provider: .gemini), status: .notFound) == nil)
    }
}

@Suite struct ClaudeCodeRoutingTests {
    private let allowlistedEmail = EmailMessage(
        id: "r1", account: "iCloud", mailbox: "Inbox", sender: "Writer <writer@substack.com>", subject: "Weekly",
        receivedAt: today.addingTimeInterval(-3600), body: "A public newsletter about gardening.",
        headers: ["List-Unsubscribe": "<https://substack.com/unsub>"], contentInspection: .complete)

    private func run(_ cfg: CloudRoutingConfig, llm: StubLLMClient = StubLLMClient()) async throws -> EmailOutcome {
        let p = DigestPipeline(llm: llm, filter: MailFilter(), timeZone: tz, clock: FixedClock(today))
        return try await p.process(allowlistedEmail, today: today, recentSuggestions: [],
                                   senderHasApprovedDecision: false, routingConfig: cfg)
    }

    private func cfg(_ runner: FakeProcessRunner) -> CloudRoutingConfig {
        CloudRoutingConfig(cloudExtractor: client(runner), cloudModel: "haiku", offReason: nil, triage: nil,
                           triageModel: "sys1", privacyThreshold: 0.9, cloudProvider: .claudeCode)
    }

    @Test func successUsesReportedModelAndLabel() async throws {
        let runner = FakeProcessRunner(.output(success(model: "claude-haiku-5-5")))
        let e = try #require(try await run(cfg(runner)).routing?.execution)
        #expect(e.provider == .cloud && e.model == "claude-haiku-5-5" && e.cloudProvider == .claudeCode)
        #expect(RoutingPresentation.executionBadge(e).text == "Cloud · Claude Haiku 5.5")
    }

    @Test func failureFallsBackLocalWithProviderLabel() async throws {
        let runner = FakeProcessRunner(.error(.timedOut))
        let llm = StubLLMClient()
        let e = try #require(try await run(cfg(runner), llm: llm).routing?.execution)
        #expect(e.provider == .local && e.cloudAttempted && e.localReason == .cloudFailed)
        #expect(e.cloudFailure == "timedOut" && e.cloudProvider == .claudeCode)
        #expect(await llm.extractCalls.count == 1)
        #expect(RoutingPresentation.executionBadge(e).text == "Claude Code failed → Local \(RoutingPresentation.modelDisplayName(e.model))")
    }

    @Test func cancellationDoesNotFallBack() async {
        let runner = FakeProcessRunner(.waitForCancellation)
        let llm = StubLLMClient()
        let task = Task { try await run(cfg(runner), llm: llm) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch is CancellationError {} catch { Issue.record("wrong error \(error)") }
        #expect(await llm.extractCalls.isEmpty)
    }

    @Test func providerUnavailableStaysLocal() async throws {
        let off = CloudRoutingConfig.localOnly(reason: .providerUnavailable)
        let e = try #require(try await run(off).routing?.execution)
        #expect(e.provider == .local && e.localReason == .providerUnavailable && !e.cloudAttempted)
        #expect(e.cloudProvider == nil)
    }

    @Test func oldExecutionRecordsStillDecodeAsGeminiLabels() throws {
        let json = #"{"provider":"local","model":"qwen3:4b","cloudAttempted":true,"localReason":"cloudFailed","cloudFailure":"rateLimited","startedAt":0,"finishedAt":1}"#
        let e = try JSONDecoder().decode(ExecutionRecord.self, from: Data(json.utf8))
        #expect(e.cloudProvider == nil)
        #expect(RoutingPresentation.executionBadge(e).text == "Gemini failed → Local Qwen3 4B")
    }
}
