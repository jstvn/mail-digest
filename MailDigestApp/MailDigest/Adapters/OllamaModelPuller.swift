import Foundation
import MailDigestCore

/// Pulls a model through the local Ollama server's `POST /api/pull`, streaming progress. It contacts only the
/// base URL it is given (the configured Ollama URL). Cancelling the calling task closes the request; Ollama
/// keeps the layers it already has, so a later pull resumes.
struct OllamaModelPuller: Sendable {
    let baseURL: URL

    enum PullError: Error, Equatable {
        case unreachable
        case http(Int)
    }

    /// Calls `onEvent` for each decoded line. Returns normally when the stream ends; throws on a connection
    /// failure, a non-200 answer or task cancellation.
    func pull(tag: String, onEvent: @Sendable (ModelPullEvent) async -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": tag, "stream": true] as [String: Any])
        // This is an idle timeout, and Ollama sends nothing while it verifies a large model, so it must be long.
        // A stopped server still fails at once (connection refused). The resource timeout is the total-time limit.
        request.timeoutInterval = 900
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PullError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw PullError.unreachable }
        guard http.statusCode == 200 else { throw PullError.http(http.statusCode) }
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let event = ModelPullEvent.decode(line: line) { await onEvent(event) }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PullError.unreachable
        }
    }

    /// Plain-English text for a failed pull.
    static func message(for error: PullError) -> String {
        switch error {
        case .unreachable: return "Couldn't reach Ollama. Check that it is running, then try again."
        case .http(404): return "Ollama doesn't know this model. Check the model name."
        case .http(let status): return "Ollama couldn't start the download (HTTP \(status))."
        }
    }
}
