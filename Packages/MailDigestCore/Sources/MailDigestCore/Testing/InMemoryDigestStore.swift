import Foundation

/// Dictionary-backed `DigestStore` with the same semantics as the SQLite store.
public actor InMemoryDigestStore: DigestStore {
    /// Digest-level row; the content lives in `resultsByDigest` (Q17).
    private struct DigestRow { var id: UUID; var createdAt: Date; var headline: String }
    private var digestRows: [DigestRow] = []
    private var resultsByDigest: [UUID: [EmailResult]] = [:]
    private var processed: [String: ProcessedEmail] = [:]
    private var decisionList: [Decision] = []
    private var jobList: [Job] = []
    private var itemList: [JobItem] = []
    /// Item id -> index in `itemList`; rebuilt when retention removes items.
    private var itemIndex: [UUID: Int] = [:]
    /// Job id -> indices into `itemList`, in enqueue order (which is position order).
    private var itemsByJob: [UUID: [Int]] = [:]

    public init() {}

    // MARK: Runs and processed mail

    public func lastRunDate() async throws -> Date? { digestRows.map(\.createdAt).max() }

    public func isProcessed(_ messageID: String) async throws -> Bool { processed[messageID] != nil }

    public func markProcessed(_ email: ProcessedEmail) async throws { processed[email.id] = email }

    // MARK: Digests and suggestions

    public func save(_ digest: Digest) async throws {
        let row = DigestRow(id: digest.id, createdAt: digest.createdAt, headline: digest.headline)
        if let i = digestRows.firstIndex(where: { $0.id == digest.id }) {
            digestRows[i] = row
        } else {
            digestRows.append(row)
        }
        resultsByDigest[digest.id] = EmailResult.results(from: digest)
    }

    public func appendEmailResult(_ result: EmailResult, to digestID: UUID) async throws {
        guard digestRows.contains(where: { $0.id == digestID }) else { throw DigestStoreError.digestNotFound(digestID) }
        var list = resultsByDigest[digestID] ?? []
        if let i = list.firstIndex(where: { $0.emailID == result.emailID }) {
            list[i] = result
        } else {
            list.append(result)
        }
        resultsByDigest[digestID] = list
    }

    public func deleteEmailResults(_ emailIDs: Set<String>, from digestID: UUID) async throws {
        resultsByDigest[digestID]?.removeAll { emailIDs.contains($0.emailID) }
    }

    public func latestDigest() async throws -> Digest? {
        digestRows.max { $0.createdAt < $1.createdAt }.map(aggregate)
    }

    public func digest(id: UUID) async throws -> Digest? {
        digestRows.first { $0.id == id }.map(aggregate)
    }

    private func aggregate(_ row: DigestRow) -> Digest {
        Digest(id: row.id, createdAt: row.createdAt, headline: row.headline, results: resultsByDigest[row.id] ?? [])
    }

    public func recentSuggestions(since: Date) async throws -> [Suggestion] {
        digestRows.filter { $0.createdAt >= since }.flatMap { resultsByDigest[$0.id] ?? [] }.flatMap(\.suggestions)
    }

    public func update(_ suggestion: Suggestion) async throws {
        for (digestID, results) in resultsByDigest {
            for r in results.indices {
                if let s = results[r].suggestions.firstIndex(where: { $0.id == suggestion.id }) {
                    resultsByDigest[digestID]?[r].suggestions[s] = suggestion
                    return
                }
            }
        }
    }

    public func apply(_ plan: RetentionPlan) async throws {
        let digestIDs = Set(plan.digestIDs)
        digestRows.removeAll { digestIDs.contains($0.id) }
        for id in digestIDs { resultsByDigest[id] = nil }
        let jobIDs = Set(plan.jobIDs)
        jobList.removeAll { jobIDs.contains($0.id) }
        itemList.removeAll { jobIDs.contains($0.jobID) }
        // Items moved, so the position lookups must be rebuilt.
        itemIndex = [:]
        itemsByJob = [:]
        for (i, item) in itemList.enumerated() {
            itemIndex[item.id] = i
            itemsByJob[item.jobID, default: []].append(i)
        }
    }

    // MARK: Decisions

    public func recordDecision(_ decision: Decision) async throws { decisionList.append(decision) }

    public func decisions(for sender: String) async throws -> [Decision] {
        decisionList.filter { $0.sender == sender }
    }

    // MARK: Jobs

    public func createJob(_ job: Job) async throws { jobList.append(job) }

    public func updateJob(_ job: Job) async throws {
        if let i = jobList.firstIndex(where: { $0.id == job.id }) { jobList[i] = job }
    }

    public func jobs() async throws -> [Job] { jobList.sorted { $0.createdAt > $1.createdAt } }

    // MARK: Queue

    public func enqueue(_ headers: [MessageHeader], job jobID: UUID) async throws {
        var position = itemsByJob[jobID]?.last.map { itemList[$0].position } ?? 0
        for h in headers {
            position += 1
            let item = JobItem(
                id: UUID(), jobID: jobID, messageID: h.id,
                mailbox: h.mailboxRef,
                sender: h.sender, subject: h.subject, receivedAt: h.receivedAt,
                position: position, state: .queued, outcome: nil, seconds: nil,
                attempts: 0, lastError: nil,
                storeRowID: h.sourceReference.storeRowID)
            itemIndex[item.id] = itemList.count
            itemsByJob[jobID, default: []].append(itemList.count)
            itemList.append(item)
        }
    }

    public func isQueued(_ messageID: String) async throws -> Bool {
        itemList.contains { $0.messageID == messageID && ($0.state == .queued || $0.state == .processing) }
    }

    public func nextQueued(job jobID: UUID, limit: Int) async throws -> [JobItem] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        var result: [JobItem] = []
        // `itemsByJob` keeps the job's items in position order, so filtering preserves "lowest position first".
        for i in itemsByJob[jobID] ?? [] where itemList[i].state == .queued {
            result.append(itemList[i])
            if result.count == cap { break }
        }
        return result
    }

    public func items(job jobID: UUID) async throws -> [JobItem] {
        (itemsByJob[jobID] ?? []).map { itemList[$0] }
    }

    public func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?) async throws {
        guard let i = itemIndex[itemID] else { return }
        itemList[i].state = state
        itemList[i].lastError = error
        if error != nil && (state == .queued || state == .failed) { itemList[i].attempts += 1 }
    }

    public func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws {
        guard let i = itemIndex[itemID] else { return }
        itemList[i].outcome = outcome
        itemList[i].seconds = seconds
        itemList[i].finishedAt = finishedAt
    }

    public func requeueFailed(job jobID: UUID) async throws -> [JobItem] {
        var changed: [JobItem] = []
        for i in itemList.indices where itemList[i].jobID == jobID && itemList[i].state == .failed {
            itemList[i].state = .queued
            itemList[i].attempts = 0
            // Q28: a requeued item must not still look finished.
            itemList[i].outcome = nil
            itemList[i].seconds = nil
            itemList[i].finishedAt = nil
            changed.append(itemList[i])
        }
        return changed.sorted { $0.position < $1.position }
    }

    public func requeueInterrupted() async throws -> Int {
        var changed = 0
        for i in itemList.indices where itemList[i].state == .processing {
            itemList[i].state = .queued
            changed += 1
        }
        return changed
    }

    // MARK: Test helpers

    /// Every queue item across jobs, in insertion order.
    public func allItems() -> [JobItem] { itemList }
    /// Ids marked processed.
    public func processedIDs() -> Set<String> { Set(processed.keys) }
    /// Every saved digest, in insertion order, rebuilt from its results.
    public func allDigests() -> [Digest] { digestRows.map(aggregate) }
}
