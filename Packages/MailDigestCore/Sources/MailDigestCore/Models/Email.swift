import Foundation

/// A full message as fetched from Mail, with body and the few headers the filter needs.
public struct EmailMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // RFC Message-ID without angle brackets
    public var account: String
    public var mailbox: String
    public var sender: String          // "Name <addr>"
    public var subject: String
    public var receivedAt: Date
    public var body: String            // plain text as Mail renders it
    public var headers: [String: String] // only List-Unsubscribe, Precedence, Auto-Submitted

    public init(id: String, account: String, mailbox: String, sender: String, subject: String,
                receivedAt: Date, body: String, headers: [String: String]) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.body = body
        self.headers = headers
    }
}

/// Cheap metadata for a message, listed before any body is fetched.
public struct MessageHeader: Codable, Sendable, Equatable {
    public var id: String
    public var account: String
    public var mailbox: String
    public var sender: String
    public var subject: String
    public var receivedAt: Date

    public init(id: String, account: String, mailbox: String, sender: String, subject: String, receivedAt: Date) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
    }
}

/// How much model work an email gets.
public enum MailTier: String, Codable, Sendable, Equatable { case skip, infoOnly, full }

/// A row of the `processed_email` table; dedupes mail across runs.
public struct ProcessedEmail: Codable, Sendable, Equatable {
    public var id: String
    public var receivedAt: Date
    public var tier: MailTier
    public var processedAt: Date

    public init(id: String, receivedAt: Date, tier: MailTier, processedAt: Date) {
        self.id = id
        self.receivedAt = receivedAt
        self.tier = tier
        self.processedAt = processedAt
    }
}
