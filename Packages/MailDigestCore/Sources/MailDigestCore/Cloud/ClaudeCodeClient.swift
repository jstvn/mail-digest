import Foundation

/// Cloud extraction through the user's Claude Code sign-in. Extraction only; no retry.
/// The email goes on stdin, never in the argument list.
public struct ClaudeCodeClient: ReportedModelExtractor {
    public static let timeout: TimeInterval = 120
    /// Variables removed so usage stays on the user's sign-in rather than an API key.
    public static let strippedEnvironmentKeys: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                                                              "ANTHROPIC_BASE_URL"]

    public let executable: URL
    public let model: String
    private let runner: any ProcessRunner
    private let baseEnvironment: [String: String]

    public init(executable: URL, model: String = DigestSettings.defaultClaudeCodeModel,
                runner: any ProcessRunner = FoundationProcessRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.model = model
        self.runner = runner
        self.baseEnvironment = environment
    }

    /// The exact argument list. Contains the system prompt and schema, never email content.
    func arguments(tier: MailTier, trustedNewsletter: Bool, today: Date, timeZone: TimeZone) throws -> [String] {
        let system = Prompts.extractionSystem(today: today, timeZone: timeZone, tier: tier,
                                              trustedNewsletter: trustedNewsletter)
        let schema = String(decoding: try ExtractionSchema.json.stableData(), as: UTF8.self)
        return ["-p", "--output-format", "json", "--model", model, "--tools", "", "--strict-mcp-config",
                "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
                "--system-prompt", system, "--json-schema", schema]
    }

    func childEnvironment() -> [String: String] {
        baseEnvironment.filter { !Self.strippedEnvironmentKeys.contains($0.key) }
    }

    public func extract(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                        today: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        try await extractReportingModel(email, tier: tier, trustedNewsletter: trustedNewsletter,
                                        today: today, timeZone: timeZone).0
    }

    public func extractReportingModel(_ email: EmailMessage, tier: MailTier, trustedNewsletter: Bool,
                                      today: Date, timeZone: TimeZone) async throws -> (ExtractionResult, String?) {
        let args = try arguments(tier: tier, trustedNewsletter: trustedNewsletter, today: today, timeZone: timeZone)
        let stdin = Data(Prompts.extractionUser(email, timeZone: timeZone).utf8)
        // A fresh empty directory, so the CLI never picks up project files or settings.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maildigest-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw ClaudeCodeError.launchFailed }
        defer { try? FileManager.default.removeItem(at: dir) }

        let output: ProcessOutput
        do {
            output = try await runner.run(executable: executable, arguments: args, stdin: stdin,
                                          workingDirectory: dir, environment: childEnvironment(),
                                          timeout: Self.timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessRunnerError.timedOut {
            throw ClaudeCodeError.timedOut
        } catch {
            throw ClaudeCodeError.launchFailed
        }
        var (result, reported) = try Self.decode(output, fallbackModel: model)
        if tier == .infoOnly { result.tasks = [] }
        return (result, reported)
    }

    private struct Envelope: Decodable {
        var is_error: Bool?
        var result: String?
        var structured_output: JSONValue?
        var modelUsage: [String: JSONValue]?
    }

    /// Reads the CLI's JSON result. Errors never include the text it contained.
    static func decode(_ output: ProcessOutput, fallbackModel: String) throws -> (ExtractionResult, String?) {
        let env = try? JSONDecoder().decode(Envelope.self, from: output.stdout)
        if env?.is_error == true {
            if env?.result?.contains("Not logged in") == true { throw ClaudeCodeError.notSignedIn }
            throw ClaudeCodeError.processFailed
        }
        guard output.exitStatus == 0 else { throw ClaudeCodeError.processFailed }
        guard let env else { throw ClaudeCodeError.malformedResponse }
        guard let structured = env.structured_output, case .object = structured,
              let data = try? structured.stableData(),
              let result = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            throw ClaudeCodeError.malformedResponse
        }
        // The CLI reports the model that answered as the single key of `modelUsage`.
        let reported = env.modelUsage?.count == 1 ? env.modelUsage?.keys.first : nil
        return (result, reported ?? fallbackModel)
    }
}

/// `claude auth status` JSON. Only these fields are read; account, organisation and e-mail fields are ignored.
public struct ClaudeAuthStatus: Sendable, Equatable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var subscriptionType: String?

    /// Nil when the output is not a JSON object with a boolean `loggedIn`.
    public static func parse(_ data: Data) -> ClaudeAuthStatus? {
        struct Wire: Decodable { var loggedIn: Bool?; var authMethod: String?; var subscriptionType: String? }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), let loggedIn = w.loggedIn else { return nil }
        return ClaudeAuthStatus(loggedIn: loggedIn, authMethod: w.authMethod, subscriptionType: w.subscriptionType)
    }
}

/// A Claude Code version such as "2.1.323".
public struct ClaudeCodeVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var components: [Int]
    /// The version verified for the flags `ClaudeCodeClient` uses; older versions may lack them.
    public static let minimum = ClaudeCodeVersion(components: [2, 1, 323])

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Parses `claude --version` output like "2.1.323 (Claude Code)"; nil when no dotted number leads it.
    public static func parse(_ output: String) -> ClaudeCodeVersion? {
        let first = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let parts = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return ClaudeCodeVersion(components: parts.compactMap { $0 })
    }

    public var meetsMinimum: Bool { self >= Self.minimum }

    public static func < (a: Self, b: Self) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
