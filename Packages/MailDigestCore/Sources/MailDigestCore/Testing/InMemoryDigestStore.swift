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
    private var eventList: [JobEvent] = []
    private var nextEventID: Int64 = 1
    private var dispositionList: [MailDisposition] = []
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

    public func retainedDigests() async throws -> [Digest] { digestRows.map(aggregate) }

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

    public func setPinned(_ pinned: Bool, infoID: String, digestID: UUID) async throws {
        guard let i = resultsByDigest[digestID]?.firstIndex(where: { $0.info?.id == infoID }) else { return }
        resultsByDigest[digestID]?[i].info?.pinned = pinned
    }

    public func pinnedInfo() async throws -> [PinnedInfo] {
        digestRows.sorted { $0.createdAt > $1.createdAt }.flatMap { row in
            (resultsByDigest[row.id] ?? []).compactMap(\.info).filter(\.pinned)
                .map { PinnedInfo(item: $0, digestID: row.id, digestCreatedAt: row.createdAt) }
        }
    }

    public func recordDispositions(_ dispositions: [MailDisposition]) async throws {
        for d in dispositions {
            guard digestRows.contains(where: { $0.id == d.digestID }) else { throw DigestStoreError.digestNotFound(d.digestID) }
            dispositionList.removeAll { $0.digestID == d.digestID && $0.emailID == d.emailID && $0.kind == d.kind }
            dispositionList.append(d)
        }
    }

    public func removeDispositions(_ kind: MailDispositionKind, emailIDs: Set<String>, digestID: UUID) async throws {
        dispositionList.removeAll { $0.digestID == digestID && $0.kind == kind && emailIDs.contains($0.emailID) }
    }

    public func dispositions(digestID: UUID) async throws -> [MailDisposition] {
        dispositionList.filter { $0.digestID == digestID }
    }

    public func apply(_ plan: RetentionPlan) async throws {
        let digestIDs = Set(plan.digestIDs)
        digestRows.removeAll { digestIDs.contains($0.id) }
        for id in digestIDs { resultsByDigest[id] = nil }
        dispositionList.removeAll { digestIDs.contains($0.digestID) }
        let jobIDs = Set(plan.jobIDs)
        jobList.removeAll { jobIDs.contains($0.id) }
        eventList.removeAll { jobIDs.contains($0.jobID) }
        itemList.removeAll { jobIDs.contains($0.jobID) }
        // Items moved, so the position lookups must be rebuilt.
        itemIndex = [:]
        itemsByJob = [:]
        for (i, item) in itemList.enumerated() {
            itemIndex[item.id] = i
            itemsByJob[item.jobID, default: []].append(i)
        }
    }

    // MARK: Summaries and paging

    public func digestSummaries() async throws -> [DigestSummary] {
        // Reversed first so the stable sort puts the later-saved digest first on equal timestamps.
        digestRows.reversed().sorted { $0.createdAt > $1.createdAt }.map { row in
            let suggestions = (resultsByDigest[row.id] ?? []).flatMap(\.suggestions)
            return DigestSummary(
                id: row.id, createdAt: row.createdAt, kind: kind(of: row.id),
                emailCount: resultsByDigest[row.id]?.count ?? 0,
                pendingCount: suggestions.filter { $0.status == .pending }.count,
                failedCount: suggestions.filter { $0.status == .failed }.count)
        }
    }

    public func actionableSuggestions(_ query: SuggestionQuery) async throws -> [SuggestionRecord] {
        let all = records { $0.status == .pending || $0.status == .failed }.filter { rec in
            (query.kinds?.contains(rec.kind) ?? true) && (query.digestsCreatedBefore.map { rec.digestCreatedAt < $0 } ?? true)
        }
        return page(all, limit: query.limit, offset: query.offset)
    }

    public func decidedSuggestions(limit: Int, offset: Int) async throws -> [SuggestionRecord] {
        // Stable sort keeps the digest/ordinal/position order from `records` for equal sort keys.
        let all = records { $0.status == .approved || $0.status == .dismissed }
            .sorted { ($0.suggestion.decidedAt ?? $0.digestCreatedAt) > ($1.suggestion.decidedAt ?? $1.digestCreatedAt) }
        return page(all, limit: limit, offset: offset)
    }

    private func page(_ list: [SuggestionRecord], limit: Int, offset: Int) -> [SuggestionRecord] {
        let start = max(0, offset)
        guard limit > 0, start < list.count else { return [] }
        return Array(list[start..<min(list.count, start + limit)])
    }

    private func kind(of digestID: UUID) -> JobKind { jobList.first { $0.id == digestID }?.kind ?? .daily }

    /// Every matching suggestion as a record, in digest (newest, later save first), ordinal, position order.
    private func records(where include: (Suggestion) -> Bool) -> [SuggestionRecord] {
        var out: [SuggestionRecord] = []
        for row in digestRows.reversed().sorted(by: { $0.createdAt > $1.createdAt }) {
            let kind = kind(of: row.id)
            let items = itemsByJob[row.id] ?? []
            for result in resultsByDigest[row.id] ?? [] {
                // First item for an email wins, as in the review window.
                let email = items.lazy.map { self.itemList[$0] }.first { $0.messageID == result.emailID }
                    .map(EmailContext.init(item:))
                for s in result.suggestions where include(s) {
                    out.append(SuggestionRecord(
                        suggestion: s, digestID: row.id, digestCreatedAt: row.createdAt, kind: kind,
                        category: s.category ?? result.info?.category ?? .other, email: email))
                }
            }
        }
        return out
    }

    // MARK: Decisions

    public func recordDecision(_ decision: Decision) async throws { decisionList.append(decision) }

    public func decisions(for sender: String) async throws -> [Decision] {
        decisionList.filter { $0.sender == sender }
    }

    // MARK: Jobs

    public func createJob(_ job: Job) async throws {
        jobList.append(job)
        append(JobEvent(jobID: job.id, kind: .created, at: job.createdAt))
    }

    public func updateJob(_ job: Job, event: JobEvent?) async throws {
        guard let i = jobList.firstIndex(where: { $0.id == job.id }) else { return }
        jobList[i] = job
        if let event { append(event) }
    }

    private func append(_ event: JobEvent) {
        var event = event
        event.id = nextEventID
        nextEventID += 1
        eventList.append(event)
    }

    public func jobs() async throws -> [Job] { jobList.sorted { $0.createdAt > $1.createdAt } }

    public func jobEvents(job jobID: UUID) async throws -> [JobEvent] {
        eventList.filter { $0.jobID == jobID }.sorted { ($0.at, $0.id ?? 0) < ($1.at, $1.id ?? 0) }
    }

    public func activityJobs(_ query: ActivityQuery) async throws -> [Job] {
        guard query.limit > 0 else { return [] }
        // Same order as the SQL store: created_at DESC, id DESC (upper-case UUID text).
        let ordered = jobList.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString > $1.id.uuidString
        }
        var page: [Job] = []
        for job in ordered {
            if let c = query.before {
                let after = job.createdAt < c.createdAt || (job.createdAt == c.createdAt && job.id.uuidString < c.id.uuidString)
                if !after { continue }
            }
            if let kind = query.kind, job.kind != kind { continue }
            if let path = query.path, !(itemsByJob[job.id] ?? []).contains(where: { itemList[$0].provider == path }) { continue }
            page.append(job)
            if page.count == query.limit { break }
        }
        return page
    }

    // MARK: Queue

    public func enqueue(_ headers: [MessageHeader], job jobID: UUID) async throws {
        appendItems(headers, job: jobID)
    }

    private func appendItems(_ headers: [MessageHeader], job jobID: UUID) {
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

    public func isReservedFromBacklog(_ messageID: String) async throws -> Bool {
        let stopped = Set(jobList.filter { $0.state == .stopped && $0.kind == .backlog }.map(\.id))
        return itemList.contains {
            $0.messageID == messageID && ($0.state == .queued || $0.state == .processing) && !stopped.contains($0.jobID)
        }
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

    public func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?, startedAt: Date?) async throws {
        guard let i = itemIndex[itemID] else { return }
        if state == .processing, let startedAt { itemList[i].startedAt = startedAt }
        itemList[i].state = state
        itemList[i].lastError = error
        if error != nil && (state == .queued || state == .failed) { itemList[i].attempts += 1 }
    }

    public func applyResumeRefresh(_ refresh: QueueRefresh) async throws {
        func isOpen(_ i: Int) -> Bool { itemList[i].state == .queued || itemList[i].state == .processing }
        for id in refresh.skippedItemIDs {
            guard let i = itemIndex[id], isOpen(i) else { continue }
            itemList[i].state = .skipped
            itemList[i].lastError = nil
            itemList[i].outcome = refresh.skipOutcome
            itemList[i].seconds = 0
            itemList[i].finishedAt = refresh.skippedAt
        }
        for move in refresh.relocations {
            guard let i = itemIndex[move.itemID], isOpen(i) else { continue }
            itemList[i].mailbox = move.mailbox
            itemList[i].storeRowID = move.storeRowID
        }
        appendItems(refresh.appended, job: refresh.jobID)
        if let scopeTo = refresh.scopeTo, let j = jobList.firstIndex(where: { $0.id == refresh.jobID }) {
            jobList[j].scopeTo = scopeTo
        }
    }

    public func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date,
                                  routing: RoutingProvenance?) async throws {
        guard let i = itemIndex[itemID] else { return }
        itemList[i].outcome = outcome
        itemList[i].seconds = seconds
        itemList[i].finishedAt = finishedAt
        if let routing {
            itemList[i].routing = routing
            itemList[i].provider = routing.execution?.provider
        }
    }

    public func recordAssessment(job jobID: UUID, messageID: String, routing: RoutingProvenance) async throws {
        for i in itemsByJob[jobID] ?? [] where itemList[i].messageID == messageID { itemList[i].routing = routing }
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

    /// Every saved digest, in insertion order, rebuilt from its results.
    public func allDigests() -> [Digest] { digestRows.map(aggregate) }

    /// Every queue item across jobs, in insertion order.
    public func allItems() -> [JobItem] { itemList }
    /// Ids marked processed.
    public func processedIDs() -> Set<String> { Set(processed.keys) }
}
