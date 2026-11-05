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

    private(set) var isRunning = false
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
    private(set) var banner: String?
    /// A job stopped by a provider outage (Q25); Retry resumes this same job and its queue.
    private(set) var failedJobID: UUID?

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
        reminders.attach(review: review)
        review.listName = { [settings] in settings.settings.resolvedListName }
    }

    /// Previews: fixed run state, no store or Mail access.
    init(preview: SettingsStore = SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
         review: ReviewViewModel = ReviewViewModel(),
         reminders: RemindersAccessModel = RemindersAccessModel(preview: .granted), progress: JobProgress? = nil, banner: String? = nil, failedJobID: UUID? = nil,
         lastRunAt: Date? = nil, lastRunFoundNothing: Bool = false, lastRunSummary: String? = nil) {
        self.settings = preview
        self.review = review
        self.reminders = reminders
        self.progress = progress
        self.banner = banner
        self.failedJobID = failedJobID
        self.lastRunAt = lastRunAt
        self.lastRunFoundNothing = lastRunFoundNothing
        self.lastRunSummary = lastRunSummary
    }

    /// The runner's progress while a job is active (listing, running, pausing, paused or stopping).
    var activeProgress: JobProgress? {
        guard let progress else { return nil }
        switch progress.state {
        case .listing, .running, .pausing, .paused, .stopping: return progress
        case .idle, .finished, .failed: return nil
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
        guard !isRunning, activeProgress == nil, let store = await openStore() else { return }
        guard let jobs = try? await store.jobs() else { return }
        let s = settings.settings
        guard MorningSchedule.isDue(now: clock.now(), hour: s.runHour, minute: s.runMinute, jobs: jobs) else { return }
        await runDaily(trigger: .scheduled)
    }

    func runDaily(trigger: RunTrigger) async {
        guard !isRunning else { return }
        Self.log.notice("daily run starting: trigger=\(trigger == .scheduled ? "scheduled" : "manual", privacy: .public)")
        isRunning = true
        banner = nil
        progressText = "Starting…"
        defer { isRunning = false; progressText = nil }

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
        guard let progress, progress.state == .paused else { return }
        await resumeJob(progress.jobID)
    }

    /// Pause after the email in flight (takes effect between emails).
    func pause() { Task { await runner?.pause() } }

    /// Stop the job; finished items stay done and the rest can be resumed later.
    func stop() { Task { await runner?.stop() } }

    private func resumeJob(_ jobID: UUID) async {
        guard !isRunning, let runner, store != nil else { return }
        isRunning = true
        banner = nil
        progressText = "Starting…"
        defer { isRunning = false; progressText = nil }
        do {
            try await runner.resume(jobID: jobID)
            await runner.waitUntilIdle()
        } catch {
            banner = Self.message(for: error)
            return
        }
        await finishRun()
    }

    /// Shows the outage banner if the job stopped as failed; otherwise summarises it.
    private func finishRun(startedAt: Date? = nil) async {
        guard let store else { return }
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
    }

    // MARK: Helpers

    /// Creates the runner once and only recreates it when the inbox set changes. The first runner puts jobs
    /// interrupted by a quit or crash back into a resumable state.
    private func runner(for inboxes: [MailboxRef], store: GRDBDigestStore) async -> JobRunner {
        // Settings that don't affect the runner are cleared so editing them doesn't rebuild it.
        var relevant = settings.settings
        relevant.retention = .default
        relevant.remindersListName = DigestSettings.defaultListName
        relevant.runHour = 6; relevant.runMinute = 30
        relevant.trustedNewsletterSenders = []
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
            Task { await review.reload() }
        }
        guard isRunning else { return }
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
