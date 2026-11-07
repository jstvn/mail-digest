import Foundation
import GRDB
import Testing
import MailDigestCore
@testable import MailDigestPersistence

@Suite struct GRDBDigestStoreTests {
    // MARK: Processed mail, decisions, settings

    @Test func processedAndDecisionsAndSettings() async throws {
        let store = try GRDBDigestStore.inMemory()
        #expect(try await store.lastRunDate() == nil)
        #expect(try await !store.isProcessed("m1"))
        try await store.markProcessed(ProcessedEmail(id: "m1", receivedAt: t0, tier: .full, processedAt: t0))
        try await store.markProcessed(ProcessedEmail(id: "m1", receivedAt: t0, tier: .infoOnly, processedAt: t0)) // upsert
        #expect(try await store.isProcessed("m1"))
        #expect(try await !store.isProcessed("m2"))

        let a = Decision(suggestionID: UUID(), sender: "a@x.com", action: .approved, decidedAt: t0)
        let b = Decision(suggestionID: UUID(), sender: "a@x.com", action: .dismissed, decidedAt: t0.addingTimeInterval(5.5))
        try await store.recordDecision(a)
        try await store.recordDecision(b)
        try await store.recordDecision(Decision(suggestionID: UUID(), sender: "b@x.com", action: .approved, decidedAt: t0))
        #expect(try await store.decisions(for: "a@x.com") == [a, b])
        #expect(try await store.decisions(for: "nobody@x.com").isEmpty)

        #expect(try store.setting("historyRetention") == nil)
        try store.setSetting("historyRetention", "ninetyDays")
        try store.setSetting("historyRetention", "thirtyDays")
        #expect(try store.setting("historyRetention") == "thirtyDays")
    }

    // MARK: Digests

