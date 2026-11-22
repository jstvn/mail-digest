import Foundation

/// What a finished child process produced.
public struct ProcessOutput: Sendable, Equatable {
    public var exitStatus: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitStatus: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Failures of running a process; cancellation is reported as `CancellationError` instead.
public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed
    case timedOut
}

/// Runs an external executable. Behind a protocol so Core tests never start a real process.
public protocol ProcessRunner: Sendable {
    /// Runs `executable`, feeds `stdin`, and returns the output. The process is terminated on timeout
    /// (`ProcessRunnerError.timedOut`) or when the calling task is cancelled (`CancellationError`).
    func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
             environment: [String: String], timeout: TimeInterval) async throws -> ProcessOutput
}

/// `ProcessRunner` backed by Foundation's `Process`.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
                    environment: [String: String], timeout: TimeInterval) async throws -> ProcessOutput {
        let job = ProcessJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A dedicated thread: the work blocks until the child exits, so keep it off the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try job.runBlocking(
                            executable: executable, arguments: arguments, stdin: stdin,
                            workingDirectory: workingDirectory, environment: environment, timeout: timeout))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// One process run, shared between the blocking worker and the cancellation handler.
private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var timedOut = false
    private var launched = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if launched, process.isRunning { process.terminate() }
    }

    private func expire() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
        if launched, process.isRunning { process.terminate() }
    }

    func runBlocking(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
                     environment: [String: String], timeout: TimeInterval) throws -> ProcessOutput {
        // Writing to a pipe whose reader has gone must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw ProcessRunnerError.launchFailed }
        launched = true
        lock.unlock()

        let timer = DispatchWorkItem { [self] in expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Drain both pipes concurrently so a full pipe never blocks the child.
        let group = DispatchGroup()
        let box = OutputBox()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, isOut: isOut)
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        timer.cancel()

        lock.lock()
        let wasCancelled = cancelled, wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw ProcessRunnerError.timedOut }
        let (out, err) = box.get()
        return ProcessOutput(exitStatus: process.terminationStatus, stdout: out, stderr: err)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(_ d: Data, isOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isOut { out = d } else { err = d }
    }
    func get() -> (Data, Data) {
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}
