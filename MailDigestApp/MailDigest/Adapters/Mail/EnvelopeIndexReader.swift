import Foundation
import MailDigestCore
import GRDB

/// Strictly read-only access to Apple Mail's `Envelope Index`. Each operation opens a short-lived
/// `DatabaseQueue`, validates the schema, queries with bound parameters and closes. Nothing here
/// writes, checkpoints or changes pragmas, and a `DatabasePool` is never used because it would
/// switch the journal mode.
struct EnvelopeIndexReader: Sendable {
    let databaseURL: URL
    /// How long SQLite waits on a lock before the operation fails as `.busy`.
    let busyTimeout: TimeInterval

    init(databaseURL: URL, busyTimeout: TimeInterval = 5) {
        self.databaseURL = databaseURL
        self.busyTimeout = busyTimeout
    }

    /// A mailbox with its live (not deleted) message counts.
    struct MailboxRow: Sendable, Equatable {
        var rowID: Int64
        var url: String
        var liveCount: Int
        var unreadCount: Int
    }

    /// One message row joined with its RFC Message-ID, mailbox URL, sender and subject.
    struct StoreRow: Sendable, Equatable {
        var rowID: Int64
        /// Raw `message_id_header`, usually with angle brackets.
        var messageIDHeader: String?
        var mailboxURL: String
        var address: String?
        var comment: String?
        var subjectPrefix: String?
        var subject: String?
        /// Unix seconds.
        var dateReceived: Double

        var canonicalMessageID: String? { messageIDHeader.flatMap(MessageID.canonical) }
        var receivedAt: Date { Date(timeIntervalSince1970: dateReceived) }

        /// `"comment <address>"`, or the bare address when there is no display name.
        var sender: String {
            let addr = address ?? ""
            let name = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return addr }
            return addr.isEmpty ? name : "\(name) <\(addr)>"
        }

