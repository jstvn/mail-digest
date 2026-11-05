import Foundation

/// In-memory `MailSource` for tests and previews; also records calls so tests can assert batch sizes.
public actor FixtureMailSource: MailSource {
    private let messages: [EmailMessage]
    private let mailboxes: [MailboxInfo]
    /// Row-ID hints (by message id) reported in `listHeaders`, to exercise locator pass-through.
    private let storeRowIDs: [String: Int64]

    /// Ids requested per `fetchMessages` call, in call order.
    public private(set) var fetchCalls: [[String]] = []
    /// References requested per `fetchMessages` call, in call order (includes row-ID hints).
    public private(set) var fetchReferenceCalls: [[MailMessageReference]] = []
    /// Number of `listHeaders` calls.
    public private(set) var listCalls = 0
    /// Number of `checkForNewMail` calls.
    public private(set) var checkCalls = 0

    /// When `mailboxes` is nil they are derived from the messages.
    public init(messages: [EmailMessage], mailboxes: [MailboxInfo]? = nil,
                storeRowIDs: [String: Int64] = [:]) {
        self.storeRowIDs = storeRowIDs
        self.messages = messages
        self.mailboxes = mailboxes ?? Self.deriveMailboxes(from: messages)
    }

    private static func deriveMailboxes(from messages: [EmailMessage]) -> [MailboxInfo] {
        var order: [MailboxRef] = []
        var counts: [MailboxRef: Int] = [:]
        for m in messages {
            let ref = MailboxRef(account: m.account, name: m.mailbox)
            if counts[ref] == nil { order.append(ref) }
            counts[ref, default: 0] += 1
        }
        return order.map {
            MailboxInfo(ref: $0, messageCount: counts[$0] ?? 0, unreadCount: 0,
                        kind: $0.name == "Inbox" ? .inbox : .custom)
        }
    }

    public func checkForNewMail() async throws { checkCalls += 1 }

    public func listMailboxes() async throws -> [MailboxInfo] { mailboxes }

    public func listHeaders(in mailbox: MailboxRef, from: Date, to: Date) async throws -> [MessageHeader] {
        listCalls += 1
        return messages
            .filter { $0.account == mailbox.account && $0.mailbox == mailbox.name
                && $0.receivedAt >= from && $0.receivedAt < to }
            .sorted { $0.receivedAt > $1.receivedAt }
            .map { MessageHeader(id: $0.id, account: $0.account, mailbox: $0.mailbox,
                                 sender: $0.sender, subject: $0.subject, receivedAt: $0.receivedAt,
                                 sourceReference: MailMessageReference(messageID: $0.id, storeRowID: storeRowIDs[$0.id])) }
    }

    public func fetchMessages(references: [MailMessageReference], in mailbox: MailboxRef) async throws -> [EmailMessage] {
        let ids = references.map(\.messageID)
        fetchReferenceCalls.append(references)
        fetchCalls.append(ids)
        let byID = Dictionary(
            messages.filter { $0.account == mailbox.account && $0.mailbox == mailbox.name }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Builds a deterministic inbox of `count` messages, newest ending at `endingAt`, spread over `mailboxes`.
    public static func generatedInbox(count: Int, mailboxes: [MailboxRef], endingAt: Date,
                                      spacing: TimeInterval = 600) -> FixtureMailSource {
        let senders: [(String, Bool)] = [
            ("Sam Taylor <sam@example.com>", false), ("QUT Canvas <canvas@qut.edu.au>", false),
            ("Ray White <rent@raywhite.example>", false), ("Origin Energy <bills@origin.example>", false),
            ("AusPost <tracking@auspost.example>", false), ("Amazon <ship-confirm@amazon.example>", false),
            ("Alex Work <alex@work.example>", false), ("Jo <jo@example.org>", false),
            ("Bank <alerts@bank.example>", false), ("Events <invites@events.example>", false),
            ("Uni Library <library@qut.edu.au>", false), ("Mum <mum@example.net>", false),
            ("Dentist <reception@dentist.example>", false), ("Gym <hello@gym.example>", false),
            ("Daily News <newsletter@news.example>", true), ("Shop <no-reply@shop.example>", true),
            ("Weekly Digest <newsletter@digest.example>", true), ("Travel <no-reply@travel.example>", true),
            ("Tech Weekly <newsletter@techweekly.example>", true), ("Promo <no-reply@promo.example>", true),
        ]
        var out: [EmailMessage] = []
        out.reserveCapacity(count)
        for n in 0..<count {
            let (sender, bulk) = senders[n % senders.count]
            let box = mailboxes[n % mailboxes.count]
            out.append(EmailMessage(
                id: "gen-\(n)@fixture", account: box.account, mailbox: box.name, sender: sender,
                subject: "Message \(n)",
                receivedAt: endingAt.addingTimeInterval(-spacing * Double(n)),
                body: "Hello,\nThis is generated message \(n). Please reply by Friday.\nThanks",
                headers: bulk ? ["List-Unsubscribe": "<mailto:unsub@fixture.example>"] : [:]))
        }
        return FixtureMailSource(messages: out)
    }
}
