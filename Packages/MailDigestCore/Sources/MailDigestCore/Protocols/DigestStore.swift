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

    // MARK: Summaries and paging (Q56)

    /// One lightweight summary per retained digest, newest first (ties: later save first). Never decodes
    /// suggestion, info or evidence payloads. A digest without a job row counts as `.daily`.
    func digestSummaries() async throws -> [DigestSummary]
    /// Pending and failed suggestions, ordered by digest `createdAt` descending, then result ordinal, then
    /// position in the result. `limit`/`offset` page the ordered list; only the returned page is decoded.
    func actionableSuggestions(_ query: SuggestionQuery) async throws -> [SuggestionRecord]
    /// Approved and dismissed suggestions ordered by `decidedAt` descending, using the owning digest's
    /// `createdAt` where `decidedAt` is nil, then by digest recency, result ordinal and position.
    func decidedSuggestions(limit: Int, offset: Int) async throws -> [SuggestionRecord]

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

    /// Inserts a new job and its `created` event (at `job.createdAt`) in one transaction.
    func createJob(_ job: Job) async throws
    /// Replaces a job by id and, when given, appends `event` in the same transaction. A missing job is
    /// ignored (and no event is written). `updateJob(_:)` is the same without an event.
    func updateJob(_ job: Job, event: JobEvent?) async throws
    /// All jobs, newest first.
    func jobs() async throws -> [Job]
    /// A job's lifecycle events ordered by `(at, id)`.
    func jobEvents(job jobID: UUID) async throws -> [JobEvent]
    /// One keyset page of jobs, `(createdAt DESC, id DESC)`, strictly after `query.before`. The `path`
    /// filter keeps jobs with an item executed by that provider. Never uses an offset.
    func activityJobs(_ query: ActivityQuery) async throws -> [Job]

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
    func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?, startedAt: Date?) async throws
    /// Applies a resume's queue refresh in ONE transaction: skips and relocates the listed open (queued or
    /// processing) items, appends the new headers after the job's last item (positions continue), and sets
    /// the job's `scopeTo` when given. Finished items are never touched. Either everything is applied or,
    /// on error, nothing.
    func applyResumeRefresh(_ refresh: QueueRefresh) async throws
    /// Stores the outcome text, time taken and finish time for a finished item. A non-nil `routing` is
    /// written in the same transaction, with `provider` set to `routing.execution?.provider`.
    func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date,
                           routing: RoutingProvenance?) async throws
    /// Writes the item's routing (assessment known, execution usually nil) as soon as it is decided,
    /// without touching its state. Matches the job's item by message id; unknown items are ignored.
    func recordAssessment(job jobID: UUID, messageID: String, routing: RoutingProvenance) async throws
    /// Moves a job's `failed` items back to `queued` with attempts reset to 0 (lastError is kept),
    /// and returns the updated items. Used by "Retry failed".
    func requeueFailed(job jobID: UUID) async throws -> [JobItem]
    /// Moves every `processing` item back to `queued` and returns how many changed.
    func requeueInterrupted() async throws -> Int
}

public extension DigestStore {
    /// Replaces a job by id without recording an event.
    func updateJob(_ job: Job) async throws { try await updateJob(job, event: nil) }

    /// `setItemState` without a start time; `startedAt` is only set when moving to `.processing`.
    func setItemState(_ itemID: UUID, _ state: JobItemState, error: String?) async throws {
        try await setItemState(itemID, state, error: error, startedAt: nil)
    }

    /// `recordItemOutcome` without routing.
    func recordItemOutcome(_ itemID: UUID, outcome: String, seconds: Double, finishedAt: Date) async throws {
        try await recordItemOutcome(itemID, outcome: outcome, seconds: seconds, finishedAt: finishedAt, routing: nil)
    }
}
