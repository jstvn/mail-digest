import Foundation
import Testing
@testable import MailDigestCore

/// T29 store behaviour on `InMemoryDigestStore` (the SQLite store runs the same checks in its own package).
@Suite struct JobEventStoreTests {
    @Test func eventsAppendedWithStateChange() async throws { try await eventsAreAppendedWithTheStateChange(InMemoryDigestStore()) }
    @Test func eventOrdering() async throws { try await eventsOrderByTimeThenID(InMemoryDigestStore()) }
    @Test func payloadRoundTrip() async throws { try await payloadRoundTrips(InMemoryDigestStore()) }
    @Test func routingFlow() async throws { try await routingFlowWritesOneValue(InMemoryDigestStore()) }
    @Test func keysetPagingStable() async throws { try await keysetPaging(InMemoryDigestStore()) }
    @Test func pathFilterWorks() async throws { try await pathFilter(InMemoryDigestStore()) }
    @Test func retention() async throws { try await retentionDeletesEventsAndItems(InMemoryDigestStore()) }
}

// MARK: - Helpers

private let base = Date(timeIntervalSince1970: 1_793_737_800)
private let box = MailboxRef(account: "iCloud", name: "Inbox")

private func makeJob(_ id: UUID = UUID(), kind: JobKind = .backlog, at date: Date = base) -> Job {
    Job(id: id, kind: kind, mailboxes: [box], scopeFrom: date.addingTimeInterval(-3600), scopeTo: date,
        state: .running, createdAt: date, totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0),
        autoPaused: false)
}

private func header(_ id: String) -> MessageHeader {
    MessageHeader(id: id, account: box.account, mailbox: box.name, sender: "Sam <sam@example.com>",
                  subject: "S \(id)", receivedAt: base,
                  sourceReference: MailMessageReference(messageID: id, storeRowID: nil))
}

private func routing(provider: ExecutionProvider? = nil, model: String = "m") -> RoutingProvenance {
    RoutingProvenance(
        assessment: PrivacyAssessment(verdict: .public, method: .systemOne, ruleID: nil,
                                      triage: TriageScores(model: "sys1", pSensitive: 0.125, pNonSensitive: 0.75,
                                                           categoryProbabilities: ["bills": 0.5], threshold: 0.5,
                                                           publicFloor: 0.7),
                                      assessedAt: base),
        execution: provider.map {
            ExecutionRecord(provider: $0, model: model, cloudAttempted: $0 == .cloud, startedAt: base,
                            finishedAt: base.addingTimeInterval(2))
        })
}

private func event(_ job: UUID, _ kind: JobEventKind, _ at: Date, _ payload: JobEventPayload = .empty) -> JobEvent {
    JobEvent(jobID: job, kind: kind, at: at, payload: payload)
}

// MARK: - Shared behaviour

private func eventsAreAppendedWithTheStateChange(_ store: any DigestStore) async throws {
    let job = makeJob()
    try await store.createJob(job)
    #expect(try await store.jobEvents(job: job.id).map(\.kind) == [.created])
    #expect(try await store.jobEvents(job: job.id).first?.at == job.createdAt)

    var running = job
    running.startedAt = base.addingTimeInterval(5)
    try await store.updateJob(running, event: event(job.id, .started, base.addingTimeInterval(5)))
    // Without an event nothing is appended.
    running.totals.done = 1
    try await store.updateJob(running)

    let events = try await store.jobEvents(job: job.id)
    #expect(events.map(\.kind) == [.created, .started])
    #expect(events.allSatisfy { $0.id != nil })
    let stored = try #require(try await store.jobs().first)
    #expect(stored.startedAt == base.addingTimeInterval(5) && stored.endedAt == nil && stored.totals.done == 1)

    // A job that does not exist gets neither an update nor an event.
    let ghost = makeJob()
    try await store.updateJob(ghost, event: event(ghost.id, .started, base))
    #expect(try await store.jobEvents(job: ghost.id).isEmpty)
    #expect(try await store.jobs().count == 1)
}

