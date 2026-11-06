import Foundation

/// Tunables for `JobRunner`; the defaults match the spec.
public struct RunnerSettings: Sendable {
    public var timeZone: TimeZone
    public var filter: MailFilter
    public var dailyMailboxes: [MailboxRef]
    /// Daily jobs never look further back than this.
    public var lookbackCap: TimeInterval
    /// Daily jobs only: keep at most this many of the newest emails.
    public var maxEmailsPerRun: Int?
    public var fetchBatchSize: Int
    public var enqueueChunkSize: Int
    public var maxAttempts: Int
    /// Pause between asking Mail to check for new mail and listing headers.
    public var waitAfterCheck: Duration
    /// Minimum injected-clock time between throttled progress updates.
    public var progressInterval: TimeInterval
    /// Presentation threshold for the Daily digest (Q16). The runner never truncates by it; the UI uses it
    /// with `SuggestionValidator.capDigest` to decide what to show first.
    public var dailyDigestCap: Int

    public init(timeZone: TimeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current,
                filter: MailFilter = MailFilter(),
                dailyMailboxes: [MailboxRef] = [],
                lookbackCap: TimeInterval = 48 * 3600,
                maxEmailsPerRun: Int? = nil,
                fetchBatchSize: Int = 10,
                enqueueChunkSize: Int = 200,
                maxAttempts: Int = 3,
                waitAfterCheck: Duration = .seconds(30),
                progressInterval: TimeInterval = 0.5,
                dailyDigestCap: Int = 25) {
        self.timeZone = timeZone
        self.filter = filter
        self.dailyMailboxes = dailyMailboxes
        self.lookbackCap = lookbackCap
        self.maxEmailsPerRun = maxEmailsPerRun
        self.fetchBatchSize = fetchBatchSize
        self.enqueueChunkSize = enqueueChunkSize
        self.maxAttempts = maxAttempts
        self.waitAfterCheck = waitAfterCheck
        self.progressInterval = progressInterval
        self.dailyDigestCap = dailyDigestCap
    }
}

public enum JobRunnerError: Error, Sendable, Equatable {
    /// A job is already listing or processing.
    case alreadyRunning
    case jobNotFound
    /// The model provider failed its health check (Q25); the message says how to fix it.
    case providerUnavailable(String)
    /// A resource rule blocks this kind of job right now (Q43). The job was left (or created) paused with
    /// this reason and resumes by itself once the rule clears in this session (Q44).
    case resourceBlocked(PauseReason)
}

