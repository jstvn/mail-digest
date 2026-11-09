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

    /// Wraps an already-open database (internal so migration tests can start from an older schema).
    init(writer: any DatabaseWriter) throws {
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
        // v3 (Q39, Q42): moved/kept emails and auto-file attempts, owned by their digest so retention removes
        // them with it. Separate from `processed_email`, which dedupe keeps forever.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE mail_disposition (
                    digest_id TEXT NOT NULL REFERENCES digest(id) ON DELETE CASCADE,
                    email_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    recorded_at REAL NOT NULL,
                    PRIMARY KEY (digest_id, email_id, kind)
                )
                """)
        }
        // v4 (Q56, Q57): a lightweight per-suggestion index so counts and paging never decode result JSON.
        // Back-filled from the stored results; `decided_at` stays NULL for history (never back-filled).
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE suggestion_ref (
                    suggestion_id TEXT PRIMARY KEY NOT NULL,
                    digest_id TEXT NOT NULL REFERENCES digest(id) ON DELETE CASCADE,
                    email_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    decided_at REAL
                );
                CREATE INDEX suggestion_ref_status_digest ON suggestion_ref (status, digest_id);
                CREATE INDEX suggestion_ref_digest_email ON suggestion_ref (digest_id, email_id);
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT digest_id, email_id, ordinal, suggestions FROM digest_email_result")
            for row in rows {
                // An undecodable payload is skipped rather than failing the migration; it already fails `digest(id:)`.
                guard let list = try? JSON.decode([Suggestion].self, row["suggestions"] as String) else { continue }
                try Self.writeRefs(db, digestID: row["digest_id"] as String, emailID: row["email_id"] as String,
                                   ordinal: row["ordinal"] as Int, suggestions: list)
            }
        }
        // v5 (T29): lifecycle times, per-item routing provenance, Activity paging indexes and the append-only
        // `job_event` log. Existing rows keep NULLs; nothing is back-filled.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                ALTER TABLE job ADD COLUMN started_at REAL;
                ALTER TABLE job ADD COLUMN ended_at REAL;
                CREATE INDEX job_created_id ON job (created_at, id);
                ALTER TABLE job_item ADD COLUMN started_at REAL;
                ALTER TABLE job_item ADD COLUMN routing TEXT;
                ALTER TABLE job_item ADD COLUMN provider TEXT;
                CREATE INDEX job_item_job_provider ON job_item (job_id, provider);
                CREATE TABLE job_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL REFERENCES job(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    at REAL NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}'
                );
                CREATE INDEX job_event_job_at ON job_event (job_id, at, id);
                """)
        }
        return migrator
    }

    /// Replaces the index rows of one result with those of `suggestions`. Runs inside the caller's transaction.
    private static func writeRefs(_ db: Database, digestID: String, emailID: String, ordinal: Int,
                                  suggestions: [Suggestion]) throws {
        try db.execute(sql: "DELETE FROM suggestion_ref WHERE digest_id = ? AND email_id = ?",
                       arguments: [digestID, emailID])
        for (position, s) in suggestions.enumerated() {
            // OR REPLACE: a duplicated suggestion id in damaged data must not abort the write.
            try db.execute(sql: """
                INSERT OR REPLACE INTO suggestion_ref
                    (suggestion_id, digest_id, email_id, ordinal, position, status, confidence, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [s.id.uuidString, digestID, emailID, ordinal, position, s.status.rawValue,
                                 s.confidence, s.decidedAt?.timeIntervalSince1970])
        }
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
        let results = EmailResult.results(from: digest)
        let rows = try results.map(ResultRow.init)
        try await writer.write { db in
            // Upsert (not REPLACE) so the digest keeps its row and its children are not cascade-deleted.
            try db.execute(sql: """
                INSERT INTO digest (id, created_at, headline) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET created_at = excluded.created_at, headline = excluded.headline
                """, arguments: [digest.id.uuidString, digest.createdAt.timeIntervalSince1970, digest.headline])
            try db.execute(sql: "DELETE FROM digest_email_result WHERE digest_id = ?", arguments: [digest.id.uuidString])
            try db.execute(sql: "DELETE FROM suggestion_ref WHERE digest_id = ?", arguments: [digest.id.uuidString])
            for (ordinal, row) in rows.enumerated() {
                try row.insert(db, digestID: digest.id, ordinal: ordinal)
                try Self.writeRefs(db, digestID: digest.id.uuidString, emailID: row.emailID, ordinal: ordinal,
                                   suggestions: results[ordinal].suggestions)
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
                try Self.writeRefs(db, digestID: digestID.uuidString, emailID: result.emailID, ordinal: ordinal,
                                   suggestions: result.suggestions)
            } else {
                let next = try Int.fetchOne(
                    db, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM digest_email_result WHERE digest_id = ?",
                    arguments: [digestID.uuidString]) ?? 0
                try row.insert(db, digestID: digestID, ordinal: next)
                try Self.writeRefs(db, digestID: digestID.uuidString, emailID: result.emailID, ordinal: next,
                                   suggestions: result.suggestions)
            }
        }
    }

    public func deleteEmailResults(_ emailIDs: Set<String>, from digestID: UUID) async throws {
        try await writer.write { db in
            for id in emailIDs {
                try db.execute(sql: "DELETE FROM digest_email_result WHERE digest_id = ? AND email_id = ?",
                               arguments: [digestID.uuidString, id])
                try db.execute(sql: "DELETE FROM suggestion_ref WHERE digest_id = ? AND email_id = ?",
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
                // Same transaction: only the changed suggestion's index row moves (status, confidence, decided_at).
                try db.execute(sql: """
                    UPDATE suggestion_ref SET status = ?, confidence = ?, decided_at = ? WHERE suggestion_id = ?
                    """, arguments: [suggestion.status.rawValue, suggestion.confidence,
                                     suggestion.decidedAt?.timeIntervalSince1970, idText])
                return
            }
        }
    }

    public func retainedDigests() async throws -> [Digest] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM digest ORDER BY created_at, rowid").map { try Self.aggregate(db, $0) }
        }
    }

    // MARK: Summaries and paging

    public func digestSummaries() async throws -> [DigestSummary] {
        try await writer.read { db in
            // Counts come from the index and the result table; no JSON column is selected.
            try Row.fetchAll(db, sql: """
                SELECT d.id, d.created_at, COALESCE(j.kind, 'daily') AS kind,
                    (SELECT COUNT(*) FROM digest_email_result r WHERE r.digest_id = d.id) AS emails,
                    (SELECT COUNT(*) FROM suggestion_ref s WHERE s.digest_id = d.id AND s.status = 'pending') AS pending,
                    (SELECT COUNT(*) FROM suggestion_ref s WHERE s.digest_id = d.id AND s.status = 'failed') AS failed
                FROM digest d LEFT JOIN job j ON j.id = d.id
                ORDER BY d.created_at DESC, d.rowid DESC
                """).map { row in
                DigestSummary(id: UUID(uuidString: row["id"]) ?? UUID(),
                              createdAt: Date(timeIntervalSince1970: row["created_at"]),
                              kind: JobKind(rawValue: row["kind"]) ?? .daily,
                              emailCount: row["emails"], pendingCount: row["pending"], failedCount: row["failed"])
            }
        }
    }

    public func actionableSuggestions(_ query: SuggestionQuery) async throws -> [SuggestionRecord] {
        guard query.limit > 0, query.kinds?.isEmpty != true else { return [] }
        return try await writer.read { db in
            var conditions = ["s.status IN ('pending', 'failed')"]
            var arguments = StatementArguments()
            if let kinds = query.kinds {
                conditions.append("COALESCE(j.kind, 'daily') IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
                arguments += StatementArguments(kinds.map(\.rawValue))
            }
            if let before = query.digestsCreatedBefore {
                conditions.append("d.created_at < ?")
                arguments += [before.timeIntervalSince1970]
            }
            arguments += [query.limit, max(0, query.offset)]
            return try Self.records(db, where: conditions.joined(separator: " AND "),
                                    order: "d.created_at DESC, d.rowid DESC, s.ordinal, s.position",
                                    arguments: arguments)
        }
    }

    public func decidedSuggestions(limit: Int, offset: Int) async throws -> [SuggestionRecord] {
        guard limit > 0 else { return [] }
        return try await writer.read { db in
            try Self.records(db, where: "s.status IN ('approved', 'dismissed')",
                             order: "COALESCE(s.decided_at, d.created_at) DESC, d.rowid DESC, s.ordinal, s.position",
                             arguments: [limit, max(0, offset)])
        }
    }

    /// Picks one page of suggestion ids from the index, then decodes only the result rows that hold them
    /// and reads each email's context from its `job_item`. `arguments` ends with limit and offset.
    private static func records(_ db: Database, where condition: String, order: String,
                                arguments: StatementArguments) throws -> [SuggestionRecord] {
        let refs = try Row.fetchAll(db, sql: """
            SELECT s.suggestion_id, s.digest_id, s.email_id, d.created_at, COALESCE(j.kind, 'daily') AS kind
            FROM suggestion_ref s JOIN digest d ON d.id = s.digest_id LEFT JOIN job j ON j.id = d.id
            WHERE \(condition) ORDER BY \(order) LIMIT ? OFFSET ?
            """, arguments: arguments)

        struct ResultKey: Hashable { var digestID: String; var emailID: String }
        struct Detail { var suggestions: [Suggestion]; var category: EmailCategory?; var email: EmailContext? }
        var details: [ResultKey: Detail] = [:]
        var out: [SuggestionRecord] = []
        for ref in refs {
            let key = ResultKey(digestID: ref["digest_id"], emailID: ref["email_id"])
            if details[key] == nil {
                guard let r = try Row.fetchOne(db, sql: """
                    SELECT info, suggestions FROM digest_email_result WHERE digest_id = ? AND email_id = ?
                    """, arguments: [key.digestID, key.emailID]) else { continue }
                let info = try (r["info"] as String?).map { try JSON.decode(InfoItem.self, $0) }
                // The lowest-position item wins, as when the review window builds its lookup.
                let email = try Row.fetchOne(db, sql: """
                    SELECT sender, subject, mailbox, received_at, mail_store_row_id FROM job_item
                    WHERE job_id = ? AND message_id = ? ORDER BY position LIMIT 1
                    """, arguments: [key.digestID, key.emailID]).map { row in
                    EmailContext(sender: row["sender"], subject: row["subject"],
                                 mailbox: try JSON.decode(MailboxRef.self, row["mailbox"] as String),
                                 receivedAt: Date(timeIntervalSince1970: row["received_at"]),
                                 storeRowID: row["mail_store_row_id"])
                }
                details[key] = Detail(suggestions: try JSON.decode([Suggestion].self, r["suggestions"] as String),
                                      category: info?.category, email: email)
            }
            guard let detail = details[key], let id = UUID(uuidString: ref["suggestion_id"]),
                  let s = detail.suggestions.first(where: { $0.id == id }) else { continue }
            out.append(SuggestionRecord(
                suggestion: s, digestID: UUID(uuidString: key.digestID) ?? UUID(),
                digestCreatedAt: Date(timeIntervalSince1970: ref["created_at"]),
                kind: JobKind(rawValue: ref["kind"]) ?? .daily,
                category: s.category ?? detail.category ?? .other, email: detail.email))
        }
        return out
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

    // MARK: Mail dispositions

    public func recordDispositions(_ dispositions: [MailDisposition]) async throws {
        guard !dispositions.isEmpty else { return }
        try await writer.write { db in
            for d in dispositions {
                // Checked up front so callers get the same error as `appendEmailResult`, not a constraint error.
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM digest WHERE id = ?)",
                                        arguments: [d.digestID.uuidString]) == true else {
                    throw DigestStoreError.digestNotFound(d.digestID)
                }
                try db.execute(sql: """
                    INSERT INTO mail_disposition (digest_id, email_id, kind, recorded_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(digest_id, email_id, kind) DO UPDATE SET recorded_at = excluded.recorded_at
                    """, arguments: [d.digestID.uuidString, d.emailID, d.kind.rawValue,
                                     d.recordedAt.timeIntervalSince1970])
            }
        }
    }

    public func removeDispositions(_ kind: MailDispositionKind, emailIDs: Set<String>, digestID: UUID) async throws {
        guard !emailIDs.isEmpty else { return }
        try await writer.write { db in
            for id in emailIDs {
                try db.execute(sql: "DELETE FROM mail_disposition WHERE digest_id = ? AND email_id = ? AND kind = ?",
                               arguments: [digestID.uuidString, id, kind.rawValue])
            }
        }
    }

    public func dispositions(digestID: UUID) async throws -> [MailDisposition] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mail_disposition WHERE digest_id = ? ORDER BY recorded_at",
                             arguments: [digestID.uuidString]).compactMap { row -> MailDisposition? in
                guard let kind = MailDispositionKind(rawValue: row["kind"]) else { return nil }
                return MailDisposition(digestID: digestID, emailID: row["email_id"], kind: kind,
                                       recordedAt: Date(timeIntervalSince1970: row["recorded_at"]))
            }
        }
    }

    // MARK: Retention

    public func apply(_ plan: RetentionPlan) async throws {
        try await writer.write { db in
            // Cascades remove each digest's results and dispositions and each job's items; processed ids and decisions have no
            // foreign key to either and are never touched (Q18, Q21).
            for id in plan.digestIDs { try db.execute(sql: "DELETE FROM digest WHERE id = ?", arguments: [id.uuidString]) }
            // Events cascade too; the explicit delete keeps retention correct even if foreign keys were off.
            for id in plan.jobIDs {
                try db.execute(sql: "DELETE FROM job_event WHERE job_id = ?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM job_item WHERE job_id = ?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [id.uuidString])
            }
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
        let created = JobEvent(jobID: job.id, kind: .created, at: job.createdAt)
        let payload = try JSON.encode(created.payload)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, kind, mailboxes, scope_from, scope_to, state, created_at,
                                 queued, done, failed, skipped, auto_paused, last_error, pause_reason,
                                 started_at, ended_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.jobArguments(job, mailboxes: mailboxes))
            try Self.insertEvent(db, created, payload: payload)
        }
    }

    public func updateJob(_ job: Job, event: JobEvent?) async throws {
        let mailboxes = try JSON.encode(job.mailboxes)
        let encoded = try event.map { (try JSON.encode($0.payload), $0) }
        try await writer.write { db in
            // Replaces by id; a missing job is ignored (with its event), as in the in-memory store.
            try db.execute(sql: """
                UPDATE job SET kind = ?2, mailboxes = ?3, scope_from = ?4, scope_to = ?5, state = ?6,
                    created_at = ?7, queued = ?8, done = ?9, failed = ?10, skipped = ?11, auto_paused = ?12,
                    last_error = ?13, pause_reason = ?14, started_at = ?15, ended_at = ?16
                WHERE id = ?1
                """, arguments: Self.jobArguments(job, mailboxes: mailboxes))
            if db.changesCount > 0, let (payload, event) = encoded {
                try Self.insertEvent(db, event, payload: payload)
            }
        }
    }

    private static func insertEvent(_ db: Database, _ event: JobEvent, payload: String) throws {
        try db.execute(sql: "INSERT INTO job_event (job_id, kind, at, payload) VALUES (?, ?, ?, ?)",
                       arguments: [event.jobID.uuidString, event.kind.rawValue, event.at.timeIntervalSince1970, payload])
    }

    private static func jobArguments(_ job: Job, mailboxes: String) -> StatementArguments {
        [job.id.uuidString, job.kind.rawValue, mailboxes, job.scopeFrom.timeIntervalSince1970,
         job.scopeTo.timeIntervalSince1970, job.state.rawValue, job.createdAt.timeIntervalSince1970,
         job.totals.queued, job.totals.done, job.totals.failed, job.totals.skipped, job.autoPaused, job.lastError,
         job.pauseReason?.rawValue, job.startedAt?.timeIntervalSince1970, job.endedAt?.timeIntervalSince1970]
    }

    public func jobEvents(job jobID: UUID) async throws -> [JobEvent] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job_event WHERE job_id = ? ORDER BY at, id",
                             arguments: [jobID.uuidString]).compactMap { row in
                // An unknown kind (written by a newer build) is dropped rather than shown as something it wasn't.
                guard let kind = JobEventKind(rawValue: row["kind"]) else { return nil }
                return JobEvent(id: row["id"], jobID: UUID(uuidString: row["job_id"]) ?? jobID,
                         kind: kind,
                         at: Date(timeIntervalSince1970: row["at"]),
                         payload: (try? JSON.decode(JobEventPayload.self, row["payload"] as String)) ?? .empty)
            }
        }
    }

    public func activityJobs(_ query: ActivityQuery) async throws -> [Job] {
        guard query.limit > 0 else { return [] }
        var clauses: [String] = []
        var args = StatementArguments()
        if let c = query.before {
            clauses.append("(created_at < ? OR (created_at = ? AND id < ?))")
            args += [c.createdAt.timeIntervalSince1970, c.createdAt.timeIntervalSince1970, c.id.uuidString]
        }
        if let kind = query.kind {
            clauses.append("kind = ?")
            args += [kind.rawValue]
        }
        if let path = query.path {
            clauses.append("EXISTS (SELECT 1 FROM job_item WHERE job_item.job_id = job.id AND job_item.provider = ?)")
            args += [path.rawValue]
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        args += [query.limit]
        let arguments = args
        return try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job \(whereSQL) ORDER BY created_at DESC, id DESC LIMIT ?",
                             arguments: arguments).map(Self.job)
        }
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
            pauseReason: (row["pause_reason"] as String?).flatMap(PauseReason.init(rawValue:)),
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: Queue

    public func enqueue(_ headers: [MessageHeader], job jobID: UUID) async throws {
        let encoded = try headers.map { try JSON.encode($0.mailboxRef) }
        try await writer.write { db in
            try Self.insertItems(db, headers, encodedMailboxes: encoded, jobID: jobID)
        }
    }

    /// Appends queued items after the job's last position. Runs inside the caller's transaction.
    private static func insertItems(_ db: Database, _ headers: [MessageHeader], encodedMailboxes: [String],
                                    jobID: UUID) throws {
        var position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) FROM job_item WHERE job_id = ?",
                                        arguments: [jobID.uuidString]) ?? 0
        for (h, mailbox) in zip(headers, encodedMailboxes) {
            position += 1
            try db.execute(sql: """
                INSERT INTO job_item (id, job_id, message_id, mailbox, mail_store_row_id, sender, subject,
                                      received_at, position, state, attempts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0)
                """, arguments: [UUID().uuidString, jobID.uuidString, h.id, mailbox, h.sourceReference.storeRowID,
                                 h.sender, h.subject, h.receivedAt.timeIntervalSince1970, position])
        }
    }

    public func applyResumeRefresh(_ refresh: QueueRefresh) async throws {
        let appendedMailboxes = try refresh.appended.map { try JSON.encode($0.mailboxRef) }
        let moves = try refresh.relocations.map { (try JSON.encode($0.mailbox), $0) }
        // One write transaction: GRDB rolls everything back if any statement throws.
        try await writer.write { db in
            for id in refresh.skippedItemIDs {
                try db.execute(sql: """
                    UPDATE job_item SET state = 'skipped', last_error = NULL, outcome = ?, seconds = 0,
                        finished_at = ? WHERE id = ? AND state IN ('queued', 'processing')
                    """, arguments: [refresh.skipOutcome, refresh.skippedAt.timeIntervalSince1970, id.uuidString])
            }
            for (json, move) in moves {
                try db.execute(sql: """
                    UPDATE job_item SET mailbox = ?, mail_store_row_id = ?
                    WHERE id = ? AND state IN ('queued', 'processing')
                    """, arguments: [json, move.storeRowID, move.itemID.uuidString])
            }
            try Self.insertItems(db, refresh.appended, encodedMailboxes: appendedMailboxes, jobID: refresh.jobID)
            if let scopeTo = refresh.scopeTo {
                try db.execute(sql: "UPDATE job SET scope_to = ? WHERE id = ?",
                               arguments: [scopeTo.timeIntervalSince1970, refresh.jobID.uuidString])
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

    public func isReservedFromBacklog(_ messageID: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM job_item i JOIN job j ON j.id = i.job_id
                    WHERE i.message_id = ? AND i.state IN ('queued', 'processing')
                      AND NOT (j.state = 'stopped' AND j.kind = 'backlog'))
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

    public func providers(job jobID: UUID) async throws -> [String: ExecutionProvider] {
        try await writer.read { db in
            var out: [String: ExecutionProvider] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT message_id, provider FROM job_item WHERE job_id = ? AND provider IS NOT NULL ORDER BY position",
                                        arguments: [jobID.uuidString])
            for row in rows {
                let id: String = row["message_id"]
                if out[id] == nil, let p = (row["provider"] as String?).flatMap(ExecutionProvider.init(rawValue:)) { out[id] = p }
            }
            return out
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
                storeRowID: row["mail_store_row_id"],
                startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                // An undecodable routing blob reads as "not recorded" rather than failing the whole list.
                routing: (row["routing"] as String?).flatMap { try? JSON.decode(RoutingProvenance.self, $0) },
                provider: (row["provider"] as String?).flatMap(ExecutionProvider.init(rawValue:)))
    }

    public func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?, startedAt: Date?) async throws {
        // Q22: only a genuine item error moving the item to queued/failed spends an attempt.
        let spendsAttempt = error != nil && (state == .queued || state == .failed)
        // The start time is written in the same statement as the move to `.processing`.
        let start = state == .processing ? startedAt?.timeIntervalSince1970 : nil
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE job_item SET state = ?, last_error = ?, attempts = attempts + ?,
                    started_at = COALESCE(?, started_at) WHERE id = ?
                """, arguments: [state.rawValue, error, spendsAttempt ? 1 : 0, start, itemID.uuidString])
        }
    }

    public func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date,
                                  routing: RoutingProvenance?) async throws {
        let encoded = try routing.map(JSON.encode)
        let provider = routing?.execution?.provider.rawValue
        try await writer.write { db in
            if let encoded {
                // Routing and provider land in the same statement as the outcome.
                try db.execute(sql: """
                    UPDATE job_item SET outcome = ?, seconds = ?, finished_at = ?, routing = ?, provider = ?
                    WHERE id = ?
                    """, arguments: [outcome, seconds, finishedAt.timeIntervalSince1970, encoded, provider,
                                     itemID.uuidString])
            } else {
                try db.execute(sql: "UPDATE job_item SET outcome = ?, seconds = ?, finished_at = ? WHERE id = ?",
                               arguments: [outcome, seconds, finishedAt.timeIntervalSince1970, itemID.uuidString])
            }
        }
    }

    public func recordAssessment(job jobID: UUID, messageID: String, routing: RoutingProvenance) async throws {
        let encoded = try JSON.encode(routing)
        try await writer.write { db in
            try db.execute(sql: "UPDATE job_item SET routing = ? WHERE job_id = ? AND message_id = ?",
                           arguments: [encoded, jobID.uuidString, messageID])
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