private func eventsOrderByTimeThenID(_ store: any DigestStore) async throws {
    let job = makeJob()
    try await store.createJob(job)
    // Inserted out of time order, with a tie: later time last, ties by insertion.
    try await store.updateJob(job, event: event(job.id, .resumed, base.addingTimeInterval(20)))
    try await store.updateJob(job, event: event(job.id, .paused, base.addingTimeInterval(10),
                                                JobEventPayload(pauseReason: .battery)))
    try await store.updateJob(job, event: event(job.id, .stopped, base.addingTimeInterval(10)))
    let events = try await store.jobEvents(job: job.id)
    #expect(events.map(\.kind) == [.created, .paused, .stopped, .resumed])
    #expect(events[1].payload.pauseReason == .battery)
}

private func payloadRoundTrips(_ store: any DigestStore) async throws {
    let job = makeJob()
    try await store.createJob(job)
    let payload = JobEventPayload(pauseReason: .heat, trigger: .automatic, count: 7, errorCategory: "provider")
    try await store.updateJob(job, event: event(job.id, .failed, base, payload))
    #expect(try await store.jobEvents(job: job.id).last?.payload == payload)
}

private func routingFlowWritesOneValue(_ store: any DigestStore) async throws {
    let job = makeJob()
    try await store.createJob(job)
    try await store.enqueue([header("a"), header("b")], job: job.id)
    let a = try #require(try await store.items(job: job.id).first { $0.messageID == "a" })
    #expect(a.routing == nil && a.provider == nil && a.startedAt == nil)

    // Assessment first: no execution, no provider, state untouched.
    let assessed = routing()
    try await store.recordAssessment(job: job.id, messageID: "a", routing: assessed)
    var now = try #require(try await store.items(job: job.id).first { $0.messageID == "a" })
    #expect(now.routing == assessed && now.provider == nil && now.state == .queued)
    let other = try #require(try await store.items(job: job.id).first { $0.messageID == "b" })
    #expect(other.routing == nil)

    // Start time is written with the move to processing, and only then.
    try await store.setItemState(a.id, .processing, error: nil, startedAt: base.addingTimeInterval(1))
    try await store.setItemState(a.id, .queued, error: nil, startedAt: base.addingTimeInterval(99))
    now = try #require(try await store.items(job: job.id).first { $0.messageID == "a" })
    #expect(now.startedAt == base.addingTimeInterval(1))

    // Outcome with the final routing replaces the assessment in one write.
    let final = routing(provider: .cloud, model: "gemini")
    try await store.recordItemOutcome(a.id, outcome: "ok", seconds: 2, finishedAt: base, routing: final)
    now = try #require(try await store.items(job: job.id).first { $0.messageID == "a" })
    #expect(now.routing == final && now.provider == .cloud && now.outcome == "ok")

    // No routing leaves the stored value alone.
    try await store.recordItemOutcome(a.id, outcome: "ok2", seconds: 2, finishedAt: base)
    now = try #require(try await store.items(job: job.id).first { $0.messageID == "a" })
    #expect(now.routing == final && now.provider == .cloud && now.outcome == "ok2")
}

private func keysetPaging(_ store: any DigestStore) async throws {
    // 7 jobs; three share one timestamp to exercise the id tie-break.
    var jobs: [Job] = []
    for n in 0..<7 {
        let at = base.addingTimeInterval(Double(n < 3 ? 0 : n) * 10)
        jobs.append(makeJob(kind: n % 2 == 0 ? .daily : .backlog, at: at))
    }
    for j in jobs { try await store.createJob(j) }
    let expected = jobs.sorted {
        $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString > $1.id.uuidString
    }.map(\.id)

    var seen: [UUID] = []
    var cursor: ActivityCursor?
    while true {
        let page = try await store.activityJobs(ActivityQuery(before: cursor, limit: 2))
        if page.isEmpty { break }
        seen += page.map(\.id)
        cursor = ActivityCursor(after: page[page.count - 1])
    }
    #expect(seen == expected)
    #expect(try await store.activityJobs(ActivityQuery(limit: 0)).isEmpty)

    // Kind filter pages the same way.
    var daily: [UUID] = []
    cursor = nil
    while true {
        let page = try await store.activityJobs(ActivityQuery(kind: .daily, before: cursor, limit: 2))
        if page.isEmpty { break }
        #expect(page.allSatisfy { $0.kind == .daily })
        daily += page.map(\.id)
        cursor = ActivityCursor(after: page[page.count - 1])
    }
    #expect(daily == expected.filter { id in jobs.first { $0.id == id }?.kind == .daily })
}

