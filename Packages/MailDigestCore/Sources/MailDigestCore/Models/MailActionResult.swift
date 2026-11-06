import Foundation

/// Per-message outcome of a Mail action; kept so the action can be undone.
public struct MailActionResult: Codable, Sendable, Equatable {
    public var messageID: String
    public var account: String
    public var originalMailbox: String
    public var succeeded: Bool
    public var error: String?
    /// Where the message was put (the account's Trash or the digest folder), as a path joined with "/".
    /// Undo searches here, because Mail gives a moved message a new id. Nil for failures and older data.
    public var destinationMailbox: String?

    public init(messageID: String, account: String, originalMailbox: String, succeeded: Bool, error: String?,
                destinationMailbox: String? = nil) {
        self.destinationMailbox = destinationMailbox
        self.messageID = messageID
        self.account = account
        self.originalMailbox = originalMailbox
        self.succeeded = succeeded
        self.error = error
    }
}

/// Plain failure reasons used in `MailActionResult.error`, so the UI can recognise them.
public enum MailActionFailure {
    public static let notFound = "not found"
    public static let ambiguous = "ambiguous"
    public static let mailNotRunning = "Mail isn't running"
    public static let automationDenied = "Mail automation denied"
    public static let timedOut = "Mail didn't respond"

    /// A short, user-facing sentence for a failure reason.
    public static func explanation(for reason: String?) -> String {
        switch reason {
        case notFound?: return "Not found in Mail (it may have been moved or deleted)."
        case ambiguous?: return "More than one matching email in that mailbox, so none was touched."
        case mailNotRunning?: return "Mail isn't running."
        case automationDenied?: return "Mail Digest isn't allowed to control Mail."
        case timedOut?: return "Mail didn't respond in time. Check Mail before trying again."
        case let other?: return other.prefix(1).uppercased() + other.dropFirst() + "."
        case nil: return "Unknown problem."
        }
    }
}

/// Thrown by `MailActions.restore` when some messages could not be put back; the rest were restored.
public enum MailActionError: Error, Sendable, Equatable {
    case restoreFailed([RestoreFailure])
}

/// One message an undo could not restore, and why.
public struct RestoreFailure: Sendable, Equatable {
    public var messageID: String
    public var reason: String

    public init(messageID: String, reason: String) {
        self.messageID = messageID
        self.reason = reason
    }
}
