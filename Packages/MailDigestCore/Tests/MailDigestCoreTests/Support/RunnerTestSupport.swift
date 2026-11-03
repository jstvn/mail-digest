import Foundation
@testable import MailDigestCore

/// Records posted notifications.
actor RecordingNotifier: Notifier {
    private(set) var messages: [String] = []
    func post(_ message: String) async { messages.append(message) }
}

/// Collects progress updates from a runner's stream.
actor ProgressCollector {
    private(set) var events: [JobProgress] = []
    private var task: Task<Void, Never>?

    func add(_ p: JobProgress) { events.append(p) }

    /// Starts consuming the stream in the background.
    func attach(_ stream: AsyncStream<JobProgress>) {
        task = Task { [self] in for await p in stream { add(p) } }
    }
    func stop() { task?.cancel() }
}

/// A one-shot async signal: `wait()` returns once `fire()` has been called.
actor Gate {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() {
        fired = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Holds a value created after the closure that needs it (for hooks that call back into the runner).
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Polls (with tiny real sleeps) until the condition holds or two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
