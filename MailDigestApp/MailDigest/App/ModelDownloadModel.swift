import Foundation
import MailDigestCore
import Observation

/// Downloads Ollama models, one per tag at a time. Owned by `DigestRunModel` so a download keeps going when
/// the Settings tab or window closes.
@MainActor @Observable
final class ModelDownloadModel {
    enum State: Equatable {
        case downloading(ModelPullProgress)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// Rises each time a download finishes, so views can refresh the installed list.
    private(set) var completedCount = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(previewStates: [String: State] = [:]) { states = previewStates }

    func state(for tag: String) -> State? { states[tag] }

    func start(tag: String, baseURL: URL) {
        guard tasks[tag] == nil else { return }
        states[tag] = .downloading(ModelPullProgress())
        tasks[tag] = Task {
            let puller = OllamaModelPuller(baseURL: baseURL)
            var final: State?
            do {
                try await puller.pull(tag: tag) { event in
                    await self.apply(event, to: tag)
                }
                if case .downloading(let progress)? = self.states[tag] {
                    switch progress.outcome {
                    case .succeeded: final = nil
                    case .failed(let message): final = .failed(message)
                    // The stream ended without success or an error line.
                    case .inProgress: final = .failed("The download stopped before it finished. Try again to resume.")
                    }
                }
            } catch is CancellationError {
                final = nil
            } catch let error as OllamaModelPuller.PullError {
                final = .failed(OllamaModelPuller.message(for: error))
            } catch {
                final = .failed("The download failed. Try again.")
            }
            self.finish(tag: tag, final: final)
        }
    }

    func cancel(tag: String) {
        // A cancelled pull leaves partial layers with Ollama; the next Download resumes them.
        tasks[tag]?.cancel()
    }

    private func apply(_ event: ModelPullEvent, to tag: String) {
        guard case .downloading(var progress)? = states[tag] else { return }
        progress.apply(event)
        states[tag] = .downloading(progress)
    }

    private func finish(tag: String, final: State?) {
        let succeeded: Bool
        if case .downloading(let progress)? = states[tag], progress.outcome == .succeeded { succeeded = true } else { succeeded = false }
        tasks[tag] = nil
        states[tag] = final
        if succeeded && final == nil { completedCount += 1 }
    }
}
