import Foundation
import Testing
@testable import MailDigestCore

/// Answers by subcommand so detection order and arguments can be checked.
private final class RoutedRunner: ProcessRunner, @unchecked Sendable {
    var version: ProcessOutput?
    var auth: ProcessOutput?
    private let lock = NSLock()
    private var _calls: [(args: [String], env: [String: String], timeout: TimeInterval)] = []
    var calls: [(args: [String], env: [String: String], timeout: TimeInterval)] {
        lock.lock(); defer { lock.unlock() }; return _calls
    }

    private func record(_ a: [String], _ e: [String: String], _ t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _calls.append((a, e, t))
    }

    func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
             environment: [String: String], timeout: TimeInterval) async throws -> ProcessOutput {
        record(arguments, environment, timeout)
        guard let out = arguments == ["--version"] ? version : auth else { throw ProcessRunnerError.launchFailed }
        return out
    }
}

private func out(_ s: String, status: Int32 = 0) -> ProcessOutput { ProcessOutput(exitStatus: status, stdout: Data(s.utf8)) }
private let exeA = URL(fileURLWithPath: "/a/claude"), exeB = URL(fileURLWithPath: "/b/claude")

private func detector(_ r: RoutedRunner, existing: Set<String> = ["/a/claude", "/b/claude"],
                      env: [String: String] = [:]) -> ClaudeCodeDetector {
    ClaudeCodeDetector(candidates: [exeA, exeB], isExecutable: { existing.contains($0.path) }, runner: r, environment: env)
}

@Suite struct ClaudeCodeDetectorTests {
    @Test func defaultCandidateOrder() {
        let c = ClaudeCodeDetector.defaultCandidates(home: URL(fileURLWithPath: "/Users/x"))
        #expect(c.map(\.path) == ["/Users/x/.local/bin/claude", "/Users/x/.claude/local/claude",
                                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    @Test func notFoundWhenNothingExecutable() async {
        let r = RoutedRunner()
        let d = await detector(r, existing: []).detect()
        #expect(d == ClaudeCodeDetection(status: .notFound))
        #expect(r.calls.isEmpty)
    }

    @Test func readyReportsPathVersionAndPlanOnly() async {
        let r = RoutedRunner()
        r.version = out("2.1.323 (Claude Code)\n")
        r.auth = out(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"me@example.test","orgName":"Acme"}"#)
        let d = await detector(r, existing: ["/b/claude"],
                               env: ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_BASE_URL": "u", "HOME": "/h"]).detect()
        #expect(d.status == .ready && d.executable == exeB && d.version?.description == "2.1.323")
        #expect(d.subscriptionType == "max" && d.planDisplayName == "Max")
        #expect(!"\(d)".contains("example.test") && !"\(d)".contains("Acme"))
        #expect(r.calls.map(\.args) == [["--version"], ["auth", "status"]])
        #expect(r.calls.allSatisfy { $0.timeout == 10 && $0.env == ["HOME": "/h"] })
    }

    @Test func firstExecutableWins() async {
        let r = RoutedRunner()
        r.version = out("2.1.323"); r.auth = out(#"{"loggedIn":true}"#)
        #expect(await detector(r).detect().executable == exeA)
    }

    @Test func tooOldSkipsAuth() async {
        let r = RoutedRunner()
        r.version = out("2.0.1 (Claude Code)")
        let d = await detector(r).detect()
        #expect(d.status == .tooOld && d.version?.description == "2.0.1")
        #expect(r.calls.count == 1)
    }

    @Test func unreadableVersionIsTooOld() async {
        let r = RoutedRunner()
        r.version = out("garbage")
        #expect(await detector(r).detect().status == .tooOld)
    }

    @Test func notSignedInEvenWhenExitStatusNonZero() async {
        let r = RoutedRunner()
        r.version = out("2.1.400"); r.auth = out(#"{"loggedIn":false}"#, status: 1)
        #expect(await detector(r).detect().status == .notSignedIn)
        r.auth = out("not json")
        #expect(await detector(r).detect().status == .notSignedIn)
    }

    @Test func versionLaunchFailureIsNotFound() async {
        let r = RoutedRunner()
        #expect(await detector(r).detect().status == .notFound)
    }

    @Test func oddPlanIsDropped() async {
        let r = RoutedRunner()
        r.version = out("2.1.323"); r.auth = out(#"{"loggedIn":true,"subscriptionType":"a b@c"}"#)
        let d = await detector(r).detect()
        #expect(d.status == .ready && d.subscriptionType == nil && d.planDisplayName == nil)
    }
}

@Suite struct ClaudeCodeConnectionTests {
    private let structured = #"{"summary":"ok","category":"other","importance":1,"key_facts":[],"tasks":[]}"#

    @Test func reportsAnsweringModel() async {
        let json = #"{"is_error":false,"structured_output":\#(structured),"modelUsage":{"claude-haiku-5-5":{}}}"#
        let runner = FakeProcessRunner(.output(out(json)))
        let c = ClaudeCodeClient(executable: exeA, runner: runner, environment: [:])
        let r = await ClaudeCodeConnectionTester.test(client: c, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(r == .connected(model: "claude-haiku-5-5"))
        let m = ClaudeCodeConnectionMessage(result: r)
        #expect(m.isSuccess && m.detail == "Claude Haiku 5.5 answered through your Claude sign-in.")
    }

    @Test func mapsErrorsToFriendlyText() async {
        let signedOut = #"{"is_error":true,"result":"Not logged in"}"#
        let c = ClaudeCodeClient(executable: exeA, runner: FakeProcessRunner(.output(out(signedOut))), environment: [:])
        let r = await ClaudeCodeConnectionTester.test(client: c, now: .now)
        #expect(r == .failed(.notSignedIn))
        #expect(ClaudeCodeConnectionMessage(result: r).detail.contains("run claude to sign in"))
        let t = ClaudeCodeClient(executable: exeA, runner: FakeProcessRunner(.error(.timedOut)), environment: [:])
        #expect(await ClaudeCodeConnectionTester.test(client: t, now: .now) == .failed(.timedOut))
    }
}
