import Foundation
import GRDB
import Testing
import MailDigestCore
@testable import MailDigestPersistence

/// T29: migration v5 and the SQLite-specific guarantees (atomic events, cascade).
@Suite struct JobProvenanceMigrationTests {
    @Test func v4DatabaseMigratesKeepingRowsWithNullsAndNoEvents() async throws {
        let queue = try DatabaseQueue()
        try GRDBDigestStore.migrator.migrate(queue, upTo: "v4")
        let jobID = UUID(), itemID = UUID()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, kind, mailboxes, scope_from, scope_to, state, created_at, queued, done, failed,
                                 skipped, auto_paused, last_error)
                VALUES (?, 'backlog', '[]', 0, 0, 'finished', ?, 0, 1, 0, 0, 0, NULL)
                """, arguments: [jobID.uuidString, t0.timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO job_item (id, job_id, message_id, mailbox, sender, subject, received_at, position, state,
                                      attempts, outcome, seconds, finished_at)
                VALUES (?, ?, 'm', ?, 's', 'x', ?, 1, 'done', 1, 'ok', 2, ?)
                """, arguments: [itemID.uuidString, jobID.uuidString, try JSON.encode(inbox), t0.timeIntervalSince1970,
                                 t0.timeIntervalSince1970])
        }
        let store = try GRDBDigestStore(writer: queue)
        let job = try #require(try await store.jobs().first)
        #expect(job.id == jobID && job.state == .finished && job.startedAt == nil && job.endedAt == nil)
        let item = try #require(try await store.items(job: jobID).first)
        #expect(item.id == itemID && item.outcome == "ok" && item.startedAt == nil && item.routing == nil && item.provider == nil)
        #expect(try await store.jobEvents(job: jobID).isEmpty)
        let events = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM job_event") }
        #expect(events == 0)
        // The old row is a normal participant afterwards.
        #expect(try await store.activityJobs(ActivityQuery()).map(\.id) == [jobID])
    }

    @Test func eventAndStateChangeRollBackTogether() async throws {
        let store = try GRDBDigestStore.inMemory()
        let job = makeJob()
        try await store.createJob(job)
        // Make the event insert fail after the job UPDATE has already run in the same transaction.
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_event BEFORE INSERT ON job_event WHEN NEW.kind = 'stopped'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        var stopped = job
        stopped.state = .stopped
        stopped.endedAt = t0
        await #expect(throws: (any Error).self) {
            try await store.updateJob(stopped, event: JobEvent(jobID: job.id, kind: .stopped, at: t0))
        }
        let after = try #require(try await store.jobs().first)
        #expect(after.state == .running && after.endedAt == nil)
        #expect(try await store.jobEvents(job: job.id).map(\.kind) == [.created])
    }

    @Test func foreignKeysAreEnforcedAndDeletingAJobCascadesEvents() async throws {
        let store = try GRDBDigestStore.inMemory()
        let enforced = try await store.writer.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enforced == true)
        let job = makeJob()
        try await store.createJob(job)
        // Cascade relies on the FK, independent of the explicit delete in `apply`.
        try await store.writer.write { try $0.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [job.id.uuidString]) }
        let left = try await store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM job_event") }
        #expect(left == 0)
    }

    @Test func routingColumnHoldsJSONAndProviderIsPlainText() async throws {
        let store = try GRDBDigestStore.inMemory()
        let job = makeJob()
        try await store.createJob(job)
        try await store.enqueue([makeHeader("a")], job: job.id)
        let item = try #require(try await store.items(job: job.id).first)
        let routing = RoutingProvenance(
            assessment: PrivacyAssessment(verdict: .private, method: .rule, ruleID: "kw.otp", assessedAt: t0),
            execution: ExecutionRecord(provider: .local, model: "qwen3:4b", cloudAttempted: false,
                                       localReason: .privateContent, startedAt: t0, finishedAt: t0))
        try await store.recordItemOutcome(item.id, outcome: "ok", seconds: 1, finishedAt: t0, routing: routing)
        let row = try await store.writer.read { try Row.fetchOne($0, sql: "SELECT routing, provider FROM job_item") }
        #expect(row?["provider"] as String? == "local")
        let json = try #require(row?["routing"] as String?)
        #expect(try JSON.decode(RoutingProvenance.self, json) == routing)
        #expect(json.contains("\"schemaVersion\":1"))
    }
}
