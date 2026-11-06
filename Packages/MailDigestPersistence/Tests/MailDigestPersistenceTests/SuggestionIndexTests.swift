import Foundation
import GRDB
import Testing
import MailDigestCore
@testable import MailDigestPersistence

private func sug(_ email: String, _ status: SuggestionStatus = .pending, decided: Date? = nil,
                 category: EmailCategory? = .work, title: String = "Task") -> Suggestion {
    var s = makeSuggestion(email, title: title, category: category)
    s.status = status
    s.decidedAt = decided
    return s
}

private let day: TimeInterval = 86_400

/// A fixture used against both stores: a daily digest, a backlog digest with a job, and one without a job.
private struct Fixture {
    let daily = makeJob(kind: .daily, state: .finished, at: t0)
    let backlog = makeJob(kind: .backlog, state: .finished, at: t0.addingTimeInterval(-day))
    let orphan = makeDigest(at: t0.addingTimeInterval(-2 * day))
    // Suggestions are created once so both stores see the same ids.
    let a1 = sug("a", .pending), a2 = sug("a", .failed), b1 = sug("b", .approved, decided: t0.addingTimeInterval(100)),
        b2 = sug("b", .dismissed), c1 = sug("c", .pending, category: nil), o1 = sug("o", .dismissed, decided: t0.addingTimeInterval(-day))

    func load(into store: any DigestStore) async throws {
        try await store.createJob(daily)
        try await store.createJob(backlog)
        try await store.enqueue([makeHeader("a", rowID: 11), makeHeader("b")], job: daily.id)
        try await store.enqueue([makeHeader("c")], job: backlog.id)
        try await store.save(makeDigest(id: daily.id, at: t0))
        try await store.save(makeDigest(id: backlog.id, at: t0.addingTimeInterval(-day)))
        try await store.save(orphan)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [a1, a2]), to: daily.id)
        try await store.appendEmailResult(EmailResult(emailID: "b", info: makeInfo("b"), suggestions: [b1, b2]), to: daily.id)
        try await store.appendEmailResult(EmailResult(emailID: "c", info: makeInfo("c"), suggestions: [c1]), to: backlog.id)
        try await store.appendEmailResult(EmailResult(emailID: "o", suggestions: [o1]), to: orphan.id)
    }
}

