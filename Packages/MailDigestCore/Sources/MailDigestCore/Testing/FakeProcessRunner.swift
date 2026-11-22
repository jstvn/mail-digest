import Foundation

/// One recorded `ProcessRunner.run` call.
public struct RecordedProcessCall: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var stdin: Data
    public var workingDirectory: URL
    public var environment: [String: String]
    public var timeout: TimeInterval
    /// Whether the working directory existed and was empty while the call ran.
    public var workingDirectoryWasEmpty: Bool
}

/// A `ProcessRunner` that records calls and returns a scripted result. No process is ever started.
public final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    public enum Script: Sendable {
        case output(ProcessOutput)
        case error(ProcessRunnerError)
        /// Suspends until the task is cancelled, then throws `CancellationError`.
        case waitForCancellation
    }

    private let lock = NSLock()
    private var _calls: [RecordedProcessCall] = []
    private var script: Script

    public init(_ script: Script) { self.script = script }

    public var calls: [RecordedProcessCall] { lock.lock(); defer { lock.unlock() }; return _calls }

    public func setScript(_ s: Script) { lock.lock(); script = s; lock.unlock() }

    private func record(_ call: RecordedProcessCall) -> Script {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
        return script
    }

    public func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
                    environment: [String: String], timeout: TimeInterval) async throws -> ProcessOutput {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
        let current = record(RecordedProcessCall(
            executable: executable, arguments: arguments, stdin: stdin, workingDirectory: workingDirectory,
            environment: environment, timeout: timeout, workingDirectoryWasEmpty: contents?.isEmpty == true))
        switch current {
        case .output(let o): return o
        case .error(let e): throw e
        case .waitForCancellation:
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
    }
}
