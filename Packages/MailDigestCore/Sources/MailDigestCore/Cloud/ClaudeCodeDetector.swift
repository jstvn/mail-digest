import Foundation

/// What detection found. Holds only the path, version and plan type; account, organisation and e-mail
/// fields are never read.
public struct ClaudeCodeDetection: Sendable, Equatable {
    public var status: ClaudeCodeStatus
    public var executable: URL?
    public var version: ClaudeCodeVersion?
    /// `subscriptionType` from `claude auth status` (for example "max"), sanitised for display.
    public var subscriptionType: String?

    public init(status: ClaudeCodeStatus, executable: URL? = nil, version: ClaudeCodeVersion? = nil,
                subscriptionType: String? = nil) {
        self.status = status
        self.executable = executable
        self.version = version
        self.subscriptionType = subscriptionType
    }

    /// "Max", "Pro", ...; nil when the plan was not reported.
    public var planDisplayName: String? {
        subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}

/// Finds the Claude Code CLI and checks its version and sign-in. Runs `--version` and `auth status` only;
/// it never starts a model request. All process work goes through `ProcessRunner`, so tests use a fake.
public struct ClaudeCodeDetector: Sendable {
    public static let probeTimeout: TimeInterval = 10

    /// The install locations, in the order they are tried (Q93).
    public static func defaultCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"),
         home.appendingPathComponent(".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    public static let isExecutableFile: @Sendable (URL) -> Bool = { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private let candidates: [URL]
    private let isExecutable: @Sendable (URL) -> Bool
    private let runner: any ProcessRunner
    private let environment: [String: String]

    public init(candidates: [URL] = ClaudeCodeDetector.defaultCandidates(),
                isExecutable: @escaping @Sendable (URL) -> Bool = ClaudeCodeDetector.isExecutableFile,
                runner: any ProcessRunner = FoundationProcessRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.runner = runner
        self.environment = environment
    }

    public func detect() async -> ClaudeCodeDetection {
        guard let exe = candidates.first(where: isExecutable) else { return ClaudeCodeDetection(status: .notFound) }
        // An empty directory, so the CLI never reads project files; same env stripping as the client.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maildigest-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return ClaudeCodeDetection(status: .notFound, executable: exe) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = environment.filter { !ClaudeCodeClient.strippedEnvironmentKeys.contains($0.key) }

        func probe(_ args: [String]) async -> ProcessOutput? {
            try? await runner.run(executable: exe, arguments: args, stdin: Data(), workingDirectory: dir,
                                  environment: env, timeout: Self.probeTimeout)
        }
        guard let out = await probe(["--version"]), out.exitStatus == 0 else {
            return ClaudeCodeDetection(status: .notFound, executable: exe)
        }
        // A version that can't be read can't be shown to meet the minimum.
        let version = ClaudeCodeVersion.parse(String(decoding: out.stdout, as: UTF8.self))
        guard let version, version.meetsMinimum else {
            return ClaudeCodeDetection(status: .tooOld, executable: exe, version: version)
        }
        // A signed-out CLI may exit non-zero but still print JSON, so read stdout regardless of the exit status.
        guard let auth = await probe(["auth", "status"]).flatMap({ ClaudeAuthStatus.parse($0.stdout) }),
              auth.loggedIn else {
            return ClaudeCodeDetection(status: .notSignedIn, executable: exe, version: version)
        }
        let plan = auth.subscriptionType.flatMap { Self.sanitisedPlan($0) }
        return ClaudeCodeDetection(status: .ready, executable: exe, version: version, subscriptionType: plan)
    }

    /// Plan names are short words; anything else is dropped rather than shown.
    private static func sanitisedPlan(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 24, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return t
    }
}

/// Outcome of the one-prompt Test Connection.
public enum ClaudeCodeConnectionResult: Sendable, Equatable {
    /// `model` is the id Claude Code reported, when it said.
    case connected(model: String?)
    case failed(ClaudeCodeError)
}

/// Runs one synthetic, non-email prompt through the real extraction path.
public enum ClaudeCodeConnectionTester {
    private static let probe = EmailMessage(
        id: "connection-test", account: "test", mailbox: "test", sender: "Test <test@example.invalid>",
        subject: "Connection test", receivedAt: Date(timeIntervalSince1970: 0),
        body: "This is a connection test. It is not an email.", headers: [:], contentInspection: .complete)

    public static func test(client: ClaudeCodeClient, now: Date, timeZone: TimeZone = .current) async
        -> ClaudeCodeConnectionResult {
        do {
            let (_, model) = try await client.extractReportingModel(probe, tier: .infoOnly, trustedNewsletter: false,
                                                                   today: now, timeZone: timeZone)
            return .connected(model: model)
        } catch let e as ClaudeCodeError {
            return .failed(e)
        } catch {
            return .failed(.launchFailed)
        }
    }
}

/// User-facing copy for a Claude Code Test Connection result and for detection status.
public struct ClaudeCodeConnectionMessage: Sendable, Equatable {
    public var title: String?
    public var detail: String
    public var footnote: String?
    public var isSuccess: Bool

    public init(result: ClaudeCodeConnectionResult) {
        switch result {
        case .connected(let model):
            let name = model.map { RoutingPresentation.modelDisplayName($0) } ?? "Claude"
            self.init(title: "Connection successful", detail: "\(name) answered through your Claude sign-in.",
                      footnote: "Only a short test message was sent. No email content was sent.", isSuccess: true)
        case .failed(.notSignedIn):
            self.init(detail: "Claude Code isn't signed in. Open Terminal, run claude to sign in, then try again.")
        case .failed(.launchFailed):
            self.init(detail: "Couldn't start Claude Code. Check that it is installed, then check again.")
        case .failed(.timedOut):
            self.init(detail: "Claude Code took too long to answer. Try again in a moment.")
        case .failed(.processFailed), .failed(.malformedResponse):
            self.init(detail: "Claude Code returned an error. Try again later.")
        }
    }

    private init(title: String? = nil, detail: String, footnote: String? = nil, isSuccess: Bool = false) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.isSuccess = isSuccess
    }
}