    @Test func digestSaveAppendReplaceDeleteReconstruct() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        let s1 = makeSuggestion("a"), s2 = makeSuggestion("b")
        await #expect(throws: DigestStoreError.digestNotFound(d.id)) {
            try await store.appendEmailResult(EmailResult(emailID: "a"), to: d.id)
        }
        try await store.save(d)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [s1]), to: d.id)
        try await store.appendEmailResult(EmailResult(emailID: "b", info: makeInfo("b"), suggestions: [s2]), to: d.id)
        let skipped = SkippedEmail(id: "c", sender: "x", subject: "y", reason: "failed: boom")
        try await store.appendEmailResult(EmailResult(emailID: "c", skipped: skipped), to: d.id)

        var s1b = s1
        s1b.title = "changed"
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [s1b]), to: d.id)

        let got = try #require(await store.digest(id: d.id))
        #expect(got.emailCount == 3 && got.info.map(\.emailID) == ["a", "b"])
        #expect(got.suggestions == [s1b, s2]) // "a" kept its position; dates round-trip exactly
        #expect(got.skipped == [skipped] && got.headline == "h" && got.createdAt == t0)

        try await store.deleteEmailResults(["c", "a"], from: d.id)
        let after = try #require(await store.digest(id: d.id))
        #expect(after.emailCount == 1 && after.info.map(\.emailID) == ["b"] && after.skipped.isEmpty)
        #expect(try await store.digest(id: UUID()) == nil)
    }

    @Test func saveReplacesResultsAndKeepsOrder() async throws {
        let store = try GRDBDigestStore.inMemory()
        var d = makeDigest()
        d.info = [makeInfo("a"), makeInfo("b")]
        d.suggestions = [makeSuggestion("b")]
        d.emailCount = 99
        try await store.save(d)
        #expect(try await store.digest(id: d.id)?.emailCount == 2)
        d.info = [makeInfo("z")]
        d.suggestions = []
        d.headline = "new"
        try await store.save(d)
        let got = try #require(await store.digest(id: d.id))
        #expect(got.info.map(\.emailID) == ["z"] && got.suggestions.isEmpty && got.headline == "new")
    }

    @Test func latestLastRunRecentSuggestionsAndUpdate() async throws {
        let store = try GRDBDigestStore.inMemory()
        let old = makeDigest(at: t0.addingTimeInterval(-86_400), headline: "old"), new = makeDigest(at: t0, headline: "new")
        try await store.save(old)
        try await store.save(new)
        let s = makeSuggestion("a"), sOld = makeSuggestion("o")
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [s]), to: new.id)
        try await store.appendEmailResult(EmailResult(emailID: "o", suggestions: [sOld]), to: old.id)

        #expect(try await store.latestDigest()?.headline == "new")
        #expect(try await store.lastRunDate() == t0)
        #expect(try await store.recentSuggestions(since: t0) == [s])
        #expect(try await store.recentSuggestions(since: t0.addingTimeInterval(-90_000)).count == 2)
        #expect(try await store.recentSuggestions(since: t0.addingTimeInterval(1)).isEmpty)

        var edited = s
        edited.category = .finance
        edited.status = .approved
        edited.title = "Edited"
        try await store.update(edited)
        #expect(try await store.digest(id: new.id)?.suggestions == [edited])
        // A suggestion whose emailID does not name its result row is still found.
        var odd = sOld
        odd.emailID = "not-the-row"
        odd.title = "Odd"
        try await store.update(odd)
        #expect(try await store.digest(id: old.id)?.suggestions.first?.title == "Odd")
        // Unknown suggestions are ignored.
        try await store.update(makeSuggestion("nowhere"))
    }

    @Test func olderSuggestionWithoutCategoryStillDecodes() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        try await store.save(d)
        var s = makeSuggestion("a", category: nil)
        s.reminderID = "REM-1"
        try await store.appendEmailResult(EmailResult(emailID: "a", suggestions: [s]), to: d.id)
        let got = try #require(await store.digest(id: d.id)?.suggestions.first)
        #expect(got.category == nil && got.reminderID == "REM-1")
    }

    // MARK: Jobs and queue

    @Test func jobsRoundTripAndOrder() async throws {
        let store = try GRDBDigestStore.inMemory()
        var older = makeJob(at: t0.addingTimeInterval(-100))
        older.lastError = "Ollama is not reachable"
        older.autoPaused = true
        older.pauseReason = .quietHours
        let newer = makeJob(kind: .daily, at: t0)
        try await store.createJob(older)
        try await store.createJob(newer)
        #expect(try await store.jobs() == [newer, older])
        var changed = older
        changed.state = .failed
        changed.totals = JobTotals(queued: 1, done: 2, failed: 3, skipped: 4)
        changed.lastError = nil
        changed.pauseReason = nil
        try await store.updateJob(changed)
        #expect(try await store.jobs().last == changed)
        try await store.updateJob(makeJob()) // unknown id: ignored
        #expect(try await store.jobs().count == 2)
    }

    @Test func queueSemanticsAndAttemptRule() async throws {
        let store = try GRDBDigestStore.inMemory()
        let job = makeJob()
        try await store.createJob(job)
        try await store.enqueue([makeHeader("a", rowID: 11), makeHeader("b"), makeHeader("c", rowID: 33)], job: job.id)
        try await store.enqueue([makeHeader("d")], job: job.id)
        var items = try await store.items(job: job.id)
        #expect(items.map(\.position) == [1, 2, 3, 4] && items.map(\.messageID) == ["a", "b", "c", "d"])
        #expect(items.map(\.storeRowID) == [11, nil, 33, nil])
        #expect(items.allSatisfy { $0.mailbox == inbox && $0.state == .queued && $0.attempts == 0 })
        #expect(items[0].reference == MailMessageReference(messageID: "a", storeRowID: 11))
        #expect(try await store.isQueued("b"))
        #expect(try await store.nextQueued(job: job.id, limit: 2).map(\.messageID) == ["a", "b"])
        #expect(try await store.nextQueued(job: job.id, limit: 0).isEmpty)

        // Q22: starting an item does not spend an attempt; an item error that requeues or fails it does.
        try await store.setItemState(items[0].id, .processing, error: nil)
        #expect(try await store.isQueued("a"))
        try await store.setItemState(items[0].id, .queued, error: "malformed")
        try await store.setItemState(items[1].id, .done, error: nil)
        try await store.setItemState(items[2].id, .failed, error: "boom")
        try await store.recordItemOutcome(items[2].id, outcome: "failed: boom", seconds: 1.5, finishedAt: t0)
        items = try await store.items(job: job.id)
        #expect(items[0].attempts == 1 && items[0].lastError == "malformed" && items[0].state == .queued)
        let bQueued = try await store.isQueued("b")
        #expect(items[1].attempts == 0 && !bQueued)
        #expect(items[2].attempts == 1 && items[2].outcome == "failed: boom" && items[2].seconds == 1.5
                && items[2].finishedAt == t0)

        // Recovery: processing -> queued, without spending an attempt.
        try await store.setItemState(items[3].id, .processing, error: nil)
        #expect(try await store.requeueInterrupted() == 1)
        #expect(try await store.requeueInterrupted() == 0)
        #expect(try await store.items(job: job.id)[3].attempts == 0)

        // Retry failed: attempts reset, stale outcome cleared, lastError kept.
        let requeued = try await store.requeueFailed(job: job.id)
        #expect(requeued.map(\.messageID) == ["c"])
        let c = try await store.items(job: job.id)[2]
        #expect(c == requeued[0])
        #expect(c.state == .queued && c.attempts == 0 && c.outcome == nil && c.seconds == nil
                && c.finishedAt == nil && c.lastError == "boom")
        #expect(try await store.requeueFailed(job: job.id).isEmpty)
        #expect(try await store.nextQueued(job: job.id, limit: 10).map(\.messageID) == ["a", "c", "d"])
    }

    @Test func foreignKeysAreEnforced() async throws {
        let store = try GRDBDigestStore.inMemory()
        await #expect(throws: (any Error).self) { try await store.enqueue([makeHeader("a")], job: UUID()) }
    }

    // MARK: Parity with the in-memory store

    @Test func behavesLikeTheInMemoryStore() async throws {
        let grdb = try GRDBDigestStore.inMemory()
        let memory = InMemoryDigestStore()
        let stores: [any DigestStore] = [grdb, memory]
        let job = makeJob()
        let digest = makeDigest(id: job.id)
        let s = makeSuggestion("a")
        for store in stores {
            try await store.createJob(job)
            try await store.enqueue([makeHeader("a", rowID: 5), makeHeader("b")], job: job.id)
            try await store.save(digest)
            try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [s]), to: job.id)
            let items = try await store.items(job: job.id)
            try await store.setItemState(items[0].id, .done, error: nil)
            try await store.recordItemOutcome(items[0].id, outcome: "ok", seconds: 2, finishedAt: t0)
            try await store.setItemState(items[1].id, .failed, error: "x")
            _ = try await store.requeueFailed(job: job.id)
        }
        func normalised(_ items: [JobItem]) -> [JobItem] {
            items.map { var i = $0; i.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!; return i }
        }
        #expect(normalised(try await grdb.items(job: job.id)) == normalised(try await memory.items(job: job.id)))
        #expect(try await grdb.digest(id: job.id) == memory.digest(id: job.id))
        #expect(try await grdb.latestDigest() == memory.latestDigest())
        #expect(try await grdb.jobs() == memory.jobs())
    }

    // MARK: Retention

    @Test func retentionApplyDeletesPlannedRecordsOnly() async throws {
        let store = try GRDBDigestStore.inMemory()
        let old = t0.addingTimeInterval(-400 * 86_400)
        let expired = makeJob(state: .finished, at: old), pinned = makeJob(state: .finished, at: old)
        let paused = makeJob(state: .paused, at: old), recent = makeJob(state: .finished, at: t0)
        for job in [expired, pinned, paused, recent] {
            try await store.createJob(job)
            try await store.enqueue([makeHeader("m-\(job.id)")], job: job.id)
            try await store.save(makeDigest(id: job.id, at: job.createdAt))
            try await store.appendEmailResult(
                EmailResult(emailID: "m-\(job.id)", info: makeInfo("m-\(job.id)", pinned: job.id == pinned.id),
                            suggestions: [makeSuggestion("m-\(job.id)")]), to: job.id)
        }
        try await store.markProcessed(ProcessedEmail(id: "m-\(expired.id)", receivedAt: old, tier: .full, processedAt: old))
        try await store.recordDecision(Decision(suggestionID: UUID(), sender: "a@x.com", action: .approved, decidedAt: old))

        let policy = RetentionPolicy()
        var all: [Digest] = []
        for job in [expired, pinned, paused, recent] { all.append(try #require(await store.digest(id: job.id))) }
        let plan = policy.plan(retention: .ninetyDays, now: t0, digests: all, jobs: try await store.jobs())
        #expect(plan == RetentionPlan(digestIDs: [expired.id], jobIDs: [expired.id]))
        try await store.apply(plan)

        #expect(try await store.digest(id: expired.id) == nil)
        #expect(try await store.items(job: expired.id).isEmpty)
        #expect(Set(try await store.jobs().map(\.id)) == [pinned.id, paused.id, recent.id])
        // Pinned digest keeps its job and its job_item context; paused job keeps its queue.
        #expect(try await store.digest(id: pinned.id)?.info.first?.pinned == true)
        #expect(try await store.items(job: pinned.id).count == 1)
        #expect(try await store.items(job: paused.id).count == 1)
        #expect(try await store.isProcessed("m-\(expired.id)"))
        #expect(try await store.decisions(for: "a@x.com").count == 1)
        let rows = try await store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM digest_email_result") }
        #expect(rows == 3)

        // "Delete all": only the unpinned, terminal records go; the rest stays.
        var all2: [Digest] = []
        for id in [pinned.id, paused.id, recent.id] { all2.append(try #require(await store.digest(id: id))) }
        let wipe = policy.deleteAllPlan(digests: all2, jobs: try await store.jobs())
        try await store.apply(wipe)
        #expect(Set(try await store.jobs().map(\.id)) == [pinned.id, paused.id])
        #expect(try await store.digest(id: pinned.id) != nil)
        #expect(try await store.digest(id: paused.id) != nil)
        #expect(try await store.isProcessed("m-\(expired.id)"))
        #expect(try await store.decisions(for: "a@x.com").count == 1)
    }

    // MARK: Atomicity

    @Test func failedAppendLeavesNoPartialRow() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        try await store.save(d)
        try await store.appendEmailResult(EmailResult(emailID: "ok", info: makeInfo("ok")), to: d.id)
        try await store.appendEmailResult(EmailResult(emailID: "boom", info: makeInfo("boom")), to: d.id)
        // From now on inserting a row for "boom" fails inside the transaction.
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_boom BEFORE INSERT ON digest_email_result WHEN NEW.email_id = 'boom'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        var changed = makeInfo("boom")
        changed.summary = "changed"
        await #expect(throws: (any Error).self) {
            // Replacing deletes the old row before inserting; the failed insert must restore it.
            try await store.appendEmailResult(EmailResult(emailID: "boom", info: changed), to: d.id)
        }
        #expect(try await store.digest(id: d.id)?.info == [makeInfo("ok"), makeInfo("boom")])

        // `save` replaces many rows: a failure on a later one must keep the previous results and headline.
        var bad = d
        bad.headline = "should not stick"
        bad.info = [makeInfo("x"), makeInfo("boom")]
        await #expect(throws: (any Error).self) { try await store.save(bad) }
        let kept = try #require(await store.digest(id: d.id))
        #expect(kept.info.map(\.emailID) == ["ok", "boom"] && kept.headline == "h")
    }

    @Test func unencodableResultWritesNothing() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        try await store.save(d)
        var nan = makeSuggestion("a")
        nan.confidence = .nan // JSONEncoder rejects it
        await #expect(throws: (any Error).self) {
            try await store.appendEmailResult(EmailResult(emailID: "a", suggestions: [nan]), to: d.id)
        }
        #expect(try await store.digest(id: d.id)?.emailCount == 0)
    }

    // MARK: Files and migrations

    @Test func migratesAnEmptyFileCreatingDirectoriesAndReopens() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            let tables = try await store.writer.read {
                try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            }
            for expected in ["processed_email", "digest", "digest_email_result", "decision", "job", "job_item", "setting"] {
                #expect(tables.contains(expected), "\(expected)")
            }
            let mode = try await store.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
            let job = makeJob()
            try await store.createJob(job)
            try store.setSetting("k", "v")
            try await store.markProcessed(ProcessedEmail(id: "m", receivedAt: t0, tier: .full, processedAt: t0))
        }
        let reopened = try GRDBDigestStore(path: dir.databasePath)
        #expect(try await reopened.jobs().count == 1)
        #expect(try reopened.setting("k") == "v")
        #expect(try await reopened.isProcessed("m"))
        let applied = try await reopened.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == ["v1", "v2", "v3", "v4", "v5"])
    }

    @Test func stoppedStateAndPauseReasonSurviveReopen() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        var paused = makeJob(state: .paused, at: t0)
        paused.autoPaused = true
        paused.pauseReason = .battery
        let stopped = makeJob(state: .stopped, at: t0.addingTimeInterval(-10))
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            try await store.createJob(paused)
            try await store.createJob(stopped)
        }
        let reopened = try GRDBDigestStore(path: dir.databasePath)
        #expect(try await reopened.jobs() == [paused, stopped])
    }

    @Test func v1DatabaseUpgradesAndOldJobsHaveNoPauseReason() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir.databasePath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Build a database as v1 left it: apply only the first migration, then insert a job the old way.
        let queue = try DatabaseQueue(path: dir.databasePath)
        try GRDBDigestStore.migrator.migrate(queue, upTo: "v1")
        let old = makeJob(state: .paused)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, kind, mailboxes, scope_from, scope_to, state, created_at, queued, done, failed,
                                 skipped, auto_paused, last_error)
                VALUES (?, 'backlog', '[]', 0, 0, 'paused', 0, 1, 0, 0, 0, 1, NULL)
                """, arguments: [old.id.uuidString])
        }
        try queue.close()
        let store = try GRDBDigestStore(path: dir.databasePath)
        let job = try #require(try await store.jobs().first)
        #expect(job.state == .paused && job.autoPaused && job.pauseReason == nil)
    }

    // MARK: Pinned info

    @Test func pinRoundTripsAndOnlyTouchesTheInfoPayload() async throws {
        let store = try GRDBDigestStore.inMemory()
        let old = makeDigest(at: t0.addingTimeInterval(-86_400), headline: "old"), new = makeDigest(at: t0, headline: "new")
        try await store.save(old)
        try await store.save(new)
        let s = makeSuggestion("a")
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [s]), to: old.id)
        try await store.appendEmailResult(EmailResult(emailID: "b", info: makeInfo("b")), to: new.id)
        try await store.appendEmailResult(EmailResult(emailID: "c", info: makeInfo("c", pinned: true)), to: new.id)

        try await store.setPinned(true, infoID: "a", digestID: old.id)
        let pinned = try await store.pinnedInfo()
        #expect(pinned.map(\.item.emailID) == ["c", "a"])
        #expect(pinned.map(\.digestID) == [new.id, old.id])
        #expect(pinned.last?.digestCreatedAt == old.createdAt && pinned.last?.item.pinned == true)
        // Suggestions and ordering of the result are untouched.
        #expect(try await store.digest(id: old.id)?.suggestions == [s])

        try await store.setPinned(false, infoID: "a", digestID: old.id)
        try await store.setPinned(true, infoID: "missing", digestID: old.id)
        try await store.setPinned(true, infoID: "a", digestID: UUID())
        #expect(try await store.pinnedInfo().map(\.item.emailID) == ["c"])
        #expect(try await store.retainedDigests().map(\.headline) == ["old", "new"])
    }

    @Test func pinSurvivesReopen() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let d = makeDigest()
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            try await store.save(d)
            try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a")), to: d.id)
            try await store.setPinned(true, infoID: "a", digestID: d.id)
        }
        let reopened = try GRDBDigestStore(path: dir.databasePath)
        #expect(try await reopened.pinnedInfo().map(\.item.emailID) == ["a"])
        try await reopened.setPinned(false, infoID: "a", digestID: d.id)
        #expect(try await GRDBDigestStore(path: dir.databasePath).pinnedInfo().isEmpty)
    }

    // MARK: Mail dispositions (Q39, Q42)

    @Test func dispositionsRecordRemoveAndSurviveReopen() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let d = makeDigest()
        do {
            let store = try GRDBDigestStore(path: dir.databasePath)
            await #expect(throws: DigestStoreError.digestNotFound(d.id)) {
                try await store.recordDispositions([MailDisposition(digestID: d.id, emailID: "a", kind: .moved, recordedAt: t0)])
            }
            try await store.save(d)
            try await store.recordDispositions([
                MailDisposition(digestID: d.id, emailID: "a", kind: .moved, recordedAt: t0),
                MailDisposition(digestID: d.id, emailID: "a", kind: .autoFileAttempted, recordedAt: t0),
                MailDisposition(digestID: d.id, emailID: "b", kind: .kept, recordedAt: t0),
            ])
            // Upsert: recording the same (digest, email, kind) again keeps one row.
            try await store.recordDispositions([MailDisposition(digestID: d.id, emailID: "a", kind: .moved,
                                                                recordedAt: t0.addingTimeInterval(1))])
            // Saving the digest again (as the runner does for the headline) must not cascade them away.
            try await store.save(d)
        }
        let store = try GRDBDigestStore(path: dir.databasePath)
        var got = MailDispositions(try await store.dispositions(digestID: d.id))
        #expect(got == MailDispositions(moved: ["a"], kept: ["b"], autoFileAttempted: ["a"]))
        #expect(try await store.dispositions(digestID: d.id).count == 3)

        // Undo clears only the moved record.
        try await store.removeDispositions(.moved, emailIDs: ["a"], digestID: d.id)
        got = MailDispositions(try await store.dispositions(digestID: d.id))
        #expect(got == MailDispositions(moved: [], kept: ["b"], autoFileAttempted: ["a"]))
    }

    @Test func retentionDeletesDispositionsWithTheirDigestOnly() async throws {
        let store = try GRDBDigestStore.inMemory()
        let gone = makeJob(state: .finished), stopped = makeJob(state: .stopped)
        for job in [gone, stopped] {
            try await store.createJob(job)
            try await store.enqueue([makeHeader("m-\(job.id)")], job: job.id)
            try await store.save(makeDigest(id: job.id, at: job.createdAt))
            try await store.appendEmailResult(EmailResult(emailID: "m-\(job.id)", info: makeInfo("m-\(job.id)")), to: job.id)
            try await store.recordDispositions([MailDisposition(digestID: job.id, emailID: "m-\(job.id)", kind: .moved,
                                                                recordedAt: t0)])
            try await store.markProcessed(ProcessedEmail(id: "m-\(job.id)", receivedAt: t0, tier: .full, processedAt: t0))
        }
        let digests = [try #require(await store.digest(id: gone.id)), try #require(await store.digest(id: stopped.id))]
        let plan = RetentionPolicy().deleteAllPlan(digests: digests, jobs: try await store.jobs())
        // A stopped job is resumable, so it and its digest stay.
        #expect(plan == RetentionPlan(digestIDs: [gone.id], jobIDs: [gone.id]))
        try await store.apply(plan)
        #expect(try await store.dispositions(digestID: gone.id).isEmpty)
        #expect(try await store.dispositions(digestID: stopped.id).count == 1)
        #expect(try await store.items(job: stopped.id).count == 1)
        // Dedupe records are never removed by retention.
        #expect(try await store.isProcessed("m-\(gone.id)"))
        #expect(try await store.isProcessed("m-\(stopped.id)"))
    }

    @Test func v2DatabaseUpgradesToDispositions() async throws {
        let queue = try DatabaseQueue()
        try GRDBDigestStore.migrator.migrate(queue, upTo: "v2")
        try GRDBDigestStore.migrator.migrate(queue)
        let tables = try await queue.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(tables.contains("mail_disposition"))
    }

    @Test func resumeRefreshAppliesSkipsMovesAppendsAndScopeTogether() async throws {
        let store = try GRDBDigestStore.inMemory()
        let job = makeJob()
        try await store.createJob(job)
        try await store.enqueue([makeHeader("m1", rowID: 7), makeHeader("m2", rowID: 8), makeHeader("m3", rowID: 9)],
                                job: job.id)
        let items = try await store.items(job: job.id)
        try await store.setItemState(items[2].id, .done, error: nil)
        let archive = MailboxRef(account: "iCloud", name: "Archive", accountID: "A1", mailboxURL: "imap://A1/Archive")
        let at = Date(timeIntervalSince1970: 5000)
        let newScope = Date(timeIntervalSince1970: 9000)

        try await store.applyResumeRefresh(QueueRefresh(
            jobID: job.id,
            // m3 is done: an attempt to skip or move it is ignored.
            skippedItemIDs: [items[0].id, items[2].id], skipOutcome: "gone", skippedAt: at,
            relocations: [.init(itemID: items[1].id, mailbox: archive, storeRowID: 42),
                          .init(itemID: items[2].id, mailbox: archive, storeRowID: 1)],
            appended: [makeHeader("m4", rowID: 10)], scopeTo: newScope))

        let after = try await store.items(job: job.id)
        #expect(after.count == 4)
        #expect(after[0].state == .skipped && after[0].outcome == "gone" && after[0].finishedAt == at
            && after[0].attempts == 0 && after[0].lastError == nil)
        #expect(after[1].mailbox == archive && after[1].storeRowID == 42 && after[1].state == .queued)
        #expect(after[2] == items[2].with(state: .done))
        #expect(after[3].messageID == "m4" && after[3].position == 4 && after[3].state == .queued)
        #expect(try await store.jobs().first?.scopeTo == newScope)
        #expect(try await store.jobs().first?.scopeFrom == job.scopeFrom)
    }
}

private extension JobItem {
    func with(state: JobItemState) -> JobItem { var copy = self; copy.state = state; return copy }
}
