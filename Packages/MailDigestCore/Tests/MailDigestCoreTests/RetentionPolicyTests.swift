import Foundation
import Testing
@testable import MailDigestCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func digest(age: TimeInterval, pinned: Bool = false) -> Digest {
    let item = InfoItem(id: "e", emailID: "e", category: .other, importance: 1, summary: "s",
                        keyFacts: [], pinned: pinned)
    return Digest(id: UUID(), createdAt: now.addingTimeInterval(-age), headline: "h", emailCount: 1,
                  suggestions: [], info: [item], skipped: [])
}

private func job(age: TimeInterval, state: JobState = .finished) -> Job {
    Job(id: UUID(), kind: .backlog, mailboxes: [], scopeFrom: now, scopeTo: now, state: state,
        createdAt: now.addingTimeInterval(-age), totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0),
        autoPaused: false)
}

@Suite struct RetentionPolicyTests {
    private let policy = RetentionPolicy()

    @Test func maxAges() {
        #expect(HistoryRetention.default == .ninetyDays)
        #expect(HistoryRetention.thirtyDays.maxAge == 30 * day)
        #expect(HistoryRetention.ninetyDays.maxAge == 90 * day)
        #expect(HistoryRetention.oneYear.maxAge == 365 * day)
        #expect(HistoryRetention.forever.maxAge == nil)
    }

    @Test(arguments: [HistoryRetention.thirtyDays, .ninetyDays, .oneYear])
    func boundary(setting: HistoryRetention) {
        let limit = setting.maxAge!
        let old = digest(age: limit + 1), exact = digest(age: limit), young = digest(age: limit - 1)
        let oldJob = job(age: limit + 1), youngJob = job(age: limit - 1)
        let plan = policy.plan(retention: setting, now: now, digests: [old, exact, young], jobs: [oldJob, youngJob])
        #expect(plan.digestIDs == [old.id])
        #expect(plan.jobIDs == [oldJob.id])
    }

    @Test func foreverKeepsEverything() {
        let plan = policy.plan(retention: .forever, now: now, digests: [digest(age: 1000 * day)],
                               jobs: [job(age: 1000 * day)])
        #expect(plan == RetentionPlan())
    }

    @Test func pinnedDigestsAreKept() {
        let pinned = digest(age: 400 * day, pinned: true), plain = digest(age: 400 * day)
        let plan = policy.plan(retention: .thirtyDays, now: now, digests: [pinned, plain], jobs: [])
        #expect(plan.digestIDs == [plain.id])
        #expect(policy.deleteAllPlan(digests: [pinned, plain], jobs: []).digestIDs == [plain.id])
    }

    @Test func onlyFinishedOrFailedJobs() {
        let states: [JobState] = [.idle, .listing, .running, .pausing, .paused, .stopping, .stopped, .finished, .failed]
        let jobs = states.map { job(age: 500 * day, state: $0) }
        let expected = jobs.filter { $0.state == .finished || $0.state == .failed }.map(\.id)
        #expect(policy.plan(retention: .thirtyDays, now: now, digests: [], jobs: jobs).jobIDs == expected)
        #expect(policy.deleteAllPlan(digests: [], jobs: jobs).jobIDs == expected)
    }

    @Test func deleteAllIgnoresAge() {
        let fresh = digest(age: 0), freshJob = job(age: 0)
        let plan = policy.deleteAllPlan(digests: [fresh], jobs: [freshJob])
        #expect(plan == RetentionPlan(digestIDs: [fresh.id], jobIDs: [freshJob.id]))
    }

    @Test func processedIDsAndDecisionsAreNotInThePlan() async throws {
        let store = InMemoryDigestStore()
        let old = digest(age: 400 * day)
        try await store.save(old)
        try await store.markProcessed(ProcessedEmail(id: "m1", receivedAt: now, tier: .full, processedAt: now))
        try await store.recordDecision(Decision(suggestionID: UUID(), sender: "a@b.c", action: .approved, decidedAt: now))

        let plan = policy.plan(retention: .thirtyDays, now: now, digests: await store.allDigests(), jobs: [])
        #expect(plan.digestIDs == [old.id])
        // The plan carries only digest and job ids, so nothing else can be deleted through it.
        #expect(Mirror(reflecting: plan).children.map { $0.label ?? "" }.sorted() == ["digestIDs", "jobIDs"])
        #expect(await store.processedIDs() == ["m1"])
        #expect(try await store.decisions(for: "a@b.c").count == 1)
    }

    @Test func pinnedItemKeepsDigestAndJobWhileUnpinnedExpiredOneIsDeleted() async throws {
        let store = InMemoryDigestStore()
        let pinned = digest(age: 400 * day), plain = digest(age: 400 * day)
        let pinnedJob = Job(id: pinned.id, kind: .daily, mailboxes: [], scopeFrom: now, scopeTo: now, state: .finished,
                            createdAt: pinned.createdAt, totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0),
                            autoPaused: false)
        var plainJob = pinnedJob
        plainJob.id = plain.id
        try await store.save(pinned)
        try await store.save(plain)
        try await store.setPinned(true, infoID: "e", digestID: pinned.id)

        // The pin is made through the store, as the panel does, and retention reads it back from there.
        let plan = policy.plan(retention: .thirtyDays, now: now, digests: try await store.retainedDigests(),
                               jobs: [pinnedJob, plainJob])
        #expect(plan.digestIDs == [plain.id] && plan.jobIDs == [plain.id])
        try await store.apply(plan)
        #expect(try await store.pinnedInfo().map(\.digestID) == [pinned.id])
        #expect(try await store.digest(id: plain.id) == nil)

        // Unpinning makes the old digest expire at the next cleanup.
        try await store.setPinned(false, infoID: "e", digestID: pinned.id)
        let later = policy.plan(retention: .thirtyDays, now: now, digests: try await store.retainedDigests(),
                                jobs: [pinnedJob])
        #expect(later.digestIDs == [pinned.id] && later.jobIDs == [pinned.id])
    }
}
