import Foundation

/// Per-message outcome of a Mail action; kept so the action can be undone.
public struct MailActionResult: Codable, Sendable, Equatable {
    public var messageID: String
    public var account: String
    public var originalMailbox: String
    public var succeeded: Bool
    public var error: String?

    public init(messageID: String, account: String, originalMailbox: String, succeeded: Bool, error: String?) {
        self.messageID = messageID
        self.account = account
        self.originalMailbox = originalMailbox
        self.succeeded = succeeded
        self.error = error
    }
}
