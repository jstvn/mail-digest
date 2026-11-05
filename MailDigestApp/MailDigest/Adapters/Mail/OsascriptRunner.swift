import Foundation
import MailDigestCore

/// Failures of an `osascript` invocation. Messages never include mail content.
enum OsascriptError: Error, Sendable, Equatable {
    /// Apple Events to Mail were refused (error -1743): Automation permission is missing.
    case automationDenied
    /// Mail was not running or the connection was invalid (-600).
    case mailNotRunning
    /// The hard timeout expired and the child was terminated.
    case timedOut
    /// Non-zero exit with a short, single-line stderr excerpt.
    case scriptFailed(code: Int32, stderrExcerpt: String)
    /// `osascript` could not be started.
    case launchFailed
    /// A bundled script resource is missing.
    case scriptMissing(String)
}

/// Runs a JXA script and returns its stdout. A seam so the sources can be tested without Mail.
protocol JXARunning: Sendable {
    func run(script: URL, argument: String?) async throws -> Data
}

/// Runs `/usr/bin/osascript -l JavaScript` off the main actor with a hard timeout (Q6).
struct OsascriptRunner: JXARunning {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    func run(script: URL, argument: String?) async throws -> Data {
        let box = ProcessBox()
        let timeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try Self.runBlocking(script: script, argument: argument,
                                                                           timeout: timeout, box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Q6: only the hard timeout kills the child. A cancelled call lets the script finish
            // (every script is read-only or idempotent) and then discards its result.
            box.cancel()
        }
    }

    /// Records cancellation so a script is not launched after it and its result is discarded.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }

    /// Thread-safe byte accumulator for a pipe reader.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func runBlocking(script: URL, argument: String?, timeout: TimeInterval, box: ProcessBox) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path] + (argument.map { [$0] } ?? [])
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard !box.isCancelled else { throw CancellationError() }
        do { try process.run() } catch { throw OsascriptError.launchFailed }

        // Drain both pipes concurrently so a full pipe buffer can never block the child.
        let stdout = Buffer(), stderr = Buffer()
        let readers = DispatchGroup()
        for (pipe, buffer) in [(out, stdout), (err, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffer.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        readers.wait()
        if timedOut { throw OsascriptError.timedOut }
        if box.isCancelled { throw CancellationError() }

        guard process.terminationStatus == 0 else {
            throw classify(stderr: String(decoding: stderr.get(), as: UTF8.self), code: process.terminationStatus)
        }
        return stdout.get()
    }

    private static func classify(stderr: String, code: Int32) -> OsascriptError {
        if stderr.contains("-1743") { return .automationDenied }
        if stderr.contains("-600") || stderr.localizedCaseInsensitiveContains("isn't running") { return .mailNotRunning }
        let oneLine = stderr.split(whereSeparator: \.isNewline).joined(separator: " ")
        return .scriptFailed(code: code, stderrExcerpt: String(oneLine.prefix(300)))
    }
}
