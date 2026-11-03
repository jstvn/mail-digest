import Foundation

/// Dictionary-backed `DigestStore` with the same semantics as the SQLite store.
public actor InMemoryDigestStore: DigestStore {
    private var digests: [Digest] = []
    private var processed: [String: ProcessedEmail] = [:]
    private var decisionList: [Decision] = []
    private var jobList: [Job] = []
    private var itemList: [JobItem] = []

    public init() {}

    // MARK: Runs and processed mail

    public func lastRunDate() async throws -> Date? { digests.map(\.createdAt).max() }

    public func isProcessed(_ messageID: String) async throws -> Bool { processed[messageID] != nil }

    public func markProcessed(_ email: ProcessedEmail) async throws { processed[email.id] = email }

    // MARK: Digests and suggestions

    public func save(_ digest: Digest) async throws {
        if let i = digests.firstIndex(where: { $0.id == digest.id }) {
            digests[i] = digest
        } else {
            digests.append(digest)
        }
    }

    public func latestDigest() async throws -> Digest? { digests.max { $0.createdAt < $1.createdAt } }

    public func digest(id: UUID) async throws -> Digest? { digests.first { $0.id == id } }

    public func recentSuggestions(since: Date) async throws -> [Suggestion] {
        digests.filter { $0.createdAt >= since }.flatMap(\.suggestions)
    }

    public func update(_ suggestion: Suggestion) async throws {
        for d in digests.indices {
            if let s = digests[d].suggestions.firstIndex(where: { $0.id == suggestion.id }) {
                digests[d].suggestions[s] = suggestion
                return
            }
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
        var position = itemList.filter { $0.jobID == jobID }.map(\.position).max() ?? 0
        for h in headers {
            position += 1
            itemList.append(JobItem(
                id: UUID(), jobID: jobID, messageID: h.id,
                mailbox: MailboxRef(account: h.account, name: h.mailbox),
                sender: h.sender, subject: h.subject, receivedAt: h.receivedAt,
                position: position, state: .queued, outcome: nil, seconds: nil,
                attempts: 0, lastError: nil))
        }
    }

    public func isQueued(_ messageID: String) async throws -> Bool {
        itemList.contains { $0.messageID == messageID && ($0.state == .queued || $0.state == .processing) }
    }

    public func nextQueued(job jobID: UUID, limit: Int) async throws -> [JobItem] {
        Array(itemList.filter { $0.jobID == jobID && $0.state == .queued }
            .sorted { $0.position < $1.position }.prefix(max(0, limit)))
    }

    public func items(job jobID: UUID) async throws -> [JobItem] {
        itemList.filter { $0.jobID == jobID }.sorted { $0.position < $1.position }
    }

    public func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?) async throws {
        guard let i = itemList.firstIndex(where: { $0.id == itemID }) else { return }
        itemList[i].state = state
        itemList[i].lastError = error
        if state == .processing { itemList[i].attempts += 1 }
    }

    public func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws {
        guard let i = itemList.firstIndex(where: { $0.id == itemID }) else { return }
        itemList[i].outcome = outcome
        itemList[i].seconds = seconds
        itemList[i].finishedAt = finishedAt
    }

    public func requeueFailed(job jobID: UUID) async throws -> [JobItem] {
        var changed: [JobItem] = []
        for i in itemList.indices where itemList[i].jobID == jobID && itemList[i].state == .failed {
            itemList[i].state = .queued
            itemList[i].attempts = 0
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
    /// Every saved digest, in insertion order.
    public func allDigests() -> [Digest] { digests }
}
