import Foundation
import GRDB
import MailDigestCore

/// SQLite-backed `DigestStore` (GRDB). Same semantics as `InMemoryDigestStore`, except that foreign keys are
/// enforced: items can only be queued for an existing job and results only appended to a saved digest.
///
/// Dates are stored as epoch seconds (REAL) so they round-trip exactly; UUIDs as upper-case text; nested
/// values as JSON text. Every multi-row write runs in one transaction.
public final class GRDBDigestStore: DigestStore, Sendable {
    /// A `DatabasePool` for files, a `DatabaseQueue` for `inMemory()`. Internal so tests can inspect it.
    let writer: any DatabaseWriter

    /// Opens (creating directories, the file and the schema if needed) the database at `path`, in WAL mode.
    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
        writer = pool
    }

    private init(writer: any DatabaseWriter) throws {
        try Self.migrator.migrate(writer)
        self.writer = writer
    }

    /// A throwaway in-memory database, for tests.
    public static func inMemory() throws -> GRDBDigestStore {
        try GRDBDigestStore(writer: DatabaseQueue())
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE processed_email (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    received_at REAL NOT NULL,
                    tier TEXT NOT NULL,
                    processed_at REAL NOT NULL
                );
                CREATE TABLE digest (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    headline TEXT NOT NULL
                );
                CREATE TABLE digest_email_result (
                    digest_id TEXT NOT NULL REFERENCES digest(id) ON DELETE CASCADE,
                    email_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    info TEXT,
                    suggestions TEXT NOT NULL,
                    skipped TEXT,
                    UNIQUE (digest_id, email_id)
                );
                CREATE INDEX digest_email_result_order ON digest_email_result (digest_id, ordinal);
                CREATE INDEX digest_email_result_email ON digest_email_result (email_id);
                CREATE TABLE decision (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    suggestion_id TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    action TEXT NOT NULL,
                    decided_at REAL NOT NULL
                );
                CREATE INDEX decision_sender ON decision (sender);
                CREATE TABLE job (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    mailboxes TEXT NOT NULL,
                    scope_from REAL NOT NULL,
                    scope_to REAL NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    queued INTEGER NOT NULL,
                    done INTEGER NOT NULL,
                    failed INTEGER NOT NULL,
                    skipped INTEGER NOT NULL,
                    auto_paused INTEGER NOT NULL,
                    last_error TEXT
                );
                CREATE TABLE job_item (
                    id TEXT PRIMARY KEY NOT NULL,
                    job_id TEXT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
                    message_id TEXT NOT NULL,
                    mailbox TEXT NOT NULL,
                    mail_store_row_id INTEGER,
                    sender TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    position INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    outcome TEXT,
                    seconds REAL,
                    attempts INTEGER NOT NULL,
                    last_error TEXT,
                    finished_at REAL
                );
                CREATE INDEX job_item_job_position ON job_item (job_id, position);
                CREATE INDEX job_item_message_state ON job_item (message_id, state);
                CREATE TABLE setting (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
        }
        // v2 (T19): why the app auto-paused a job. Nullable, so jobs stored by v1 simply have none.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE job ADD COLUMN pause_reason TEXT")
        }
        return migrator
    }

    // MARK: Runs and processed mail

    public func lastRunDate() async throws -> Date? {
        try await writer.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(created_at) FROM digest").map(Date.init(timeIntervalSince1970:))
        }
    }

    public func isProcessed(_ messageID: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM processed_email WHERE message_id = ?)",
                              arguments: [messageID]) ?? false
        }
    }

    public func markProcessed(_ email: ProcessedEmail) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO processed_email (message_id, received_at, tier, processed_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET
                    received_at = excluded.received_at, tier = excluded.tier, processed_at = excluded.processed_at
                """, arguments: [email.id, email.receivedAt.timeIntervalSince1970, email.tier.rawValue,
                                 email.processedAt.timeIntervalSince1970])
        }
    }

    // MARK: Digests and suggestions

    public func save(_ digest: Digest) async throws {
        // Encode before opening the transaction so an encoding failure cannot leave a half-written digest.
        let rows = try EmailResult.results(from: digest).map(ResultRow.init)
        try await writer.write { db in
            // Upsert (not REPLACE) so the digest keeps its row and its children are not cascade-deleted.
            try db.execute(sql: """
                INSERT INTO digest (id, created_at, headline) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET created_at = excluded.created_at, headline = excluded.headline
                """, arguments: [digest.id.uuidString, digest.createdAt.timeIntervalSince1970, digest.headline])
            try db.execute(sql: "DELETE FROM digest_email_result WHERE digest_id = ?", arguments: [digest.id.uuidString])
            for (ordinal, row) in rows.enumerated() {
                try row.insert(db, digestID: digest.id, ordinal: ordinal)
            }
        }
    }

    public func appendEmailResult(_ result: EmailResult, to digestID: UUID) async throws {
        let row = try ResultRow(result)
        try await writer.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM digest WHERE id = ?)",
                                           arguments: [digestID.uuidString]) ?? false
            guard exists else { throw DigestStoreError.digestNotFound(digestID) }
            if let ordinal = try Int.fetchOne(
                db, sql: "SELECT ordinal FROM digest_email_result WHERE digest_id = ? AND email_id = ?",
                arguments: [digestID.uuidString, result.emailID]) {
                try db.execute(sql: "DELETE FROM digest_email_result WHERE digest_id = ? AND email_id = ?",
                               arguments: [digestID.uuidString, result.emailID])
                try row.insert(db, digestID: digestID, ordinal: ordinal)
            } else {
                let next = try Int.fetchOne(
                    db, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM digest_email_result WHERE digest_id = ?",
                    arguments: [digestID.uuidString]) ?? 0
                try row.insert(db, digestID: digestID, ordinal: next)
            }
        }
    }

    public func deleteEmailResults(_ emailIDs: Set<String>, from digestID: UUID) async throws {
        try await writer.write { db in
            for id in emailIDs {
                try db.execute(sql: "DELETE FROM digest_email_result WHERE digest_id = ? AND email_id = ?",
                               arguments: [digestID.uuidString, id])
            }
        }
    }

    public func latestDigest() async throws -> Digest? {
        try await writer.read { db in
            // Ties go to the later-saved digest, like `Array.max` over insertion order.
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM digest ORDER BY created_at DESC, rowid DESC LIMIT 1")
            else { return nil }
            return try Self.aggregate(db, row)
        }
    }

    public func digest(id: UUID) async throws -> Digest? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM digest WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            return try Self.aggregate(db, row)
        }
    }

    private static func aggregate(_ db: Database, _ digestRow: Row) throws -> Digest {
        let idText: String = digestRow["id"]
        let results = try Row.fetchAll(db, sql: """
            SELECT email_id, info, suggestions, skipped FROM digest_email_result WHERE digest_id = ? ORDER BY ordinal
            """, arguments: [idText]).map(ResultRow.decode)
        return Digest(id: UUID(uuidString: idText) ?? UUID(),
                      createdAt: Date(timeIntervalSince1970: digestRow["created_at"]),
                      headline: digestRow["headline"], results: results)
    }

    public func recentSuggestions(since: Date) async throws -> [Suggestion] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.suggestions FROM digest_email_result r JOIN digest d ON d.id = r.digest_id
                WHERE d.created_at >= ? ORDER BY d.rowid, r.ordinal
                """, arguments: [since.timeIntervalSince1970])
                .flatMap { row -> [Suggestion] in
                    let text: String = row["suggestions"]
                    return try JSON.decode([Suggestion].self, text)
                }
        }
    }

    public func update(_ suggestion: Suggestion) async throws {
        try await writer.write { db in
            let idText = suggestion.id.uuidString
            // The suggestion's own email id normally names its result row; fall back to scanning for the id.
            var candidates = try Row.fetchAll(db, sql: """
                SELECT digest_id, email_id, suggestions FROM digest_email_result WHERE email_id = ?
                """, arguments: [suggestion.emailID])
            func holds(_ row: Row) throws -> Bool {
                try JSON.decode([Suggestion].self, row["suggestions"] as String).contains { $0.id == suggestion.id }
            }
            if try !candidates.contains(where: holds) {
                candidates = try Row.fetchAll(db, sql: """
                    SELECT digest_id, email_id, suggestions FROM digest_email_result WHERE instr(suggestions, ?) > 0
                    """, arguments: [idText])
            }
            for row in candidates {
                var list = try JSON.decode([Suggestion].self, row["suggestions"] as String)
                guard let i = list.firstIndex(where: { $0.id == suggestion.id }) else { continue }
                list[i] = suggestion
                try db.execute(sql: "UPDATE digest_email_result SET suggestions = ? WHERE digest_id = ? AND email_id = ?",
                               arguments: [try JSON.encode(list), row["digest_id"] as String, row["email_id"] as String])
                return
            }
        }
    }

    public func retainedDigests() async throws -> [Digest] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM digest ORDER BY created_at, rowid").map { try Self.aggregate(db, $0) }
        }
    }

    // MARK: Pinned info

    public func setPinned(_ pinned: Bool, infoID: String, digestID: UUID) async throws {
        try await writer.write { db in
            // Info ids equal email ids, so the result row is addressed directly; only its info payload changes.
            guard let text = try String.fetchOne(
                db, sql: "SELECT info FROM digest_email_result WHERE digest_id = ? AND email_id = ? AND info IS NOT NULL",
                arguments: [digestID.uuidString, infoID]) else { return }
            var item = try JSON.decode(InfoItem.self, text)
            item.pinned = pinned
            try db.execute(sql: "UPDATE digest_email_result SET info = ? WHERE digest_id = ? AND email_id = ?",
                           arguments: [try JSON.encode(item), digestID.uuidString, infoID])
        }
    }

    public func pinnedInfo() async throws -> [PinnedInfo] {
        try await writer.read { db in
            // The LIKE narrows the scan cheaply; decoding then decides exactly (sorted-key JSON writes `"pinned":true`).
            try Row.fetchAll(db, sql: """
                SELECT r.digest_id, r.info, d.created_at FROM digest_email_result r JOIN digest d ON d.id = r.digest_id
                WHERE r.info LIKE '%"pinned":true%' ORDER BY d.created_at DESC, d.rowid DESC, r.ordinal
                """).compactMap { row -> PinnedInfo? in
                    let item = try JSON.decode(InfoItem.self, row["info"] as String)
                    guard item.pinned, let id = UUID(uuidString: row["digest_id"]) else { return nil }
                    return PinnedInfo(item: item, digestID: id, digestCreatedAt: Date(timeIntervalSince1970: row["created_at"]))
                }
        }
    }

    // MARK: Retention

    public func apply(_ plan: RetentionPlan) async throws {
        try await writer.write { db in
            // Cascades remove each digest's results and each job's items; processed ids and decisions have no
            // foreign key to either and are never touched (Q18, Q21).
            for id in plan.digestIDs { try db.execute(sql: "DELETE FROM digest WHERE id = ?", arguments: [id.uuidString]) }
            for id in plan.jobIDs { try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [id.uuidString]) }
        }
    }

    // MARK: Decisions

    public func recordDecision(_ decision: Decision) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO decision (suggestion_id, sender, action, decided_at) VALUES (?, ?, ?, ?)
                """, arguments: [decision.suggestionID.uuidString, decision.sender, decision.action.rawValue,
                                 decision.decidedAt.timeIntervalSince1970])
        }
    }

    public func decisions(for sender: String) async throws -> [Decision] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM decision WHERE sender = ? ORDER BY id", arguments: [sender]).map {
                Decision(suggestionID: UUID(uuidString: $0["suggestion_id"]) ?? UUID(), sender: $0["sender"],
                         action: SuggestionStatus(rawValue: $0["action"]) ?? .pending,
                         decidedAt: Date(timeIntervalSince1970: $0["decided_at"]))
            }
        }
    }

    // MARK: Jobs

    public func createJob(_ job: Job) async throws {
        let mailboxes = try JSON.encode(job.mailboxes)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, kind, mailboxes, scope_from, scope_to, state, created_at,
                                 queued, done, failed, skipped, auto_paused, last_error, pause_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.jobArguments(job, mailboxes: mailboxes))
        }
    }

    public func updateJob(_ job: Job) async throws {
        let mailboxes = try JSON.encode(job.mailboxes)
        try await writer.write { db in
            // Replaces by id; a missing job is ignored, as in the in-memory store.
            try db.execute(sql: """
                UPDATE job SET kind = ?2, mailboxes = ?3, scope_from = ?4, scope_to = ?5, state = ?6,
                    created_at = ?7, queued = ?8, done = ?9, failed = ?10, skipped = ?11, auto_paused = ?12,
                    last_error = ?13, pause_reason = ?14
                WHERE id = ?1
                """, arguments: Self.jobArguments(job, mailboxes: mailboxes))
        }
    }

    private static func jobArguments(_ job: Job, mailboxes: String) -> StatementArguments {
        [job.id.uuidString, job.kind.rawValue, mailboxes, job.scopeFrom.timeIntervalSince1970,
         job.scopeTo.timeIntervalSince1970, job.state.rawValue, job.createdAt.timeIntervalSince1970,
         job.totals.queued, job.totals.done, job.totals.failed, job.totals.skipped, job.autoPaused, job.lastError,
         job.pauseReason?.rawValue]
    }

    public func jobs() async throws -> [Job] {
        try await writer.read { db in
            // Newest first; equal timestamps keep insertion order, like the in-memory store's stable sort.
            try Row.fetchAll(db, sql: "SELECT * FROM job ORDER BY created_at DESC, rowid ASC").map(Self.job)
        }
    }

    private static func job(_ row: Row) throws -> Job {
        Job(id: UUID(uuidString: row["id"]) ?? UUID(),
            kind: JobKind(rawValue: row["kind"]) ?? .backlog,
            mailboxes: try JSON.decode([MailboxRef].self, row["mailboxes"] as String),
            scopeFrom: Date(timeIntervalSince1970: row["scope_from"]),
            scopeTo: Date(timeIntervalSince1970: row["scope_to"]),
            state: JobState(rawValue: row["state"]) ?? .failed,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            totals: JobTotals(queued: row["queued"], done: row["done"], failed: row["failed"], skipped: row["skipped"]),
            autoPaused: row["auto_paused"], lastError: row["last_error"],
            pauseReason: (row["pause_reason"] as String?).flatMap(PauseReason.init(rawValue:)))
    }

    // MARK: Queue

    public func enqueue(_ headers: [MessageHeader], job jobID: UUID) async throws {
        let encoded = try headers.map { try JSON.encode($0.mailboxRef) }
        try await writer.write { db in
            var position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) FROM job_item WHERE job_id = ?",
                                            arguments: [jobID.uuidString]) ?? 0
            for (h, mailbox) in zip(headers, encoded) {
                position += 1
                try db.execute(sql: """
                    INSERT INTO job_item (id, job_id, message_id, mailbox, mail_store_row_id, sender, subject,
                                          received_at, position, state, attempts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0)
                    """, arguments: [UUID().uuidString, jobID.uuidString, h.id, mailbox, h.sourceReference.storeRowID,
                                     h.sender, h.subject, h.receivedAt.timeIntervalSince1970, position])
            }
        }
    }

    public func isQueued(_ messageID: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM job_item WHERE message_id = ? AND state IN ('queued', 'processing'))
                """, arguments: [messageID]) ?? false
        }
    }

    public func nextQueued(job jobID: UUID, limit: Int) async throws -> [JobItem] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM job_item WHERE job_id = ? AND state = 'queued' ORDER BY position LIMIT ?
                """, arguments: [jobID.uuidString, cap]).map(Self.item)
        }
    }

    public func items(job jobID: UUID) async throws -> [JobItem] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job_item WHERE job_id = ? ORDER BY position",
                             arguments: [jobID.uuidString]).map(Self.item)
        }
    }

    private static func item(_ row: Row) throws -> JobItem {
        JobItem(id: UUID(uuidString: row["id"]) ?? UUID(), jobID: UUID(uuidString: row["job_id"]) ?? UUID(),
                messageID: row["message_id"],
                mailbox: try JSON.decode(MailboxRef.self, row["mailbox"] as String),
                sender: row["sender"], subject: row["subject"],
                receivedAt: Date(timeIntervalSince1970: row["received_at"]),
                position: row["position"],
                state: JobItemState(rawValue: row["state"]) ?? .failed,
                outcome: row["outcome"], seconds: row["seconds"], attempts: row["attempts"],
                lastError: row["last_error"],
                finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                storeRowID: row["mail_store_row_id"])
    }

    public func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?) async throws {
        // Q22: only a genuine item error moving the item to queued/failed spends an attempt.
        let spendsAttempt = error != nil && (state == .queued || state == .failed)
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE job_item SET state = ?, last_error = ?, attempts = attempts + ? WHERE id = ?
                """, arguments: [state.rawValue, error, spendsAttempt ? 1 : 0, itemID.uuidString])
        }
    }

    public func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE job_item SET outcome = ?, seconds = ?, finished_at = ? WHERE id = ?",
                           arguments: [outcome, seconds, finishedAt.timeIntervalSince1970, itemID.uuidString])
        }
    }

    public func requeueFailed(job jobID: UUID) async throws -> [JobItem] {
        try await writer.write { db in
            let failed = try Row.fetchAll(db, sql: """
                SELECT * FROM job_item WHERE job_id = ? AND state = 'failed' ORDER BY position
                """, arguments: [jobID.uuidString]).map(Self.item)
            // Q28: back to queued with attempts reset and stale outcome/seconds/finish time cleared;
            // lastError stays for diagnostics.
            try db.execute(sql: """
                UPDATE job_item SET state = 'queued', attempts = 0, outcome = NULL, seconds = NULL, finished_at = NULL
                WHERE job_id = ? AND state = 'failed'
                """, arguments: [jobID.uuidString])
            return failed.map { item in
                var item = item
                item.state = .queued
                item.attempts = 0
                item.outcome = nil
                item.seconds = nil
                item.finishedAt = nil
                return item
            }
        }
    }

    public func requeueInterrupted() async throws -> Int {
        try await writer.write { db in
            try db.execute(sql: "UPDATE job_item SET state = 'queued' WHERE state = 'processing'")
            return db.changesCount
        }
    }

    // MARK: Settings

    /// The stored value for `key`, if any.
    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    /// Stores `value` for `key`, replacing any earlier value.
    public func setSetting(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }
}

// MARK: - Helpers

/// Stable JSON for nested values.
enum JSON {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// One `digest_email_result` row, with its payloads already encoded.
private struct ResultRow {
    var emailID: String
    var info: String?
    var suggestions: String
    var skipped: String?

    init(_ result: EmailResult) throws {
        emailID = result.emailID
        info = try result.info.map(JSON.encode)
        suggestions = try JSON.encode(result.suggestions)
        skipped = try result.skipped.map(JSON.encode)
    }

    func insert(_ db: Database, digestID: UUID, ordinal: Int) throws {
        try db.execute(sql: """
            INSERT INTO digest_email_result (digest_id, email_id, ordinal, info, suggestions, skipped)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [digestID.uuidString, emailID, ordinal, info, suggestions, skipped])
    }

    static func decode(_ row: Row) throws -> EmailResult {
        EmailResult(emailID: row["email_id"],
                    info: try (row["info"] as String?).map { try JSON.decode(InfoItem.self, $0) },
                    suggestions: try JSON.decode([Suggestion].self, row["suggestions"] as String),
                    skipped: try (row["skipped"] as String?).map { try JSON.decode(SkippedEmail.self, $0) })
    }
}
