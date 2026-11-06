import Foundation
import MailDigestCore
import MailDigestPersistence
import Observation
import OSLog

/// Drives "Run Now" and the mailbox list. UI state lives here on the main actor;
/// mail, model and store work happens in the Core types, off the main actor.
@MainActor @Observable
final class DigestRunModel {
    private(set) var mailboxes: [MailboxInfo] = []
    private(set) var isLoadingMailboxes = false
    private(set) var mailboxError: String?

    /// True while the app is starting or waiting on a job, or while the runner reports an active job (which
    /// also covers a job the resource monitor auto-resumed).
    var isRunning: Bool { busyFlag || Self.isActive(progress?.state, includePaused: false) }
    private var busyFlag = false
    private(set) var progressText: String?
    private(set) var lastRunSummary: String?
    /// Latest runner update. Applied always, so a job paused earlier still shows its strip.
    private(set) var progress: JobProgress?
    /// When the last digest was created, or the last run that found nothing finished.
    private(set) var lastRunAt: Date?
    /// The last finished run found no new mail (Q24: such a job leaves no digest).
    private(set) var lastRunFoundNothing = false
    /// The panel's digest and selection; refreshed while a job runs.
    let review: ReviewViewModel
    let settings: SettingsStore
    let reminders: RemindersAccessModel
    /// The Processed tab: cleanup, Undo history and auto-file.
    let processed: ProcessedMailModel
    private(set) var banner: String?
    /// A job stopped by a provider outage (Q25); Retry resumes this same job and its queue.
    private(set) var failedJobID: UUID?
    /// A paused job loaded from the store, for example one left paused by a previous session, so its strip
    /// and Resume button show without the runner having published anything.
    private(set) var restoredProgress: JobProgress?
    /// Items of the job shown in the progress view (recent results and the activity log); sender and subject only.
    private(set) var activityItems: [JobItem] = []
    /// Every job, newest first, for Settings > Jobs.
    private(set) var pastJobs: [PastJobRow] = []
    /// Watches power, Low Power Mode, heat and quiet hours (Mac-only adapter).
    @ObservationIgnored let monitor = ResourceMonitor()
    @ObservationIgnored private var lastBlocked: [JobKind: PauseReason] = [:]

    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "run")

    @ObservationIgnored private let source = AppleMailSource()
    /// The SQLite store, opened lazily off the main actor. Nil until opened; there is deliberately no
    /// in-memory fallback, so a failure is shown instead of silently losing results.
    @ObservationIgnored private var store: GRDBDigestStore?
    @ObservationIgnored private var didRecoverJobs = false
    @ObservationIgnored private let notifier = UserNotifier()
    @ObservationIgnored private let clock = SystemClock()
    @ObservationIgnored private var runner: JobRunner?
    @ObservationIgnored private var runnerKey: RunnerKey?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshedDone: Int?

    /// What a runner was built from; a new runner is only made when it changes.
    private struct RunnerKey: Equatable {
        var settings: DigestSettings
        var inboxes: Set<MailboxRef>
    }

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        self.review = ReviewViewModel()
        self.reminders = RemindersAccessModel()
        self.processed = ProcessedMailModel(review: review, settings: settings)
        reminders.attach(review: review)
        review.onSuggestionsSettled = { [processed] in await processed.autoFileIfEnabled() }
        review.listName = { [settings] in settings.settings.resolvedListName }
        review.settingsStore = settings
        settings.onChange = { [weak self] in self?.evaluateResources() }
    }

    /// Previews: fixed run state, no store or Mail access.
    init(preview: SettingsStore = SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
         review: ReviewViewModel = ReviewViewModel(),
         reminders: RemindersAccessModel = RemindersAccessModel(preview: .granted), progress: JobProgress? = nil, banner: String? = nil, failedJobID: UUID? = nil,
         lastRunAt: Date? = nil, lastRunFoundNothing: Bool = false, lastRunSummary: String? = nil) {
        self.settings = preview
        self.review = review
        self.reminders = reminders
        self.processed = ProcessedMailModel(review: review, settings: preview, actions: RecordingMailActions(locations: [:]))
        self.progress = progress
        self.banner = banner
        self.failedJobID = failedJobID
        self.lastRunAt = lastRunAt
        self.lastRunFoundNothing = lastRunFoundNothing
        self.lastRunSummary = lastRunSummary
    }

    /// The runner's progress while a job is active (listing, running, pausing, paused or stopping), or a
    /// paused job restored from the store. A stopped job has no strip; it is resumed from Past Jobs.
    var activeProgress: JobProgress? {
        if let progress, Self.isActive(progress.state, includePaused: true) { return progress }
        return restoredProgress
    }

    private static func isActive(_ state: JobState?, includePaused: Bool) -> Bool {
        switch state {
        case .listing, .running, .pausing, .stopping: return true
        case .paused: return includePaused
        case .idle, .finished, .failed, .stopped, .none: return false
        }
    }

    /// Whether a Daily run may start now: nothing is running, or only a running Backlog job, which the
    /// runner pauses first (Daily goes before Backlog). A paused or stopped job never blocks it.
    var canStartDaily: Bool {
        if !isRunning { return true }
        return progress?.kind == .backlog && progress?.state == .running
    }

    /// What the menu bar icon shows. Progress is bucketed to 5% so the icon is rarely redrawn.
    var menuBarIcon: MenuBarIconState {
        guard let p = activeProgress else { return .idle }
        switch p.state {
        case .paused: return .paused
        case .listing: return .listing
        default:
            guard p.total > 0 else { return .listing }
            return .progress(step: Int((Double(min(p.done, p.total)) / Double(p.total) * 20).rounded(.down)))
        }
    }

    private var llm: OllamaClient {
        OllamaClient(baseURL: settings.settings.resolvedOllamaURL, model: settings.settings.resolvedModel)
    }

    /// Onboarding's Ollama step: nil when the server and model answer, otherwise a message saying how to fix it.
    func checkOllama() async -> String? {
        do {
            try await llm.healthCheck()
            return nil
        } catch let error as LLMError {
            return error.userMessage
        } catch {
            return "Ollama is not reachable. Start Ollama, or run `ollama pull qwen3:4b`."
        }
    }

    /// Daily runs read every inbox.
    var inboxCount: Int { mailboxes.filter { $0.kind == .inbox }.count }

    func loadMailboxes() async {
        guard !isLoadingMailboxes else { return }
        isLoadingMailboxes = true
        mailboxError = nil
        defer { isLoadingMailboxes = false }
        do {
            mailboxes = try await source.listMailboxes()
        } catch {
            mailboxError = Self.message(for: error)
        }
    }

    /// Call once at launch: opens the database and shows the last run's summary.
    func loadLastRun() async {
        guard let store = await openStore() else { return }
        await review.attach(store: store)
        // Building the runner puts jobs interrupted by a quit or crash back to paused, so it comes before
        // loading the resumable job.
        _ = await ensureRunner()
        await refreshJobLists()
        startResourceMonitor()
        guard let digest = try? await store.latestDigest() else { return }
        lastRunSummary = Self.summary(for: digest)
        lastRunAt = digest.createdAt
    }

    /// `~/Library/Application Support/MailDigest/digest.sqlite`.
    private static var databasePath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MailDigest/digest.sqlite").path
    }

    /// Opens the store once, off the main actor. On failure shows a banner and returns nil.
    func openStore() async -> GRDBDigestStore? {
        if let store { return store }
        let path = Self.databasePath
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try GRDBDigestStore(path: path) }.value
            store = opened
            await review.attach(store: opened)
            return opened
        } catch {
            Self.log.error("could not open database: \(String(describing: error), privacy: .public)")
            banner = "Could not open the Mail Digest database. Your results can't be saved, so nothing was run."
            return nil
        }
    }

    /// What started a Daily run. Scheduled runs are silent on failure apart from the usual banner.
    enum RunTrigger { case manual, scheduled }

    /// Run Now: starts the Daily job.
    func runNow() async { await runDaily(trigger: .manual) }

    /// Called by the scheduler: starts the Daily job only when the core rule says the morning run is due
    /// and nothing is running. Failures before a job exists (Ollama down) leave no job, so the next check retries.
    func runIfDue() async {
        guard canStartDaily, let store = await openStore() else { return }
        guard let jobs = try? await store.jobs() else { return }
        let s = settings.settings
        guard MorningSchedule.isDue(now: clock.now(), hour: s.runHour, minute: s.runMinute, jobs: jobs) else {
            await cleanUpHistoryIfDue()
            return
        }
        await runDaily(trigger: .scheduled)
        await cleanUpHistoryIfDue()
    }

    private static let lastCleanupKey = "lastRetentionCleanup"

    /// The daily retention cleanup: at most once a day, never while a job is running. A job or digest created
    /// after the plan is built is not in the plan, so a run starting meanwhile is safe. Pinned digests keep
    /// their jobs (Q21); processed ids and decisions are never touched.
    func cleanUpHistoryIfDue() async {
        let defaults = UserDefaults.standard
        let now = clock.now()
        if let last = defaults.object(forKey: Self.lastCleanupKey) as? Date, now.timeIntervalSince(last) < 86_400 { return }
        guard !isRunning, activeProgress == nil, let store = await openStore() else { return }
        do {
            let plan = RetentionPolicy().plan(retention: settings.settings.retention, now: now,
                                              digests: try await store.retainedDigests(), jobs: try await store.jobs())
            if !plan.digestIDs.isEmpty || !plan.jobIDs.isEmpty {
                try await store.apply(plan)
                await review.reload()
            }
            defaults.set(now, forKey: Self.lastCleanupKey)
            Self.log.notice("history cleanup: digests=\(plan.digestIDs.count, privacy: .public) jobs=\(plan.jobIDs.count, privacy: .public)")
        } catch {
            Self.log.error("history cleanup failed: \(String(describing: error), privacy: .public)")
        }
    }

    func runDaily(trigger: RunTrigger) async {
        guard canStartDaily else { return }
        // A Daily run that preempts a running Backlog job leaves that run's own bookkeeping alone.
        let preempting = isRunning
        Self.log.notice("daily run starting: trigger=\(trigger == .scheduled ? "scheduled" : "manual", privacy: .public)")
        if !preempting {
            busyFlag = true
            progressText = "Starting…"
        }
        banner = nil
        defer { if !preempting { busyFlag = false; progressText = nil } }

        guard let store = await openStore() else { return }

        // Check Ollama first so a down server doesn't cost a mail listing (Q25).
        do {
            try await llm.healthCheck()
        } catch let error as LLMError {
            banner = error.userMessage
            return
        } catch {
            banner = "Ollama is not reachable. Start Ollama, or run `ollama pull qwen3:4b`."
            return
        }

        if mailboxes.isEmpty { await loadMailboxes() }
        if let mailboxError {
            banner = mailboxError
            return
        }
        let inboxes = mailboxes.filter { $0.kind == .inbox }.map(\.ref)
        guard !settings.settings.runnerSettings(inboxes: inboxes).dailyMailboxes.isEmpty else {
            banner = "No inboxes found in Mail."
            return
        }

        let runner = await runner(for: inboxes, store: store)
        let startedAt = clock.now()
        do {
            try await runner.startDaily()
            evaluateResources(force: true)
            await runner.waitUntilIdle()
        } catch {
            banner = Self.message(for: error)
            return
        }
        await finishRun(startedAt: startedAt)
    }

    /// Resumes the job a provider outage stopped. The runner re-checks Ollama first.
    func retryFailedJob() async {
        guard let jobID = failedJobID else { return }
        await resumeJob(jobID)
    }

    /// Resume button: continues the paused job from the next email.
    func resume() async {
        guard let paused = activeProgress, paused.state == .paused else { return }
        await resumeJob(paused.jobID)
    }

    /// Pause after the email in flight (takes effect between emails).
    func pause() { Task { await runner?.pause() } }

    /// Cancel the email in flight and pause; that email is requeued.
    func pauseNow() { Task { await runner?.pauseNow() } }

    /// Stop the job; finished items stay done and the rest can be resumed later.
    func stop() { Task { await runner?.stop() } }

    /// Resumes a paused, stopped or failed job by id, including one from a previous session.
    func resumeJob(_ jobID: UUID) async {
        guard !isRunning else { return }
        busyFlag = true
        banner = nil
        progressText = "Starting…"
        defer { busyFlag = false; progressText = nil }
        guard let runner = await ensureRunner() else { return }
        do {
            try await runner.resume(jobID: jobID)
            restoredProgress = nil
            await runner.waitUntilIdle()
        } catch {
            banner = Self.message(for: error)
            return
        }
        await finishRun()
    }

    /// Retry failed (Q28): requeues the job's failed emails and resumes it. Rejected while any job runs.
    func retryFailedItems(of jobID: UUID) async {
        guard !isRunning else { return }
        busyFlag = true
        banner = nil
        progressText = "Starting…"
        defer { busyFlag = false; progressText = nil }
        guard let runner = await ensureRunner() else { return }
        do {
            try await runner.retryFailed(jobID: jobID)
            restoredProgress = nil
            await runner.waitUntilIdle()
        } catch {
            banner = Self.message(for: error)
            return
        }
        await finishRun()
    }

    /// Job setup: lists headers for the plan and reports what Start would queue. Nothing is queued.
    func previewJob(_ plan: JobPlan) async throws -> JobPreview {
        guard let runner = await ensureRunner() else { throw JobSetupError.databaseUnavailable }
        return try await runner.preview(plan)
    }

    /// Job setup: queues exactly the confirmed plan and starts it in the background. Returns once the job is
    /// queued; progress then arrives through the progress strip. Returns an error message on failure.
    func startBacklog(_ plan: JobPlan) async -> String? {
        guard !isRunning else { return "Another job is already running." }
        busyFlag = true
        banner = nil
        progressText = "Starting…"
        guard let runner = await ensureRunner() else {
            busyFlag = false; progressText = nil
            return banner ?? "Could not open the Mail Digest database."
        }
        do {
            try await runner.start(plan)
        } catch {
            busyFlag = false; progressText = nil
            return Self.message(for: error)
        }
        evaluateResources(force: true)
        Task {
            await runner.waitUntilIdle()
            busyFlag = false
            progressText = nil
            await finishRun()
        }
        return nil
    }

    /// Shows the outage banner if the job stopped as failed; otherwise summarises it.
    private func finishRun(startedAt: Date? = nil) async {
        guard let store else { return }
        defer { Task { await refreshJobLists() } }
        let job = try? await store.jobs().first
        if let job, job.state == .failed {
            failedJobID = job.id
            banner = job.lastError ?? "The run stopped. Try again."
            Self.log.notice("run stopped: state=failed queued=\(job.totals.queued, privacy: .public)")
            await review.reload()
            return
        }
        failedJobID = nil
        await summariseLastRun(store)
        await review.reload()
        // A finished job with no digest newer than its start found nothing (Q24).
        if let startedAt, job?.state == .finished {
            let latest = review.digest?.createdAt
            lastRunFoundNothing = latest.map { $0 < startedAt } ?? true
            if lastRunFoundNothing { lastRunAt = clock.now() }
        } else if job?.state == .finished {
            lastRunFoundNothing = false
        }
        if !lastRunFoundNothing, let created = review.digest?.createdAt { lastRunAt = created }
        await processed.autoFileIfEnabled()
    }

    // MARK: Job lists, activity and resources

    /// The runner for the current settings, created on demand (for example to resume an old job at launch).
    private func ensureRunner() async -> JobRunner? {
        guard let store = await openStore() else { return nil }
        return await runner(for: mailboxes.filter { $0.kind == .inbox }.map(\.ref), store: store)
    }

    /// Reloads Past Jobs and the paused-job strip from the store.
    func refreshJobLists() async {
        await refreshPastJobs()
        await restoreResumableJob()
    }

    func refreshPastJobs() async {
        guard let store, let jobs = try? await store.jobs() else { return }
        var rows: [PastJobRow] = []
        for job in jobs {
            let items = (try? await store.items(job: job.id)) ?? []
            rows.append(PastJobRow(job: job, processingSeconds: items.compactMap(\.seconds).reduce(0, +)))
        }
        pastJobs = rows
    }

    /// Shows the newest paused job's strip when the runner has nothing active (after a relaunch, or after
    /// a Daily run that preempted nothing). The runner only publishes progress while it works on a job.
    private func restoreResumableJob() async {
        guard let store else { return }
        guard !Self.isActive(progress?.state, includePaused: false),
              let job = (try? await store.jobs())?.first(where: { $0.state == .paused }),
              let items = try? await store.items(job: job.id) else {
            if !Self.isActive(progress?.state, includePaused: true) { restoredProgress = nil }
            return
        }
        // The runner's own paused progress for this job is just as good; only restore what it doesn't hold.
        if progress?.jobID == job.id, progress?.state == .paused { restoredProgress = nil; return }
        restoredProgress = JobProgressSnapshot.progress(job: job, items: items)
        activityItems = items
        activityJobID = job.id
    }

    /// Recent results and the activity log for the job the progress view shows.
    func refreshActivity(jobID: UUID) async {
        guard let store, let items = try? await store.items(job: jobID) else { return }
        activityItems = items
        activityJobID = jobID
    }

    private(set) var activityJobID: UUID?

    private func startResourceMonitor() {
        monitor.onChange = { [weak self] in self?.evaluateResources() }
        monitor.start()
        evaluateResources()
    }

    /// Applies the core resource policy. Normally it acts only when the set of blocking reasons changes, so a
    /// job the user resumed by hand on battery keeps running until the next change; `force` (a job just
    /// started) applies the current rules once.
    func evaluateResources(force: Bool = false) {
        let policy = settings.settings.resourcePolicy()
        let now = clock.now()
        monitor.scheduleBoundary(at: policy.quietHours?.nextBoundary(after: now, in: policy.timeZone))
        let blocked = policy.blocked(conditions: monitor.conditions, now: now)
        guard force || blocked != lastBlocked else { return }
        lastBlocked = blocked
        guard let runner else { return }
        Task {
            do { try await runner.applyResourceRules(blocked) } catch {
                Self.log.error("resource rules failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Helpers

    /// Creates the runner once and only recreates it when the inbox set changes. The first runner puts jobs
    /// interrupted by a quit or crash back into a resumable state.
    private func runner(for inboxes: [MailboxRef], store: GRDBDigestStore) async -> JobRunner {
        // Never swap the runner under a job that is running; the next idle moment picks up new settings.
        if let runner, Self.isActive(progress?.state, includePaused: false) { return runner }
        // Settings that don't affect the runner are cleared so editing them doesn't rebuild it.
        var relevant = settings.settings
        relevant.retention = .default
        relevant.remindersListName = DigestSettings.defaultListName
        relevant.runHour = 6; relevant.runMinute = 30
        relevant.trustedNewsletterSenders = []
        relevant.declinedIgnoreSuggestions = []
        relevant.autoFileProcessed = false
        relevant.pauseBacklogOnBattery = true
        relevant.quietHoursEnabled = false
        let key = RunnerKey(settings: relevant, inboxes: Set(inboxes))
        if let runner, key == runnerKey { return runner }
        progressTask?.cancel()
        let new = JobRunner(source: source, llm: llm, store: store, notifier: notifier, clock: clock,
                            settings: settings.settings.runnerSettings(inboxes: inboxes))
        runner = new
        runnerKey = key
        if !didRecoverJobs {
            didRecoverJobs = true
            do { try await new.recoverOnLaunch() } catch {
                Self.log.error("job recovery failed: \(String(describing: error), privacy: .public)")
            }
        }
        progressTask = Task { [weak self] in
            for await update in new.progress {
                self?.apply(update)
            }
        }
        return new
    }

    private func apply(_ update: JobProgress) {
        progress = update
        // Show finished results while the job runs. The runner already throttles updates to 2 a second.
        if update.state == .running, update.done != lastRefreshedDone {
            lastRefreshedDone = update.done
            Task {
                await review.reload()
                await refreshActivity(jobID: update.jobID)
            }
        }
        // A job the resource monitor resumed has no caller waiting on it, so settle it here.
        if !busyFlag, [.finished, .failed, .paused, .stopped].contains(update.state) {
            Task { await finishRun() }
        }
        guard busyFlag else { return }
        switch update.state {
        case .listing:
            progressText = "Looking for new mail…"
        case .running, .pausing, .paused, .stopping:
            progressText = ReviewPresentation.readingSummary(update)
        default:
            break
        }
    }

    private static func summary(for digest: Digest) -> String {
        let time = digest.createdAt.formatted(date: .omitted, time: .shortened)
        if digest.emailCount == 0 { return "Inbox zero for today · last run \(time)" }
        return "Last run \(time) · \(digest.suggestions.count) suggestions · \(digest.emailCount) emails"
    }

    private func summariseLastRun(_ store: GRDBDigestStore) async {
        do {
            guard let digest = try await store.latestDigest() else {
                lastRunSummary = "Inbox zero for today"
                Self.log.notice("run finished: no digest")
                return
            }
            lastRunSummary = Self.summary(for: digest)

            // Counts only: no subjects, senders, bodies or IDs go to the log.
            let items = try await store.items(job: digest.id)
            let queued = Set(items.map(\.messageID))
            let failed = items.filter { $0.state == .failed }.count
            let canonical = digest.info.allSatisfy { queued.contains($0.emailID) }
                && digest.suggestions.allSatisfy { queued.contains($0.emailID) }
            Self.log.notice("run finished: emails=\(digest.emailCount, privacy: .public) info=\(digest.info.count, privacy: .public) suggestions=\(digest.suggestions.count, privacy: .public) skipped=\(digest.skipped.count, privacy: .public) failed=\(failed, privacy: .public) idsCanonical=\(canonical, privacy: .public)")
        } catch {
            banner = "Could not read the run result."
        }
    }

    private static func message(for error: Error) -> String {
        if case JobRunnerError.providerUnavailable(let message) = error { return message }
        if case OsascriptError.automationDenied = error {
            return "Mail automation is off. Open Mail Access to allow it."
        }
        return "Could not read Mail. Open Mail Access to check permissions."
    }
}


/// A job as Settings > Jobs lists it.
struct PastJobRow: Identifiable, Equatable, Sendable {
    var job: Job
    /// Sum of the seconds the model spent on its emails.
    var processingSeconds: Double

    var id: UUID { job.id }
}

enum JobSetupError: Error { case databaseUnavailable }