@Suite struct SuggestionIndexTests {
    @Test func summariesCountPendingFailedAndEmails() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)
        let summaries = try await store.digestSummaries()
        #expect(summaries.map(\.id) == [f.daily.id, f.backlog.id, f.orphan.id])
        #expect(summaries.map(\.kind) == [.daily, .backlog, .daily]) // no job row -> daily
        #expect(summaries.map(\.emailCount) == [2, 1, 1])
        #expect(summaries.map(\.pendingCount) == [1, 1, 0])
        #expect(summaries.map(\.failedCount) == [1, 0, 0])
        for s in summaries {
            let digest = try #require(await store.digest(id: s.id))
            #expect(digest.emailCount == s.emailCount)
        }
    }

    @Test func summariesDoNotDecodePayloads() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE digest_email_result SET suggestions = 'not json', info = 'nope'")
        }
        #expect(try await store.digestSummaries().first?.pendingCount == 1)
    }

    @Test func countsFollowAppendUpdateDeleteAndRetention() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)

        var approved = f.a1
        approved.status = .approved
        approved.decidedAt = t0
        try await store.update(approved)
        var s = try #require(await store.digestSummaries().first)
        #expect(s.pendingCount == 0 && s.failedCount == 1)

        var retry = f.a2
        retry.status = .failed
        try await store.update(retry) // still failed
        // Replacing a result swaps its index rows.
        let extra = sug("a", .pending)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: makeInfo("a"), suggestions: [extra]), to: f.daily.id)
        s = try #require(await store.digestSummaries().first)
        #expect(s.pendingCount == 1 && s.failedCount == 0 && s.emailCount == 2)

        try await store.deleteEmailResults(["a"], from: f.daily.id)
        s = try #require(await store.digestSummaries().first)
        #expect(s.pendingCount == 0 && s.emailCount == 1)

        // save() replaces the whole result set and its index rows.
        var whole = makeDigest(id: f.backlog.id, at: t0.addingTimeInterval(-day))
        whole.suggestions = [sug("z", .failed)]
        try await store.save(whole)
        #expect(try await store.digestSummaries().map(\.failedCount) == [0, 1, 0])

        try await store.apply(RetentionPlan(digestIDs: [f.backlog.id], jobIDs: []))
        let refs = try await store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM suggestion_ref WHERE digest_id = ?", arguments: [f.backlog.id.uuidString]) }
        #expect(refs == 0)
        #expect(try await store.digestSummaries().count == 2)
    }

    @Test func actionablePagingOrderAndFilters() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)
        let all = try await store.actionableSuggestions(SuggestionQuery(limit: 10))
        #expect(all.map(\.suggestion.id) == [f.a1.id, f.a2.id, f.c1.id])
        #expect(all.map(\.kind) == [.daily, .daily, .backlog])
        // c1 has no category of its own: falls back to the info item's (.work), a2 keeps its own.
        #expect(all[2].category == .work)
        let ctx = try #require(all[0].email)
        #expect(ctx.sender == "Sam <sam@example.com>" && ctx.storeRowID == 11 && ctx.mailbox == inbox)

        let page = try await store.actionableSuggestions(SuggestionQuery(limit: 1, offset: 1))
        #expect(page.map(\.suggestion.id) == [f.a2.id])
        #expect(try await store.actionableSuggestions(SuggestionQuery(limit: 5, offset: 3)).isEmpty)
        #expect(try await store.actionableSuggestions(SuggestionQuery(kinds: [.backlog], limit: 5)).map(\.suggestion.id) == [f.c1.id])
        #expect(try await store.actionableSuggestions(SuggestionQuery(kinds: [], limit: 5)).isEmpty)
        let before = try await store.actionableSuggestions(SuggestionQuery(digestsCreatedBefore: t0, limit: 5))
        #expect(before.map(\.suggestion.id) == [f.c1.id])
    }

    @Test func pagingDecodesOnlyReturnedRows() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE digest_email_result SET suggestions = 'broken' WHERE email_id = 'c'")
        }
        // The broken row is outside the page, so the page still loads.
        #expect(try await store.actionableSuggestions(SuggestionQuery(limit: 2)).count == 2)
    }

    @Test func categoryFallsBackToOtherWithoutInfo() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        try await store.save(d)
        let s = sug("x", category: nil)
        try await store.appendEmailResult(EmailResult(emailID: "x", suggestions: [s]), to: d.id)
        let rec = try #require(await store.actionableSuggestions(SuggestionQuery(limit: 5)).first)
        #expect(rec.category == .other && rec.email == nil && rec.kind == .daily)
    }

    @Test func logbookOrdersByDecidedAtWithDigestFallback() async throws {
        let store = try GRDBDigestStore.inMemory()
        let f = Fixture()
        try await f.load(into: store)
        // b1 decided at t0+100; b2 has nil -> daily digest createdAt t0; o1 decided t0-1d.
        let all = try await store.decidedSuggestions(limit: 10, offset: 0)
        #expect(all.map(\.suggestion.id) == [f.b1.id, f.b2.id, f.o1.id])
        #expect(try await store.decidedSuggestions(limit: 1, offset: 1).map(\.suggestion.id) == [f.b2.id])
        #expect(try await store.decidedSuggestions(limit: 0, offset: 0).isEmpty)
    }

    @Test func decidedAtRoundTripsAndIsClearedOnUpdate() async throws {
        let store = try GRDBDigestStore.inMemory()
        let d = makeDigest()
        try await store.save(d)
        var s = sug("a")
        try await store.appendEmailResult(EmailResult(emailID: "a", suggestions: [s]), to: d.id)
        s.status = .approved
        s.decidedAt = t0.addingTimeInterval(5.5)
        try await store.update(s)
        #expect(try await store.digest(id: d.id)?.suggestions.first?.decidedAt == t0.addingTimeInterval(5.5))
        s.status = .failed
        s.decidedAt = nil
        try await store.update(s)
        #expect(try await store.decidedSuggestions(limit: 5, offset: 0).isEmpty)
        #expect(try await store.digestSummaries().first?.failedCount == 1)
    }

    @Test func v3DatabaseMigratesPreservingDataAndBackfillsIndex() async throws {
        let queue = try DatabaseQueue()
        try GRDBDigestStore.migrator.migrate(queue, upTo: "v3")
        let digestID = UUID(), jobID = digestID
        let pending = sug("a", .pending), done = sug("a", .approved)
        let info = makeInfo("a", pinned: true)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO digest (id, created_at, headline) VALUES (?, ?, 'old')",
                           arguments: [digestID.uuidString, t0.timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO job (id, kind, mailboxes, scope_from, scope_to, state, created_at, queued, done, failed,
                                 skipped, auto_paused, last_error)
                VALUES (?, 'backlog', '[]', 0, 0, 'finished', ?, 1, 1, 0, 0, 0, NULL)
                """, arguments: [jobID.uuidString, t0.timeIntervalSince1970])
            try db.execute(sql: """
                INSERT INTO digest_email_result (digest_id, email_id, ordinal, info, suggestions, skipped)
                VALUES (?, 'a', 0, ?, ?, NULL)
                """, arguments: [digestID.uuidString, try JSON.encode(info), try JSON.encode([pending, done])])
        }
        let store = try GRDBDigestStore(writer: queue)
        let digest = try #require(await store.digest(id: digestID))
        #expect(digest.suggestions == [pending, done] && digest.info == [info] && digest.headline == "old")
        let summary = try #require(await store.digestSummaries().first)
        #expect(summary.kind == .backlog && summary.pendingCount == 1 && summary.emailCount == 1)
        let decided = try await store.decidedSuggestions(limit: 5, offset: 0)
        #expect(decided.map(\.suggestion.id) == [done.id] && decided[0].suggestion.decidedAt == nil)
        #expect(decided[0].category == .work)
    }

    @Test func storesAgreeOnSharedFixture() async throws {
        let grdb = try GRDBDigestStore.inMemory()
        let memory = InMemoryDigestStore()
        let f = Fixture()
        try await f.load(into: grdb)
        try await f.load(into: memory)
        #expect(try await grdb.digestSummaries() == memory.digestSummaries())
        let queries = [SuggestionQuery(limit: 10), SuggestionQuery(kinds: [.daily], limit: 10),
                       SuggestionQuery(digestsCreatedBefore: t0, limit: 10), SuggestionQuery(limit: 1, offset: 1)]
        for q in queries {
            #expect(try await grdb.actionableSuggestions(q) == memory.actionableSuggestions(q))
        }
        #expect(try await grdb.decidedSuggestions(limit: 10, offset: 0) == memory.decidedSuggestions(limit: 10, offset: 0))
        #expect(try await grdb.decidedSuggestions(limit: 1, offset: 1) == memory.decidedSuggestions(limit: 1, offset: 1))
    }
}
