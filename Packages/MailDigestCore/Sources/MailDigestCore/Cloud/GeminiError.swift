import Foundation

/// Failures from the Gemini API. Values carry no server text and never the key.
/// Cancellation is not represented here: it propagates as `CancellationError`.
public enum GeminiError: Error, Sendable, Equatable {
    case invalidCredential
    case rateLimited
    case modelUnavailable
    case server(Int)
    case timedOut
    case network
    case blocked
    case malformedResponse

    /// Stable short code for provenance.
    public var code: String {
        switch self {
        case .invalidCredential: return "invalidCredential"
        case .rateLimited: return "rateLimited"
        case .modelUnavailable: return "modelUnavailable"
        case .server(let s): return "server\(s)"
        case .timedOut: return "timedOut"
        case .network: return "network"
        case .blocked: return "blocked"
        case .malformedResponse: return "malformedResponse"
        }
    }
}