/// Runs persisted jobs one email at a time with a checkpoint after each email.
///
/// Only one processing loop exists at a time. Pause takes effect between emails; "pause now" and
/// stop cancel the in-flight email, which goes back to `queued` without counting as a failure.
public actor JobRunner {
    /// Throttled progress updates; state changes and job end are always delivered.
    public nonisolated let progress: AsyncStream<JobProgress>

    private let source: any MailSource
    private let store: any DigestStore
    private let notifier: any Notifier
    private let clock: any Clock
    private let settings: RunnerSettings
    private let pipeline: DigestPipeline
    private let llm: any LLMClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private let continuation: AsyncStream<JobProgress>.Continuation

    // Actor-confined mutable state.
    private var busy = false
    private var loopTask: Task<Void, Never>?
    private var run: RunState?
    private var resumeAfter: UUID?
    private var pauseRequested = false
    private var stopRequested = false
    private var autoPauseRequested = false
    private var autoPauseReason: PauseReason?
    /// Jobs this runner auto-paused for a resource reason in this session; only these are auto-resumed.
    private var autoPausedThisSession: Set<UUID> = []
    /// The resource rules that apply now, by job kind; Start and Resume check them first (Q43).
    private var resourceBlockers: [JobKind: PauseReason] = [:]
    private var cancelRequested = false
    private var itemActive = false
    private var inFlight: Task<EmailOutcome, Error>?
    private var lastEmit: Date?

    /// Everything the loop tracks for the job it is working on.
    private final class RunState {
        var job: Job
        var digest: Digest
        var stage: JobStage = .listing
        var current: JobItemSummary?
        var lastFinished: JobItemSummary?
        var nextUp: JobItemSummary?
        var counts: [MailboxRef: MailboxProgress] = [:]
        var recentSeconds: [Double] = []
        /// Rest of the fetched batch; its first element is the next email.
        var queueHead: [JobItem] = []
        /// Set when the loop has decided to pause, so `resume()` can no longer cancel the pause.
        var committed = false
        /// Whether the digest row exists in the store. Created lazily with the first result so an empty
        /// job leaves no digest (Q24).
        var digestStored: Bool

        init(job: Job, digest: Digest, digestStored: Bool) {
            self.job = job
            self.digest = digest
            self.digestStored = digestStored
        }
    }

    private enum LoopOutcome { case finished, paused, failed }

    public init(source: any MailSource, llm: any LLMClient, store: any DigestStore, notifier: any Notifier,
                clock: any Clock, settings: RunnerSettings,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source
        self.store = store
        self.notifier = notifier
        self.clock = clock
        self.settings = settings
        self.sleep = sleep
        self.llm = llm
        self.pipeline = DigestPipeline(llm: llm, filter: settings.filter, timeZone: settings.timeZone)
        let (stream, continuation) = AsyncStream<JobProgress>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.progress = stream
        self.continuation = continuation
    }

    // MARK: Starting

    /// Lists, filters and queues the plan's mail, then starts processing in the background and returns.
    /// The queued set equals `preview(plan).toProcess`. The plan's `to` is fixed when the user confirms the
    /// preview; start never re-reads "now" for a confirmed plan, so mail arriving later goes to the next Daily job.
    /// Throws `alreadyRunning` if a job is active; use `startDaily()` to run a Daily job over a Backlog job.
    public func start(_ plan: JobPlan) async throws {
        try claim()
        resumeAfter = nil
        do {
            try await preflight()
        } catch {
            busy = false
            throw error
        }
        try await begin(plan)
    }

    /// Starts the Daily job: mail since the last run, at most `lookbackCap` back. A running Backlog job
    /// is auto-paused first and resumes by itself once the Daily job finishes.
    public func startDaily() async throws {
        var backlogToResume: UUID?
        if busy {
            guard loopTask != nil, let run, run.job.kind == .backlog else { throw JobRunnerError.alreadyRunning }
            backlogToResume = run.job.id
            autoPauseRequested = true
            autoPauseReason = .dailyJob
            pauseRequested = true
            run.job.state = .pausing
            emit(force: true)
            await waitUntilIdle()
        }
        try claim()
        do {
            let now = clock.now()
            let floor = now.addingTimeInterval(-settings.lookbackCap)
            // The last Daily job's scope end, not `store.lastRunDate()`: a Backlog digest also moves the
            // store's last-run date and would make the next Daily job skip mail.
            let lastDaily = try await store.jobs()
                .filter { $0.kind == .daily && $0.state != .failed && $0.state != .listing }
                .map(\.scopeTo).max()
            let from = max(lastDaily ?? floor, floor)
            try await preflight()
            // Mail not running is not fatal here; listing will report it if it matters.
            if (try? await source.checkForNewMail()) != nil { try await sleep(settings.waitAfterCheck) }
            let plan = JobPlan(kind: .daily, mailboxes: settings.dailyMailboxes, from: from, to: clock.now(),
                               excludedMessageIDs: [])
            resumeAfter = backlogToResume
            try await begin(plan)
        } catch {
            busy = false
            resumeAfter = nil
            throw error
        }
    }

    // MARK: Preview

    /// Lists headers for the plan and reports what `start(plan)` would queue. Queues nothing and creates no job.
    public func preview(_ plan: JobPlan) async throws -> JobPreview {
        let (headers, unavailable) = try await listHeaders(plan)
        let builder = JobPreviewBuilder(filter: settings.filter)
        return builder.build(plan: plan, headers: headers, isProcessedOrQueued: unavailable,
                             averageSecondsPerEmail: try await rollingAverage(),
                             limit: dailyLimit(plan))
    }

    /// Mean seconds of the last 20 finished emails across all jobs, or nil without history.
    private func rollingAverage() async throws -> Double? {
        var finished: [JobItem] = []
        for job in try await store.jobs() {
            finished += try await store.items(job: job.id).filter { $0.state == .done && $0.seconds != nil }
        }
        finished.sort { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        let recent = finished.suffix(20).compactMap(\.seconds)
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }

    private func dailyLimit(_ plan: JobPlan) -> Int? { plan.kind == .daily ? settings.maxEmailsPerRun : nil }

    /// Lists every mailbox and finds which listed ids are already processed or queued.
    private func listHeaders(_ plan: JobPlan) async throws -> ([MailboxRef: [MessageHeader]], Set<String>) {
        var headers: [MailboxRef: [MessageHeader]] = [:]
        var unavailable = Set<String>()
        for mailbox in plan.mailboxes where headers[mailbox] == nil {
            let listed = try await source.listHeaders(in: mailbox, from: plan.from, to: plan.to)
            headers[mailbox] = listed
            for h in listed where !plan.excludedMessageIDs.contains(h.id) {
                let processed = try await store.isProcessed(h.id)
                if processed { unavailable.insert(h.id) } else if try await store.isQueued(h.id) { unavailable.insert(h.id) }
            }
        }
        return (headers, unavailable)
    }

    /// The one listing-and-dedupe path shared by `preview` and `start`.
    private func select(_ plan: JobPlan) async throws -> JobPreviewBuilder.Selection {
        let (headers, unavailable) = try await listHeaders(plan)
        return JobPreviewBuilder.select(plan: plan, headers: headers, unavailable: unavailable,
                                        limit: dailyLimit(plan))
    }

    // MARK: Retry

    /// Requeues the job's failed emails (attempts reset), removes their "failed: ..." entries from the job's
    /// digest, then resumes the job. Returns how many were requeued. Throws `alreadyRunning` if a job is active.
    @discardableResult
    public func retryFailed(jobID: UUID) async throws -> Int {
        guard !busy else { throw JobRunnerError.alreadyRunning }
        guard var job = try await store.jobs().first(where: { $0.id == jobID }) else { throw JobRunnerError.jobNotFound }
        let requeued = try await store.requeueFailed(job: jobID)
        guard !requeued.isEmpty else { return 0 }
        // A failed item's only result is its "failed: ..." skip entry, so dropping the result removes it
        // and keeps the digest's email count consistent.
        try await store.deleteEmailResults(Set(requeued.map(\.messageID)), from: jobID)
        job.state = .paused
        job.clearPause()
        job.totals.failed = max(0, job.totals.failed - requeued.count)
        job.totals.queued += requeued.count
        try await store.updateJob(job)
        try await resume(jobID: jobID)
        return requeued.count
    }

    // MARK: Controls

    /// Finishes the current email, then pauses before the next one.
    public func pause() {
        guard let run, loopTask != nil, !pauseRequested, !stopRequested else { return }
        pauseRequested = true
        run.job.state = .pausing
        emit(force: true)
    }

    /// Cancels the in-flight email (it returns to `queued`) and pauses.
    public func pauseNow() {
        guard let run, loopTask != nil, !stopRequested else { return }
        pauseRequested = true
        run.job.state = .pausing
        cancelInFlight()
        emit(force: true)
    }

    /// Pauses the active job after the current email because of a resource rule (battery, Low Power Mode,
    /// heat, quiet hours), recording the reason. Does nothing when no job runs or one is already pausing.
    public func autoPause(_ reason: PauseReason) {
        guard let run, loopTask != nil, !pauseRequested, !stopRequested else { return }
        autoPauseRequested = true
        autoPauseReason = reason
        pauseRequested = true
        run.job.state = .pausing
        emit(force: true)
    }

    /// Resumes the newest job this runner auto-paused for a resource reason that has cleared (its kind is
    /// not in `blocked`). A job the user paused or stopped, one paused for a Daily job, or one auto-paused
    /// in an earlier session is never resumed here. Returns the resumed job id.
    @discardableResult
    public func autoResume(blocked: [JobKind: PauseReason]) async throws -> UUID? {
        resourceBlockers = blocked
        guard !busy else { return nil }
        let candidate = try await store.jobs().first {
            autoPausedThisSession.contains($0.id) && $0.state == .paused && $0.pauseReason != nil
                && blocked[$0.kind] == nil
        }
        guard let candidate else { return nil }
        try await resume(jobID: candidate.id)
        return candidate.id
    }

    /// Applies the current resource rules: pauses the active job if its kind is blocked, otherwise
    /// auto-resumes a job paused for a reason that has cleared.
    public func applyResourceRules(_ blocked: [JobKind: PauseReason]) async throws {
        resourceBlockers = blocked
        if let run, loopTask != nil {
            if let reason = blocked[run.job.kind] { autoPause(reason) }
            return
        }
        try await autoResume(blocked: blocked)
    }

    /// Records the resource rules that apply now without pausing or resuming anything. Call it before
    /// `start`, `startDaily`, `resume` or `retryFailed` so they see the current rules (Q43).
    public func setResourceBlockers(_ blocked: [JobKind: PauseReason]) {
        resourceBlockers = blocked
    }

    /// Cancels the in-flight email (it returns to `queued`) and ends the run. The job is persisted as
    /// `.stopped` (Q15): resumable by hand from Past Jobs with `resume(jobID:)`, never automatically.
    public func stop() {
        guard let run, loopTask != nil else { return }
        stopRequested = true
        run.job.state = .stopping
        cancelInFlight()
        emit(force: true)
    }

    /// Resumes the given paused job, or the most recent paused one. Also used after a restart.
    public func resume(jobID: UUID? = nil) async throws {
        if let run, loopTask != nil {
            if let jobID, jobID != run.job.id { throw JobRunnerError.alreadyRunning }
            if run.committed {
                await waitUntilIdle()
            } else if pauseRequested && !stopRequested, let reason = resourceBlockers[run.job.kind] {
                // Q43: Resume never overrides an active resource rule; let the pause go ahead as an auto-pause.
                autoPauseRequested = true
                autoPauseReason = reason
                throw JobRunnerError.resourceBlocked(reason)
            } else if pauseRequested && !stopRequested {
                // The loop hasn't paused yet, so just withdraw the request.
                pauseRequested = false
                autoPauseRequested = false
                autoPauseReason = nil
                cancelRequested = false
                run.job.state = .running
                emit(force: true)
                return
            } else if !pauseRequested && !stopRequested {
                return // already running
            } else {
                await waitUntilIdle()
            }
        }
        try claim()
        do {
            let all = try await store.jobs()
            let job: Job?
            if let jobID {
                guard let found = all.first(where: { $0.id == jobID }) else { throw JobRunnerError.jobNotFound }
                job = [.paused, .failed, .stopped].contains(found.state) ? found : nil
            } else {
                job = all.first { $0.state == .paused }
            }
            guard var job else { busy = false; return }
            // Q43: an active resource rule keeps the job paused; it resumes once the rule clears (Q44). A stopped
            // or failed job keeps its state, so it is never resumed without the user (Q48).
            if let reason = resourceBlockers[job.kind] {
                if job.state == .paused { try await parkBlocked(&job, reason: reason) }
                throw JobRunnerError.resourceBlocked(reason)
            }
            // Re-check the provider before resuming (Q25), so a still-down Ollama fails fast.
            try await preflight()
            // Daily mail may have been deleted or filed since the pause; never process what is gone.
            if job.kind == .daily { try await refreshQueue(of: job) }
            job.state = .running
            job.clearPause()
            job.lastError = nil
            autoPausedThisSession.remove(job.id)
            try await store.updateJob(job)
            resetFlags()
            resumeAfter = nil
            run = try await loadRun(job)
            if let run { try await store.updateJob(run.job) }
            launch(kind: job.kind)
        } catch {
            busy = false
            run = nil
            throw error
        }
    }

    /// Call once at launch: items left `processing` go back to `queued` and interrupted jobs become `.paused`.
    public func recoverOnLaunch() async throws {
        _ = try await store.requeueInterrupted()
        for var job in try await store.jobs() where [.running, .pausing, .listing, .stopping].contains(job.state) {
            // An interrupted Stop stays a Stop (Q15); everything else was never asked to stop, so it is paused.
            job.state = job.state == .stopping ? .stopped : .paused
            try await store.updateJob(job)
        }
    }

    /// Returns when no processing loop is running.
    public func waitUntilIdle() async {
        while let task = loopTask { await task.value }
    }

    // MARK: Start helpers

    private func claim() throws {
        guard !busy else { throw JobRunnerError.alreadyRunning }
        busy = true
    }

    private func resetFlags() {
        pauseRequested = false
        stopRequested = false
        autoPauseRequested = false
        autoPauseReason = nil
        cancelRequested = false
        itemActive = false
    }

    /// Phase 1: list headers, drop what shouldn't be queued, enqueue in chunks, then launch the loop.
    private func begin(_ plan: JobPlan) async throws {
        resetFlags()
        let now = clock.now()
        var job = Job(id: UUID(), kind: plan.kind, mailboxes: plan.mailboxes, scopeFrom: plan.from,
                      scopeTo: plan.to, state: .listing, createdAt: now,
                      totals: JobTotals(queued: 0, done: 0, failed: 0, skipped: 0), autoPaused: false)
        do {
            try await store.createJob(job)
            run = RunState(job: job, digest: Digest(id: job.id, createdAt: now, headline: "", emailCount: 0,
                                                    suggestions: [], info: [], skipped: []), digestStored: false)
            emit(force: true)

            let headers = try await select(plan).toProcess

            var index = 0
            while index < headers.count {
                let end = min(index + max(1, settings.enqueueChunkSize), headers.count)
                try await store.enqueue(Array(headers[index..<end]), job: job.id)
                index = end
            }

            job.totals.queued = headers.count
            let digest = Digest(id: job.id, createdAt: now, headline: "", emailCount: 0,
                                suggestions: [], info: [], skipped: [])
            // Q43: a job created while a resource rule applies is stored paused before any email runs.
            if let reason = resourceBlockers[plan.kind] {
                try await parkBlocked(&job, reason: reason)
                try await parkPreemptedBacklog()
                let parked = try await loadRun(job, newDigest: digest)
                if let next = try await store.nextQueued(job: job.id, limit: 1).first {
                    parked.nextUp = summary(next, outcome: nil)
                }
                run = parked
                emit(force: true)
                run = nil
                busy = false
                return
            }
            job.state = .running
            try await store.updateJob(job)
            run = try await loadRun(job, newDigest: digest)
            launch(kind: plan.kind)
        } catch {
            job.state = .failed
            try? await store.updateJob(job)
            busy = false
            run = nil
            throw error
        }
    }

    /// Rebuilds counters from the persisted items so a resumed job reports correct totals.
    private func loadRun(_ job: Job, newDigest: Digest? = nil) async throws -> RunState {
        var job = job
        let items = try await store.items(job: job.id)
        var digest: Digest
        var stored = false
        if let newDigest {
            digest = newDigest
        } else if let saved = try await store.digest(id: job.id) {
            digest = saved
            stored = true
        } else {
            digest = Digest(id: job.id, createdAt: clock.now(), headline: "", emailCount: 0,
                            suggestions: [], info: [], skipped: [])
        }
        let state = RunState(job: job, digest: digest, digestStored: stored)
        var totals = JobTotals(queued: 0, done: 0, failed: 0, skipped: 0)
        for item in items {
            var c = state.counts[item.mailbox] ?? MailboxProgress(done: 0, total: 0)
            c.total += 1
            switch item.state {
            case .queued, .processing: totals.queued += 1
            case .done: totals.done += 1; c.done += 1
            case .failed: totals.failed += 1; c.done += 1
            case .skipped: totals.skipped += 1; c.done += 1
            }
            state.counts[item.mailbox] = c
        }
        job.totals = totals
        state.job = job
        state.recentSeconds = Array(items.filter { $0.state == .done }.compactMap(\.seconds).suffix(20))
        if let last = items.last(where: { $0.state != .queued && $0.state != .processing }) {
            state.lastFinished = summary(last, outcome: last.outcome)
        }
        return state
    }

    private func launch(kind: JobKind) {
        let priority: TaskPriority = kind == .daily ? .utility : .background
        loopTask = Task(priority: priority) { [self] in await self.runChain() }
        emit(force: true)
    }

    /// Runs the current job, then the auto-paused Backlog job if a Daily job just finished.
    private func runChain() async {
        while true {
            let outcome = await runLoop()
            guard outcome == .finished, let next = resumeAfter else { break }
            resumeAfter = nil
            do {
                guard var job = try await store.jobs().first(where: { $0.id == next }), job.state == .paused else { break }
                // The hand-off is a resume too: a rule that applies now keeps the Backlog job paused (Q43).
                if let reason = resourceBlockers[job.kind] {
                    try await parkBlocked(&job, reason: reason)
                    break
                }
                job.state = .running
                job.clearPause()
                try await store.updateJob(job)
                resetFlags()
                run = try await loadRun(job)
            } catch { break }
        }
        run = nil
        resumeAfter = nil
        busy = false
        loopTask = nil
    }

    // MARK: Resource rules (Q43)

    /// Stores the job as auto-paused for `reason` and remembers it so it auto-resumes in this session once
    /// the rule clears (Q44).
    private func parkBlocked(_ job: inout Job, reason: PauseReason) async throws {
        job.state = .paused
        job.autoPaused = true
        job.pauseReason = reason
        autoPausedThisSession.insert(job.id)
        try await store.updateJob(job)
    }

    /// A Daily job that could not start leaves the Backlog job it preempted waiting for the Daily job, which
    /// would never hand back. Re-park it under its own resource rule, if any, so it can still auto-resume.
    private func parkPreemptedBacklog() async throws {
        guard let id = resumeAfter else { return }
        resumeAfter = nil
        guard var job = try await store.jobs().first(where: { $0.id == id }), job.state == .paused else { return }
        if let reason = resourceBlockers[job.kind] { try await parkBlocked(&job, reason: reason) }
    }

    // MARK: Refresh before resuming a Daily job

    /// Outcome text for a queued Daily email that is no longer in the job's mailboxes and scope.
    static let goneFromMailboxOutcome = "skipped: no longer in mailbox"

    /// Re-lists the job's mailboxes over its original `[scopeFrom, scopeTo)` range and reconciles the queue
    /// by canonical Message-ID. A queued email still listed stays queued (pointing at the mailbox it is in
    /// now); one that is gone is skipped without a model call, a failure or an attempt. Finished items,
    /// their results and the scope are untouched, and new mail is not added. Any listing error aborts
    /// before anything changes: a failed listing never proves an email is missing.
    private func refreshQueue(of job: Job) async throws {
        let items = try await store.items(job: job.id).filter { $0.state == .queued || $0.state == .processing }
        guard !items.isEmpty else { return }

        func key(_ id: String) -> String { MessageID.canonical(id) ?? id }
        func sameMailbox(_ a: MailboxRef, _ b: MailboxRef) -> Bool { a.account == b.account && a.name == b.name }

        // List everything first, so a failure part-way leaves the queue as it was.
        var listed: [String: [MessageHeader]] = [:]
        for mailbox in job.mailboxes {
            for header in try await source.listHeaders(in: mailbox, from: job.scopeFrom, to: job.scopeTo) {
                listed[key(header.id), default: []].append(header)
            }
        }

        let now = clock.now()
        for item in items {
            guard let found = listed[key(item.messageID)], let first = found.first else {
                try await store.recordItemOutcome(item.id, outcome: Self.goneFromMailboxOutcome, seconds: 0,
                                                  finishedAt: now)
                try await store.setItemState(item.id, .skipped, error: nil)
                continue
            }
            // Still where it was queued: keep the stored mailbox and locator.
            if found.contains(where: { sameMailbox($0.mailboxRef, item.mailbox) }) { continue }
            try await store.updateItemLocation(item.id, mailbox: first.mailboxRef,
                                               storeRowID: first.sourceReference.storeRowID)
        }
    }

    // MARK: Processing loop

    private func runLoop() async -> LoopOutcome {
        guard let run else { return .failed }
        do {
            return try await loop(run)
        } catch {
            // Provider outage, store or Mail failure: stop the loop but keep the queue so the job can be
            // resumed by id once the cause is fixed.
            run.job.state = .failed
            run.job.lastError = (error as? ProviderFailure)?.message ?? Self.shortReason(error)
            run.current = nil
            try? await store.updateJob(run.job)
            emit(force: true)
            return .failed
        }
    }

    private func loop(_ run: RunState) async throws -> LoopOutcome {
        while true {
            if pauseRequested || stopRequested { return try await commitPause(run) }

            run.stage = .fetching
            run.current = nil
            let batch = try await store.nextQueued(job: run.job.id, limit: settings.fetchBatchSize)
            if batch.isEmpty { return try await finish(run) }
            emit(force: false)

            // One fetch call per mailbox, so each call stays within the batch size.
            var order: [MailboxRef] = []
            var refsByMailbox: [MailboxRef: [MailMessageReference]] = [:]
            for item in batch {
                if refsByMailbox[item.mailbox] == nil { order.append(item.mailbox) }
                refsByMailbox[item.mailbox, default: []].append(item.reference)
            }
            var fetched: [String: EmailMessage] = [:]
            for mailbox in order {
                for email in try await source.fetchMessages(references: refsByMailbox[mailbox] ?? [], in: mailbox) {
                    fetched[email.id] = email
                }
            }

            run.queueHead = batch
            while !run.queueHead.isEmpty {
                if pauseRequested || stopRequested { break }
                let item = run.queueHead.removeFirst()
                let requeued = try await handle(item, email: fetched[item.messageID], run: run)
                // A requeued item sorts before the rest of the batch, so refetch from the store.
                if requeued { break }
            }
            run.queueHead = []
        }
    }

    /// Skip reason recorded when a fetched message has no readable body text.
    static let unreadableBodyReason = "no readable body"

    /// Processes one item. Returns true if it went back to `queued`.
    private func handle(_ item: JobItem, email: EmailMessage?, run: RunState) async throws -> Bool {
        guard let email else {
            let reason = "not found in Mail"
            try await persist(EmailResult(emailID: item.messageID, skipped: SkippedEmail(
                id: item.messageID, sender: item.sender, subject: item.subject, reason: reason)), in: run)
            try await complete(run, item, state: .skipped, outcome: "skipped: \(reason)", seconds: nil, error: reason)
            return false
        }
        // Guards against a crash between "marked processed" and "item done".
        if try await store.isProcessed(item.messageID) {
            try await complete(run, item, state: .skipped, outcome: "skipped: already processed", seconds: nil, error: nil)
            return false
        }
        // An empty body (for example a message Mail never downloaded) must not reach the model. It is
        // skipped without consuming an attempt and is not marked processed, so a later job can retry it.
        if email.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reason = Self.unreadableBodyReason
            try await persist(EmailResult(emailID: item.messageID, skipped: SkippedEmail(
                id: item.messageID, sender: item.sender, subject: item.subject, reason: reason)), in: run)
            try await complete(run, item, state: .skipped, outcome: "skipped: \(reason)", seconds: nil, error: reason)
            return false
        }

        cancelRequested = false
        itemActive = true
        run.current = summary(item, outcome: nil)
        run.stage = .summarising
        defer { itemActive = false; inFlight = nil }
        try await store.setItemState(item.id, .processing, error: nil)
        emit(force: false)

        let started = clock.now()
        let today = started
        let recent = try await recentSuggestions(for: run, today: today)
        let approved = try await store.decisions(for: MailFilter.address(from: email.sender))
            .contains { $0.action == .approved }
        let pipeline = self.pipeline
        let priority: TaskPriority = run.job.kind == .daily ? .utility : .background
        let child = Task(priority: priority) {
            try await pipeline.process(email, today: today, recentSuggestions: recent,
                                       senderHasApprovedDecision: approved)
        }
        inFlight = child
        // Pause-now may have arrived while we were fetching context.
        if cancelRequested { child.cancel() }
        let result = await child.result
        inFlight = nil
        itemActive = false

        switch result {
        case .success(let outcome):
            run.stage = .saving
            // Every validated suggestion is kept (Q16); the Daily cap is presentation-only.
            // Order matters for crash safety: result first, then "processed", then the item state.
            try await persist(EmailResult(emailID: email.id, info: outcome.info, suggestions: outcome.suggestions,
                                          skipped: outcome.skipped), in: run)
            let seconds = clock.now().timeIntervalSince(started)
            try await store.markProcessed(ProcessedEmail(id: email.id, receivedAt: email.receivedAt,
                                                         tier: outcome.tier, processedAt: clock.now()))
            try await complete(run, item, state: outcome.tier == .skip ? .skipped : .done,
                               outcome: outcome.summaryText, seconds: seconds, error: nil,
                               countsTowardSpeed: outcome.tier != .skip)
            return false

        case .failure(let error):
            if cancelRequested || error is CancellationError {
                try await store.setItemState(item.id, .queued, error: nil)
                run.current = nil
                return true
            }
            // Q25: anything but a malformed answer may be the provider rather than this email. If the
            // provider is unhealthy, stop the whole job and return the item without spending an attempt.
            if Self.mightBeProviderFailure(error), let outage = await providerOutage() {
                try await store.setItemState(item.id, .queued, error: nil)
                run.current = nil
                throw ProviderFailure(message: outage)
            }
            let reason = Self.shortReason(error)
            // `item.attempts` was read before this attempt started. A timed-out extraction already
            // waited the full (long) timeout, so it is not retried automatically (Q35); the user can
            // still retry it with `retryFailed(jobID:)`.
            if item.attempts + 1 >= settings.maxAttempts || error as? LLMError == .timedOut {
                try await persist(EmailResult(emailID: item.messageID, skipped: SkippedEmail(
                    id: item.messageID, sender: item.sender, subject: item.subject, reason: "failed: \(reason)")),
                                  in: run)
                try await complete(run, item, state: .failed, outcome: "failed: \(reason)",
                                   seconds: clock.now().timeIntervalSince(started), error: reason)
                return false
            }
            try await store.setItemState(item.id, .queued, error: reason)
            run.current = nil
            return true
        }
    }

    /// Records a finished item (done, skipped or failed) and updates counters, job totals and progress.
    private func complete(_ run: RunState, _ item: JobItem, state: JobItemState, outcome: String,
                          seconds: Double?, error: String?, countsTowardSpeed: Bool = true) async throws {
        try await store.recordItemOutcome(item.id, outcome: outcome, seconds: seconds ?? 0,
                                          finishedAt: clock.now())
        try await store.setItemState(item.id, state, error: error)
        run.job.totals.queued = max(0, run.job.totals.queued - 1)
        switch state {
        case .done: run.job.totals.done += 1
        case .failed: run.job.totals.failed += 1
        default: run.job.totals.skipped += 1
        }
        var c = run.counts[item.mailbox] ?? MailboxProgress(done: 0, total: 0)
        c.done += 1
        run.counts[item.mailbox] = c
        if let seconds, countsTowardSpeed {
            run.recentSeconds.append(seconds)
            if run.recentSeconds.count > 20 { run.recentSeconds.removeFirst(run.recentSeconds.count - 20) }
        }
        run.lastFinished = summary(item, outcome: outcome)
        run.current = nil
        try await store.updateJob(run.job)
        emit(force: false)
    }

    private func commitPause(_ run: RunState) async throws -> LoopOutcome {
        // No await before this flag, so `resume()` sees a consistent "pause is happening" state.
        run.committed = true
        let stopped = stopRequested
        let reason = (autoPauseRequested && !stopped) ? autoPauseReason : nil
        pauseRequested = false
        stopRequested = false
        autoPauseRequested = false
        autoPauseReason = nil
        cancelRequested = false
        run.job.state = stopped ? .stopped : .paused
        run.job.autoPaused = reason != nil
        run.job.pauseReason = reason
        if let reason, reason != .dailyJob { autoPausedThisSession.insert(run.job.id) }
        run.current = nil
        run.queueHead = []
        if let next = try await store.nextQueued(job: run.job.id, limit: 1).first {
            run.nextUp = summary(next, outcome: nil)
        } else {
            run.nextUp = nil
        }
        try await store.updateJob(run.job)
        emit(force: true)
        return .paused
    }

    private func finish(_ run: RunState) async throws -> LoopOutcome {
        run.stage = .saving
        run.current = nil
        run.nextUp = nil
        if hasContent(run.digest) {
            // Reload first: the user may have edited suggestions since the last result, and `save` replaces
            // the stored results with this digest's content.
            if let fresh = try await store.digest(id: run.digest.id) { run.digest = fresh }
            run.digest.headline = await pipeline.headline(for: run.digest)
            try await store.save(run.digest)
            run.digestStored = true
            let pending = run.digest.suggestions.filter { $0.status == .pending }.count
            if pending > 0 {
                await notifier.post(pending == 1 ? "1 suggestion ready" : "\(pending) suggestions ready")
            }
        }
        run.job.state = .finished
        try await store.updateJob(run.job)
        emit(force: true)
        return .finished
    }

    // MARK: Helpers

    /// Persists one email's result atomically and mirrors it into the in-memory digest.
    private func persist(_ result: EmailResult, in run: RunState) async throws {
        if !run.digestStored {
            try await store.save(run.digest)
            run.digestStored = true
        }
        try await store.appendEmailResult(result, to: run.digest.id)
        let d = run.digest
        let known = d.info.contains { $0.emailID == result.emailID } || d.skipped.contains { $0.id == result.emailID }
            || d.suggestions.contains { $0.emailID == result.emailID }
        if known {
            // Reprocessed after a crash between the write and the item state: replace, as the store does.
            var results = EmailResult.results(from: d)
            if let i = results.firstIndex(where: { $0.emailID == result.emailID }) { results[i] = result }
            run.digest = Digest(id: d.id, createdAt: d.createdAt, headline: d.headline, results: results)
        } else {
            if let info = result.info { run.digest.info.append(info) }
            run.digest.suggestions.append(contentsOf: result.suggestions)
            if let skipped = result.skipped { run.digest.skipped.append(skipped) }
            run.digest.emailCount += 1
        }
    }

    private func cancelInFlight() {
        guard itemActive else { return }
        cancelRequested = true
        inFlight?.cancel()
    }

    private func hasContent(_ digest: Digest) -> Bool {
        digest.emailCount > 0 || !digest.info.isEmpty || !digest.suggestions.isEmpty || !digest.skipped.isEmpty
    }

    /// Pending and approved suggestions from the last 14 days, plus this run's own, without duplicates.
    private func recentSuggestions(for run: RunState, today: Date) async throws -> [Suggestion] {
        let stored = try await store.recentSuggestions(since: today.addingTimeInterval(-14 * 86_400))
        var seen = Set<UUID>()
        return (stored + run.digest.suggestions).filter {
            ($0.status == .pending || $0.status == .approved) && seen.insert($0.id).inserted
        }
    }

    private func summary(_ item: JobItem, outcome: String?) -> JobItemSummary {
        JobItemSummary(messageID: item.messageID, sender: item.sender, subject: item.subject,
                       mailbox: item.mailbox, position: item.position, outcome: outcome)
    }

    // MARK: Provider health (Q25)

    /// A job-level stop caused by the model provider, not by the email being processed.
    private struct ProviderFailure: Error { let message: String }

    /// Throws `providerUnavailable` unless the model provider passes its health check.
    private func preflight() async throws {
        if let outage = await providerOutage() { throw JobRunnerError.providerUnavailable(outage) }
    }

    /// Nil when the provider is healthy, otherwise a message safe to show.
    private func providerOutage() async -> String? {
        do {
            try await llm.healthCheck()
            return nil
        } catch {
            return (error as? LLMError)?.userMessage ?? Self.shortReason(error)
        }
    }

    /// A malformed answer is about this email's output; everything else is checked against the provider.
    private static func mightBeProviderFailure(_ error: Error) -> Bool {
        if case LLMError.malformedResponse = error { return false }
        return true
    }

    /// Error text safe to store and show; it never includes email content.
    private static func shortReason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(120))
    }

    private func emit(force: Bool) {
        guard let run else { return }
        let now = clock.now()
        if !force, let last = lastEmit, now.timeIntervalSince(last) < settings.progressInterval { return }
        lastEmit = now
        let t = run.job.totals
        let finished = t.done + t.failed + t.skipped
        let total = finished + t.queued
        let avg = run.recentSeconds.isEmpty ? nil : run.recentSeconds.reduce(0, +) / Double(run.recentSeconds.count)
        continuation.yield(JobProgress(
            jobID: run.job.id, kind: run.job.kind, state: run.job.state,
            done: finished, total: total, failed: t.failed,
            avgSecondsPerEmail: avg, eta: avg.map { $0 * Double(t.queued) },
            stage: run.stage, current: run.current, lastFinished: run.lastFinished,
            nextUp: run.queueHead.first.map { summary($0, outcome: nil) } ?? run.nextUp,
            countsByMailbox: run.counts, error: run.job.lastError, pauseReason: run.job.pauseReason))
    }
}
