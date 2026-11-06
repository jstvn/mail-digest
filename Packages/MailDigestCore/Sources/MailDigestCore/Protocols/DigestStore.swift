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

    /// Upserts the digest row (id, createdAt, headline) and REPLACES its per-email results with those
    /// derived from `digest`'s content (see `EmailResult.results(from:)`). The runner uses it to create a
    /// digest and to store the headline; per-email progress goes through `appendEmailResult`.
    func save(_ digest: Digest) async throws
    /// Atomically upserts one email's result, keyed by (digest, email id): a new email appends after the
    /// existing results, a known one is replaced in place. Throws `DigestStoreError.digestNotFound` if the
    /// digest was never saved.
    func appendEmailResult(_ result: EmailResult, to digestID: UUID) async throws
    /// Removes the given emails' results from a digest (used by "Retry failed").
    func deleteEmailResults(_ emailIDs: Set<String>, from digestID: UUID) async throws
    /// The most recent digest, if any, rebuilt from its results.
    func latestDigest() async throws -> Digest?
    /// The digest with this id (a job's digest shares the job's id), so a resumed job keeps appending to it.
    func digest(id: UUID) async throws -> Digest?
    /// Suggestions created since the given date, for validator dedupe (rule 6).
    func recentSuggestions(since: Date) async throws -> [Suggestion]
    /// Replaces a suggestion by id inside whichever digest holds it.
    func update(_ suggestion: Suggestion) async throws
    /// Every retained digest, for the daily retention cleanup.
    func retainedDigests() async throws -> [Digest]

    // MARK: Pinned info

    /// Sets the pinned flag of one email's info item and nothing else (no digest rewrite). A digest or
    /// email without an info item is ignored.
    func setPinned(_ pinned: Bool, infoID: String, digestID: UUID) async throws
    /// Every pinned info item across retained digests, newest digest first, with its owning digest.
    func pinnedInfo() async throws -> [PinnedInfo]

    // MARK: Mail dispositions (Q39, Q42)

    /// Upserts disposition records, keyed by (digest, email, kind). Throws
    /// `DigestStoreError.digestNotFound` if a record's digest was never saved.
    func recordDispositions(_ dispositions: [MailDisposition]) async throws
    /// Removes one kind of disposition for the given emails of a digest (for example `moved` after Undo).
    func removeDispositions(_ kind: MailDispositionKind, emailIDs: Set<String>, digestID: UUID) async throws
    /// Every disposition recorded for a digest.
    func dispositions(digestID: UUID) async throws -> [MailDisposition]

    // MARK: Retention

    /// Deletes the planned digests (with their results and dispositions) and jobs (with their items).
    /// Never touches processed ids or decisions (Q18, Q21).
    func apply(_ plan: RetentionPlan) async throws

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
    /// Applies a resume's queue refresh in ONE transaction: skips and relocates the listed open (queued or
    /// processing) items, appends the new headers after the job's last item (positions continue), and sets
    /// the job's `scopeTo` when given. Finished items are never touched. Either everything is applied or,
    /// on error, nothing.
    func applyResumeRefresh(_ refresh: QueueRefresh) async throws
    /// Stores the outcome text, time taken and finish time for a finished item.
    func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws
    /// Moves a job's `failed` items back to `queued` with attempts reset to 0 (lastError is kept),
    /// and returns the updated items. Used by "Retry failed".
    func requeueFailed(job jobID: UUID) async throws -> [JobItem]
    /// Moves every `processing` item back to `queued` and returns how many changed.
    func requeueInterrupted() async throws -> Int
}
