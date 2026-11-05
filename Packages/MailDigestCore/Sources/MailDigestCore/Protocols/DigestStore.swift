import Foundation

public protocol DigestStore: Sendable {
    // MARK: Runs and processed mail

    /// When the last digest run happened, if ever.
    func lastRunDate() async throws -> Date?
    /// Whether this message id was already processed in any run.
    func isProcessed(_ messageID: String) async throws -> Bool
    /// Records a message as processed so it is never reprocessed.
    func markProcessed(_ email: ProcessedEmail) async throws

    // MARK: Digests and suggestions

    /// Upserts by id. The pipeline re-saves after every email so partial results survive.
    func save(_ digest: Digest) async throws
    /// The most recent digest, if any.
    func latestDigest() async throws -> Digest?
    /// The digest with this id (a job's digest shares the job's id), so a resumed job keeps appending to it.
    func digest(id: UUID) async throws -> Digest?
    /// Suggestions created since the given date, for validator dedupe (rule 6).
    func recentSuggestions(since: Date) async throws -> [Suggestion]
    /// Replaces a suggestion by id inside whichever digest holds it.
    func update(_ suggestion: Suggestion) async throws

    // MARK: Decisions

    /// Stores an approve or dismiss decision.
    func recordDecision(_ decision: Decision) async throws
    /// All decisions for one sender, for learned rules. Decisions are keyed by the lowercased
    /// address (see `MailFilter.address(from:)`), not by "Name <addr>".
    func decisions(for sender: String) async throws -> [Decision]

    // MARK: Jobs

    /// Inserts a new job.
    func createJob(_ job: Job) async throws
    /// Replaces a job by id.
    func updateJob(_ job: Job) async throws
    /// All jobs, newest first.
    func jobs() async throws -> [Job]

    // MARK: Queue

    /// Appends items in order; positions continue from 1 (or after the job's last item).
    func enqueue(_ headers: [MessageHeader], job jobID: UUID) async throws
    /// True if an item with this message id is queued or processing in any job.
    func isQueued(_ messageID: String) async throws -> Bool
    /// Up to `limit` queued items, lowest position first.
    func nextQueued(job jobID: UUID, limit: Int) async throws -> [JobItem]
    /// All items of a job, by position.
    func items(job jobID: UUID) async throws -> [JobItem]
    /// Sets an item's state and stores `error` as lastError. Attempts count genuine item failures only
    /// (Q22): moving to `.queued` or `.failed` with a non-nil `error` increments them. Starting an item,
    /// pausing, stopping, recovery and provider-wide outages (requeued with `error: nil`) do not.
    func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?) async throws
    /// Stores the outcome text, time taken and finish time for a finished item.
    func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws
    /// Moves a job's `failed` items back to `queued` with attempts reset to 0 (lastError is kept),
    /// and returns the updated items. Used by "Retry failed".
    func requeueFailed(job jobID: UUID) async throws -> [JobItem]
    /// Moves every `processing` item back to `queued` and returns how many changed.
    func requeueInterrupted() async throws -> Int
}