        var fullSubject: String { (subjectPrefix ?? "") + (subject ?? "") }
    }

    // MARK: Operations

    /// Throws `.unsupportedSchema` unless every required table and column exists.
    func validateSchema() throws {
        try withDatabase { _ in () }
    }

    /// All mailbox rows with live message counts (unread counts when the `read` column exists).
    func mailboxes() throws -> [MailboxRow] {
        try withDatabase { db in
            let hasRead = try db.columns(in: "messages").contains { $0.name == "read" }
            let unread = hasRead ? #"COALESCE(SUM(CASE WHEN m."read" = 0 THEN 1 ELSE 0 END), 0)"# : "0"
            let sql = """
                SELECT mb.ROWID, mb.url, COUNT(m.ROWID), \(unread)
                FROM mailboxes mb
                LEFT JOIN messages m ON m.mailbox = mb.ROWID AND m.deleted = 0
                GROUP BY mb.ROWID, mb.url
                """
            return try Row.fetchAll(db, sql: sql).map {
                MailboxRow(rowID: $0[0], url: $0[1], liveCount: $0[2], unreadCount: $0[3])
            }
        }
    }

    /// Live messages of one mailbox received in `[from, to)`, newest first (ties by greater ROWID).
    func headers(mailboxURL: String, from: Date, to: Date) throws -> [StoreRow] {
        try query(where: "mb.url = ? AND m.deleted = 0 AND m.date_received >= ? AND m.date_received < ?",
                  arguments: [mailboxURL, from.timeIntervalSince1970, to.timeIntervalSince1970])
    }

    /// Live messages per local calendar day in `[from, to)` across the given mailboxes: one grouped COUNT over
    /// the index, so no subject, sender or body is read. Days follow the Mac's time zone (`localtime`).
    func dailyCounts(mailboxURLs: [String], from: Date, to: Date) throws -> [DayCount] {
        guard !mailboxURLs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: mailboxURLs.count).joined(separator: ", ")
        var arguments = StatementArguments(mailboxURLs)
        arguments += [from.timeIntervalSince1970, to.timeIntervalSince1970]
        let bound = arguments
        return try withDatabase { db in
            let sql = """
                SELECT date(m.date_received, 'unixepoch', 'localtime') AS day, COUNT(*)
                FROM messages m
                JOIN mailboxes mb ON mb.ROWID = m.mailbox
                WHERE mb.url IN (\(placeholders)) AND m.deleted = 0 AND m.date_received >= ? AND m.date_received < ?
                GROUP BY day
                """
            return try Row.fetchAll(db, sql: sql, arguments: bound).compactMap { row -> DayCount? in
                guard let text: String = row[0] else { return nil }
                let parts = text.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { return nil }
                return DayCount(day: DigestDay(year: parts[0], month: parts[1], day: parts[2]), count: row[1])
            }
        }
    }

    /// The live row with this ROWID, for verifying a stored locator hint.
    func row(rowID: Int64) throws -> StoreRow? {
        try query(where: "m.ROWID = ? AND m.deleted = 0", arguments: [rowID]).first
    }

    /// Live rows in one mailbox whose Message-ID header is `<id>` or `id`, newest first.
    func rows(messageID: String, mailboxURL: String) throws -> [StoreRow] {
        try query(where: "mb.url = ? AND m.deleted = 0 AND g.message_id_header IN (?, ?)",
                  arguments: [mailboxURL, "<\(messageID)>", messageID])
    }

    // MARK: Internals

    private func query(where clause: String, arguments: StatementArguments) throws -> [StoreRow] {
        try withDatabase { db in
            let sql = """
                SELECT m.ROWID, g.message_id_header, mb.url, a.address, a.comment,
                       m.subject_prefix, s.subject, COALESCE(m.date_received, 0)
                FROM messages m
                JOIN mailboxes mb ON mb.ROWID = m.mailbox
                LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
                LEFT JOIN addresses a ON a.ROWID = m.sender
                LEFT JOIN subjects s ON s.ROWID = m.subject
                WHERE \(clause)
                ORDER BY m.date_received DESC, m.ROWID DESC
                """
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                StoreRow(rowID: $0[0], messageIDHeader: $0[1], mailboxURL: $0[2], address: $0[3],
                         comment: $0[4], subjectPrefix: $0[5], subject: $0[6], dateReceived: $0[7])
            }
        }
    }

    private static let requiredColumns: [String: [String]] = [
        "messages": ["global_message_id", "sender", "subject_prefix", "subject", "date_received", "mailbox", "deleted"],
        "message_global_data": ["message_id_header"],
        "mailboxes": ["url"],
        "addresses": ["address", "comment"],
        "subjects": ["subject"],
    ]

    /// Opens read-only, validates the schema, runs `work`, then closes the connection.
    private func withDatabase<T>(_ work: (Database) throws -> T) throws -> T {
        // Distinguish "no Full Disk Access" from other open failures; SQLite reports both as CANTOPEN.
        if access(databaseURL.path, R_OK) != 0 {
            switch errno {
            case EPERM, EACCES: throw MailStoreError.permissionDenied
            case ENOENT: throw MailStoreError.notFound
            default: throw MailStoreError.other(errno)
            }
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        do {
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            return try queue.read { db in
                try Self.validate(db)
                return try work(db)
            }
        } catch let error as MailStoreError {
            throw error
        } catch let error as DatabaseError {
            throw Self.map(error)
        } catch {
            throw MailStoreError.from(error)
        }
    }

    private static func validate(_ db: Database) throws {
        for (table, required) in requiredColumns {
            guard try db.tableExists(table) else { throw MailStoreError.unsupportedSchema }
            let present = Set(try db.columns(in: table).map(\.name))
            guard present.isSuperset(of: required) else { throw MailStoreError.unsupportedSchema }
        }
    }

    private static func map(_ error: DatabaseError) -> MailStoreError {
        switch error.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED: return .busy
        case .SQLITE_PERM, .SQLITE_AUTH: return .permissionDenied
        case .SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_ERROR: return .unsupportedSchema
        default: return .other(error.extendedResultCode.rawValue)
        }
    }
}
