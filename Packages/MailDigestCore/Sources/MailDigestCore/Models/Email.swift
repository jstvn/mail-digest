import Foundation

/// Identity plus a private locator for a message. `messageID` is the only identity;
/// `storeRowID` is a hint for finding the file quickly and must never be used for identity.
public struct MailMessageReference: Codable, Sendable, Equatable, Hashable {
    public var messageID: String
    public var storeRowID: Int64?

    public init(messageID: String, storeRowID: Int64? = nil) {
        self.messageID = messageID
        self.storeRowID = storeRowID
    }
}

/// How much of a message's content was actually read (Q66). Anything but `.complete` fails closed.
public enum ContentInspection: String, Codable, Sendable, Equatable {
    case complete, uninspectedParts, unknown
}

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
    public var sourceReference: MailMessageReference
    /// Defaults to `.unknown` so fixtures and older callers fail closed.
    public var contentInspection: ContentInspection

    public init(id: String, account: String, mailbox: String, sender: String, subject: String,
                receivedAt: Date, body: String, headers: [String: String],
                sourceReference: MailMessageReference? = nil,
                contentInspection: ContentInspection = .unknown) {
        self.contentInspection = contentInspection
        self.sourceReference = sourceReference ?? MailMessageReference(messageID: id, storeRowID: nil)
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.body = body
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case id, account, mailbox, sender, subject, receivedAt, body, headers, sourceReference, contentInspection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(id: id, account: try c.decode(String.self, forKey: .account),
                  mailbox: try c.decode(String.self, forKey: .mailbox),
                  sender: try c.decode(String.self, forKey: .sender),
                  subject: try c.decode(String.self, forKey: .subject),
                  receivedAt: try c.decode(Date.self, forKey: .receivedAt),
                  body: try c.decode(String.self, forKey: .body),
                  headers: try c.decode([String: String].self, forKey: .headers),
                  sourceReference: try c.decodeIfPresent(MailMessageReference.self, forKey: .sourceReference),
                  contentInspection: try c.decodeIfPresent(ContentInspection.self, forKey: .contentInspection) ?? .unknown)
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
    public var sourceReference: MailMessageReference
    public var accountID: String?
    public var mailboxURL: String?

    /// The mailbox this header was listed from, including its on-disk locator when known.
    public var mailboxRef: MailboxRef {
        MailboxRef(account: account, name: mailbox, accountID: accountID, mailboxURL: mailboxURL)
    }

    public init(id: String, account: String, mailbox: String, sender: String, subject: String, receivedAt: Date,
                sourceReference: MailMessageReference? = nil, accountID: String? = nil, mailboxURL: String? = nil) {
        self.sourceReference = sourceReference ?? MailMessageReference(messageID: id, storeRowID: nil)
        self.accountID = accountID
        self.mailboxURL = mailboxURL
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, account, mailbox, sender, subject, receivedAt, sourceReference, accountID, mailboxURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  account: try c.decode(String.self, forKey: .account),
                  mailbox: try c.decode(String.self, forKey: .mailbox),
                  sender: try c.decode(String.self, forKey: .sender),
                  subject: try c.decode(String.self, forKey: .subject),
                  receivedAt: try c.decode(Date.self, forKey: .receivedAt),
                  sourceReference: try c.decodeIfPresent(MailMessageReference.self, forKey: .sourceReference),
                  accountID: try c.decodeIfPresent(String.self, forKey: .accountID),
                  mailboxURL: try c.decodeIfPresent(String.self, forKey: .mailboxURL))
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
