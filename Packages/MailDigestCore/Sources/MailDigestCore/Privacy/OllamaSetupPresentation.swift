import Foundation

/// Text and symbol for onboarding's Ollama step, one per `OllamaSetupState` (Q92).
public struct OllamaSetupPresentation: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case ready, attention }

    public var symbol: String
    public var tone: Tone
    /// Short status label, also the VoiceOver label of the symbol.
    public var title: String
    public var message: String

    public init(symbol: String, tone: Tone, title: String, message: String) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.message = message
    }

    /// Wording for a state; `model` is the digest model tag.
    public static func make(for state: OllamaSetupState, model: String) -> OllamaSetupPresentation {
        switch state {
        case .notInstalled:
            return .init(symbol: "exclamationmark.triangle.fill", tone: .attention, title: "Ollama not installed",
                         message: "Ollama runs the summarising model on this Mac. Download and install it, then open it once.")
        case .notRunning:
            return .init(symbol: "exclamationmark.triangle.fill", tone: .attention, title: "Ollama not running",
                         message: "Ollama is installed but isn\u{2019}t running. Start it and Mail Digest will check again.")
        case .versionTooOld(let installed):
            return .init(symbol: "exclamationmark.triangle.fill", tone: .attention, title: "Ollama needs an update",
                         message: "Ollama \(installed) is too old. Update Ollama to the latest version.")
        case .modelMissing:
            return .init(symbol: "exclamationmark.triangle.fill", tone: .attention, title: "Model needed",
                         message: "Ollama needs the model \(model) to write summaries. Download it once; it stays on this Mac.")
        case .ready:
            return .init(symbol: "checkmark.circle.fill", tone: .ready, title: "Ready",
                         message: "Ollama and the model are ready.")
        }
    }

    /// Shown when Apple Intelligence is the provider, so the step needs no Ollama (Q100).
    public static let appleIntelligence = OllamaSetupPresentation(
        symbol: "checkmark.circle.fill", tone: .ready, title: "Ready",
        message: "Apple Intelligence will write summaries on this Mac.")
}

/// How long onboarding keeps re-checking after "Start Ollama" (Q92).
public struct OllamaStartPolling: Sendable, Equatable {
    public var interval: TimeInterval
    public var timeout: TimeInterval

    public init(interval: TimeInterval = 2, timeout: TimeInterval = 30) {
        self.interval = interval
        self.timeout = timeout
    }

    /// Keep polling while the server isn't reachable yet and the time budget remains. Any reachable
    /// state (including old version or missing model) ends polling because the user must act.
    public func shouldContinue(after state: OllamaSetupState, elapsed: TimeInterval) -> Bool {
        switch state {
        case .notInstalled, .notRunning: return elapsed + interval <= timeout
        case .versionTooOld, .modelMissing, .ready: return false
        }
    }
}