private func pathFilter(_ store: any DigestStore) async throws {
    let local = makeJob(at: base), cloud = makeJob(at: base.addingTimeInterval(10)), none = makeJob(at: base.addingTimeInterval(20))
    for j in [local, cloud, none] { try await store.createJob(j) }
    for (j, p) in [(local, ExecutionProvider.local), (cloud, .cloud)] {
        try await store.enqueue([header("x-\(j.id)")], job: j.id)
        let item = try #require(try await store.items(job: j.id).first)
        try await store.recordItemOutcome(item.id, outcome: "ok", seconds: 1, finishedAt: base, routing: routing(provider: p))
    }
    try await store.enqueue([header("y")], job: none.id)
    #expect(try await store.activityJobs(ActivityQuery(path: .cloud)).map(\.id) == [cloud.id])
    #expect(try await store.activityJobs(ActivityQuery(path: .local)).map(\.id) == [local.id])
    #expect(try await store.activityJobs(ActivityQuery()).count == 3)
    #expect(try await store.activityJobs(ActivityQuery(kind: .daily, path: .cloud)).isEmpty)
}

private func retentionDeletesEventsAndItems(_ store: any DigestStore) async throws {
    let gone = makeJob(at: base), kept = makeJob(at: base.addingTimeInterval(10))
    for j in [gone, kept] {
        try await store.createJob(j)
        try await store.enqueue([header("m-\(j.id)")], job: j.id)
        try await store.updateJob(j, event: event(j.id, .started, base.addingTimeInterval(100)))
    }
    try await store.apply(RetentionPlan(jobIDs: [gone.id]))
    #expect(try await store.jobEvents(job: gone.id).isEmpty)
    #expect(try await store.items(job: gone.id).isEmpty)
    #expect(try await store.jobs().map(\.id) == [kept.id])
    #expect(try await store.jobEvents(job: kept.id).map(\.kind) == [.created, .started])
    #expect(try await store.items(job: kept.id).count == 1)
}

// MARK: - Model Codable

@Suite struct JobModelCodableT29Tests {
    @Test func oldJobAndItemJSONDecodeWithoutNewKeys() throws {
        let job = makeJob()
        var data = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        data["startedAt"] = nil
        data["endedAt"] = nil
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(decoded.startedAt == nil && decoded.endedAt == nil)

        let item = JobItem(id: UUID(), jobID: job.id, messageID: "a", mailbox: box, sender: "s", subject: "x",
                           receivedAt: base, position: 1, state: .queued, outcome: nil, seconds: nil, attempts: 0,
                           lastError: nil, startedAt: base, routing: routing(provider: .local), provider: .local)
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(try JSONDecoder().decode(JobItem.self, from: JSONSerialization.data(withJSONObject: obj)) == item)
        for key in ["startedAt", "routing", "provider"] { obj[key] = nil }
        let old = try JSONDecoder().decode(JobItem.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.startedAt == nil && old.routing == nil && old.provider == nil)
    }

    @Test func eventKindsAreExactlyTheSpecifiedSet() {
        #expect(Set(JobEventKind.allCases.map(\.rawValue)) == [
            "created", "started", "paused", "autoPaused", "resumed", "stopped", "completed",
            "completedWithFailures", "failed", "retryRequested", "recoveredAfterInterruption"])
    }
}
