import Foundation
import Testing
@testable import MailDigestCore

private let t0 = Date(timeIntervalSince1970: 1_793_737_800)

private func suggestion(_ email: String, _ title: String = "T", category: EmailCategory? = nil) -> Suggestion {
    Suggestion(id: UUID(), emailID: email, title: title, due: nil, dueHasTime: false, priority: .low,
               evidence: "x", confidence: 0.8, preselected: true, flags: [], status: .pending, reminderID: nil,
               category: category)
}

private func info(_ email: String) -> InfoItem {
    InfoItem(id: email, emailID: email, category: .work, importance: 2, summary: "s", keyFacts: [], pinned: false)
}

private func digestRow(_ id: UUID = UUID(), at date: Date = t0) -> Digest {
    Digest(id: id, createdAt: date, headline: "h", emailCount: 0, suggestions: [], info: [], skipped: [])
}

@Suite struct EmailResultStoreTests {
    @Test func appendUpsertsAndReconstructsInResultOrder() async throws {
        let store = InMemoryDigestStore()
        let d = digestRow()
        try await store.save(d)
        let s1 = suggestion("a"), s2 = suggestion("b")
        try await store.appendEmailResult(EmailResult(emailID: "a", info: info("a"), suggestions: [s1]), to: d.id)
        try await store.appendEmailResult(EmailResult(emailID: "b", info: info("b"), suggestions: [s2]), to: d.id)
        try await store.appendEmailResult(EmailResult(emailID: "c", skipped: SkippedEmail(
            id: "c", sender: "x", subject: "y", reason: "r")), to: d.id)

        // Replacing "a" keeps its position.
        var s1b = s1
        s1b.title = "changed"
        try await store.appendEmailResult(EmailResult(emailID: "a", info: info("a"), suggestions: [s1b]), to: d.id)

        let got = try #require(await store.digest(id: d.id))
        #expect(got.emailCount == 3)
        #expect(got.info.map(\.emailID) == ["a", "b"])
        #expect(got.suggestions.map(\.title) == ["changed", "T"])
        #expect(got.skipped.map(\.id) == ["c"])
        #expect(got.headline == "h")
    }

    @Test func appendToUnknownDigestThrows() async throws {
        let store = InMemoryDigestStore()
        let id = UUID()
        await #expect(throws: DigestStoreError.digestNotFound(id)) {
            try await store.appendEmailResult(EmailResult(emailID: "a"), to: id)
        }
    }

    @Test func deleteRemovesOnlyTheNamedResults() async throws {
        let store = InMemoryDigestStore()
        let d = digestRow()
        try await store.save(d)
        for id in ["a", "b", "c"] { try await store.appendEmailResult(EmailResult(emailID: id, info: info(id)), to: d.id) }
        try await store.deleteEmailResults(["a", "c", "zzz"], from: d.id)
        let got = try #require(await store.digest(id: d.id))
        #expect(got.info.map(\.emailID) == ["b"] && got.emailCount == 1)
    }

    @Test func saveReplacesResultsWithThoseDerivedFromTheDigest() async throws {
        let store = InMemoryDigestStore()
        var d = digestRow()
        d.info = [info("a"), info("b")]
        d.suggestions = [suggestion("b"), suggestion("a")]
        d.emailCount = 99 // derived from content on read, never trusted
        try await store.save(d)
        #expect(try await store.digest(id: d.id)?.emailCount == 2)
        d.info = [info("z")]
        d.suggestions = []
        try await store.save(d)
        let got = try #require(await store.digest(id: d.id))
        #expect(got.info.map(\.emailID) == ["z"] && got.suggestions.isEmpty)
    }

    @Test func updatePersistsEditsInsideTheResult() async throws {
        let store = InMemoryDigestStore()
        let d = digestRow()
        try await store.save(d)
        let s = suggestion("a", category: .work)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: info("a"), suggestions: [s]), to: d.id)
        var edited = s
        edited.category = .finance
        edited.status = .approved
        try await store.update(edited)
        #expect(try await store.latestDigest()?.suggestions == [edited])
    }

    @Test func applyRetentionDeletesDigestsAndJobsButNotProcessedIDsOrDecisions() async throws {
        let store = InMemoryDigestStore()
        let old = digestRow(at: t0), keep = digestRow(at: t0.addingTimeInterval(10))
        try await store.save(old); try await store.save(keep)
        try await store.appendEmailResult(EmailResult(emailID: "a", info: info("a")), to: old.id)
        let jobA = Job(id: old.id, kind: .backlog, mailboxes: [], scopeFrom: t0, scopeTo: t0, state: .finished,
                       createdAt: t0, totals: JobTotals(queued: 0, done: 1, failed: 0, skipped: 0), autoPaused: false)
        var jobB = jobA
        jobB.id = keep.id
        try await store.createJob(jobA); try await store.createJob(jobB)
        let header = MessageHeader(id: "a", account: "x", mailbox: "Inbox", sender: "s", subject: "t", receivedAt: t0,
                                   sourceReference: MailMessageReference(messageID: "a", storeRowID: nil))
        try await store.enqueue([header], job: jobA.id)
        try await store.enqueue([header], job: jobB.id)
        try await store.markProcessed(ProcessedEmail(id: "a", receivedAt: t0, tier: .full, processedAt: t0))
        try await store.recordDecision(Decision(suggestionID: UUID(), sender: "s@x.com", action: .approved, decidedAt: t0))

        try await store.apply(RetentionPlan(digestIDs: [old.id], jobIDs: [jobA.id]))

        #expect(try await store.digest(id: old.id) == nil)
        #expect(try await store.digest(id: keep.id) != nil)
        #expect(try await store.jobs().map(\.id) == [keep.id])
        #expect(try await store.items(job: jobA.id).isEmpty)
        let kept = try await store.items(job: jobB.id)
        #expect(kept.count == 1)
        // Index lookups still work after removal.
        try await store.setItemState(kept[0].id, .done, error: nil)
        #expect(try await store.items(job: jobB.id).first?.state == .done)
        #expect(await store.processedIDs() == ["a"])
        #expect(try await store.decisions(for: "s@x.com").count == 1)
    }

    @Test func pinnedDigestKeepsItsJobAndResumableJobKeepsItsDigest() {
        let old = t0.addingTimeInterval(-400 * 86_400)
        func job(_ id: UUID, _ state: JobState) -> Job {
            Job(id: id, kind: .backlog, mailboxes: [], scopeFrom: old, scopeTo: old, state: state, createdAt: old,
                totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0), autoPaused: false)
        }
        var pinned = digestRow(at: old)
        pinned.info = [InfoItem(id: "p", emailID: "p", category: .work, importance: 1, summary: "", keyFacts: [], pinned: true)]
        let plain = digestRow(at: old), paused = digestRow(at: old)
        let jobs = [job(pinned.id, .finished), job(plain.id, .finished), job(paused.id, .paused)]
        let policy = RetentionPolicy()
        let plan = policy.plan(retention: .thirtyDays, now: t0, digests: [pinned, plain, paused], jobs: jobs)
        #expect(plan.digestIDs == [plain.id] && plan.jobIDs == [plain.id])
        let all = policy.deleteAllPlan(digests: [pinned, plain, paused], jobs: jobs)
        #expect(all.digestIDs == [plain.id] && all.jobIDs == [plain.id])
    }

    @Test func suggestionDecodesWithoutCategory() throws {
        let s = suggestion("a", category: .uni)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        object["category"] = nil
        let decoded = try JSONDecoder().decode(Suggestion.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.category == nil)
    }
}
