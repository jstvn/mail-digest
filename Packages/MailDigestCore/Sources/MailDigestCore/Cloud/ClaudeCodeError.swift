import Foundation

/// Failures from running Claude Code. Values carry no email text and no process output.
/// Cancellation is not represented here: it propagates as `CancellationError`.
public enum ClaudeCodeError: Error, Sendable, Equatable {
    case notSignedIn
    case launchFailed
    case timedOut
    /// The CLI exited non-zero, or reported `is_error` for a reason other than being signed out.
    case processFailed
    case malformedResponse

    /// Stable short code for provenance.
    public var code: String {
        switch self {
        case .notSignedIn: return "notSignedIn"
        case .launchFailed: return "launchFailed"
        case .timedOut: return "timedOut"
        case .processFailed: return "processFailed"
        case .malformedResponse: return "malformedResponse"
        }
    }
}
