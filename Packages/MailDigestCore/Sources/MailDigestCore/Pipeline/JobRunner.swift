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

        init(job: Job, digest: Digest) {
            self.job = job
            self.digest = digest
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
        let ids = Set(requeued.map(\.messageID))
        if var digest = try await store.digest(id: jobID) {
            let before = digest.skipped.count
            digest.skipped.removeAll { ids.contains($0.id) && $0.reason.hasPrefix("failed:") }
            digest.emailCount = max(0, digest.emailCount - (before - digest.skipped.count))
            try await store.save(digest)
        }
        job.state = .paused
        job.autoPaused = false
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

    /// Cancels the in-flight email and ends the run. `JobState` has no "stopped" case, so the job is left
    /// `.paused` with `autoPaused == false`; the user can resume it later from the job list.
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
            } else if pauseRequested && !stopRequested {
                // The loop hasn't paused yet, so just withdraw the request.
                pauseRequested = false
                autoPauseRequested = false
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
                job = (found.state == .paused || found.state == .failed) ? found : nil
            } else {
                job = all.first { $0.state == .paused }
            }
            guard var job else { busy = false; return }
            job.state = .running
            job.autoPaused = false
            try await store.updateJob(job)
            resetFlags()
            resumeAfter = nil
            run = try await loadRun(job)
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
            job.state = .paused
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
                                                    suggestions: [], info: [], skipped: []))
            emit(force: true)

            let headers = try await select(plan).toProcess

            var index = 0
            while index < headers.count {
                let end = min(index + max(1, settings.enqueueChunkSize), headers.count)
                try await store.enqueue(Array(headers[index..<end]), job: job.id)
                index = end
            }

            job.state = .running
            job.totals.queued = headers.count
            try await store.updateJob(job)
            let digest = Digest(id: job.id, createdAt: now, headline: "", emailCount: 0,
                                suggestions: [], info: [], skipped: [])
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
        if let newDigest {
            digest = newDigest
        } else if let saved = try await store.digest(id: job.id) {
            digest = saved
        } else {
            digest = Digest(id: job.id, createdAt: clock.now(), headline: "", emailCount: 0,
                            suggestions: [], info: [], skipped: [])
        }
        let state = RunState(job: job, digest: digest)
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
                job.state = .running
                job.autoPaused = false
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

    // MARK: Processing loop

    private func runLoop() async -> LoopOutcome {
        guard let run else { return .failed }
        do {
            return try await loop(run)
        } catch {
            // Store or Mail failure: stop the loop but keep the queue so the job can be resumed by id.
            run.job.state = .failed
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
            var idsByMailbox: [MailboxRef: [String]] = [:]
            for item in batch {
                if idsByMailbox[item.mailbox] == nil { order.append(item.mailbox) }
                idsByMailbox[item.mailbox, default: []].append(item.messageID)
            }
            var fetched: [String: EmailMessage] = [:]
            for mailbox in order {
                for email in try await source.fetchMessages(ids: idsByMailbox[mailbox] ?? [], in: mailbox) {
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

    /// Processes one item. Returns true if it went back to `queued`.
    private func handle(_ item: JobItem, email: EmailMessage?, run: RunState) async throws -> Bool {
        guard let email else {
            let reason = "not found in Mail"
            run.digest.skipped.append(SkippedEmail(id: item.messageID, sender: item.sender,
                                                   subject: item.subject, reason: reason))
            run.digest.emailCount += 1
            try await store.save(run.digest)
            try await complete(run, item, state: .skipped, outcome: "skipped: \(reason)", seconds: nil, error: reason)
            return false
        }
        // Guards against a crash between "marked processed" and "item done".
        if try await store.isProcessed(item.messageID) {
            try await complete(run, item, state: .skipped, outcome: "skipped: already processed", seconds: nil, error: nil)
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
            if let info = outcome.info { run.digest.info.append(info) }
            run.digest.suggestions.append(contentsOf: outcome.suggestions)
            // Backlog digests are not capped; they are reviewed in batches instead.
            if run.job.kind == .daily {
                run.digest.suggestions = pipeline.validator.capDigest(run.digest.suggestions,
                                                                       limit: settings.dailyDigestCap)
            }
            if let skipped = outcome.skipped { run.digest.skipped.append(skipped) }
            run.digest.emailCount += 1
            // Order matters for crash safety: results first, then "processed", then the item state.
            try await store.save(run.digest)
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
            let reason = Self.shortReason(error)
            // `item.attempts` was read before this attempt started.
            if item.attempts + 1 >= settings.maxAttempts {
                run.digest.skipped.append(SkippedEmail(id: item.messageID, sender: item.sender,
                                                       subject: item.subject, reason: "failed: \(reason)"))
                run.digest.emailCount += 1
                try await store.save(run.digest)
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
        let auto = autoPauseRequested
        pauseRequested = false
        stopRequested = false
        autoPauseRequested = false
        cancelRequested = false
        run.job.state = .paused
        run.job.autoPaused = auto
        run.current = nil
        run.queueHead = []
        if let next = try await store.nextQueued(job: run.job.id, limit: 1).first {
            run.nextUp = summary(next, outcome: nil)
        } else {
            run.nextUp = nil
        }
        try await store.updateJob(run.job)
        if hasContent(run.digest) { try await store.save(run.digest) }
        emit(force: true)
        return .paused
    }

    private func finish(_ run: RunState) async throws -> LoopOutcome {
        run.stage = .saving
        run.current = nil
        run.nextUp = nil
        if hasContent(run.digest) {
            run.digest.headline = await pipeline.headline(for: run.digest)
            try await store.save(run.digest)
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
            countsByMailbox: run.counts))
    }
}
