import Foundation
import MailDigestCore
import Observation

/// Settings-side state for Claude Code: what detection found and the last Test Connection. Jobs detect on
/// their own (`CloudRoutingProvider`), so nothing here is trusted at run time. Never holds account details.
@MainActor @Observable
final class ClaudeCodeModel {
    enum TestState: Equatable {
        case idle, running, finished(ClaudeCodeConnectionResult)
    }

    private(set) var detection: ClaudeCodeDetection?
    private(set) var isChecking = false
    private(set) var test = TestState.idle
    @ObservationIgnored private let detector: ClaudeCodeDetector
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(detector: ClaudeCodeDetector = ClaudeCodeDetector()) { self.detector = detector }

    /// Preview support: a fixed detection result.
    init(preview: ClaudeCodeDetection?, test: TestState = .idle) {
        self.detector = ClaudeCodeDetector()
        self.detection = preview
        self.test = test
    }

    /// Looks for Claude Code again. The probes run in child processes, never on the main thread.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        test = .idle
        let found = await detector.detect()
        detection = found
        isChecking = false
    }

    /// Sends one synthetic prompt (no email content) and records the outcome.
    func runTest(model: String) {
        guard test != .running, let exe = detection?.executable else { return }
        test = .running
        testTask?.cancel()
        testTask = Task {
            let client = ClaudeCodeClient(executable: exe, model: model)
            let result = await ClaudeCodeConnectionTester.test(client: client, now: Date())
            if !Task.isCancelled { test = .finished(result) }
        }
    }
}
