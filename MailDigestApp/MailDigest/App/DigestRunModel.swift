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
    /// The latest digest, for Mail Cleanup and auto-file; refreshed while a job runs.
    let review: ReviewViewModel
    /// The sidebar summaries (Q56) and the cross-digest canvases and triage actions (Q54).
    let library: ReviewLibrary
    let coordinator: ReviewCoordinator
    let settings: SettingsStore
    /// Sender logos for the avatars; website logos are fetched only while Show Sender Logos is on.
    let senderLogos: SenderLogoProvider?
    @ObservationIgnored private let logoService: SenderLogoService?
    let reminders: RemindersAccessModel
    /// Model downloads started from Settings or the missing-model banner; they outlive the window.
    let modelDownloads = ModelDownloadModel()
    /// The Processed tab: cleanup, Undo history and auto-file.
    let processed: ProcessedMailModel
    private(set) var banner: String? {
        get { bannerText }
        // Any assignment replaces the banner, so what was known about the old one goes with it.
        set { bannerText = newValue; bannerContext = nil }
    }
    private var bannerText: String?
    /// What `banner` reports, set only through `showBanner` and cleared whenever the banner changes.
    private var bannerContext: (kind: JobFailureKind?, dailyStartFailedAt: Date?)?
    /// Whether the current banner is "model not installed", which offers Download Model.
    var bannerOffersDownloadModel: Bool { banner != nil && bannerContext?.kind == .modelMissing }
    /// Whether the current banner is "Ollama isn't running", which the canvas answers with Start Ollama.
    var bannerOffersStartOllama: Bool { banner != nil && bannerContext?.kind == .ollamaUnreachable }
    /// A job stopped by a provider outage (Q25); Retry resumes this same job and its queue.
    private(set) var failedJobID: UUID?
    /// A paused job loaded from the store, for example one left paused by a previous session, so its strip
    /// and Resume button show without the runner having published anything.
    private(set) var restoredProgress: JobProgress?
    /// Items of the job shown in the progress view (recent results and the activity log); sender and subject only.
    private(set) var activityItems: [JobItem] = []
    /// Every job, newest first. Drives the Daily lifecycle and the menu panel.
    private(set) var pastJobs: [PastJobRow] = []
    /// The Settings tab shown, so a caller can open Settings on a given tab.
    var settingsTab: SettingsTab = .general
    /// Set synchronously when a Daily run or Daily resume starts, before any job or progress exists, so a
    /// second click or a scheduler check in between cannot start another one (Q52).
    private(set) var dailyStarting = false
    /// A scheduler check found the morning run due while a Daily job was unresolved (Q52).
    private(set) var scheduledRunWaiting = false
    /// Watches power, Low Power Mode, heat and quiet hours (Mac-only adapter).
    @ObservationIgnored let monitor = ResourceMonitor()
    @ObservationIgnored private var lastBlocked: [JobKind: PauseReason] = [:]
    @ObservationIgnored private var lastOvernightBlock: PauseReason?
    /// The overnight and quiet-hours windows last evaluated, so editing them re-evaluates at once.
    @ObservationIgnored private var lastWindows: [QuietHours?] = []
    /// Whether a job may be started automatically now: onboarding is done and Mail access is available.
    /// The app sets it; until it passes, rules only pause (never start) and evaluation is retried.
    @ObservationIgnored var autoStartGate: @MainActor () -> Bool = { true }
    @ObservationIgnored private var autoStartPending = false
    /// `overnightOnly` per job id, looked up once from the store, for the idle-sleep assertion.
    @ObservationIgnored private var overnightJobFlags: [UUID: Bool] = [:]
    @ObservationIgnored private var overnightLookups: Set<UUID> = []

    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "run")

    @ObservationIgnored private let source = AppleMailSource()
    /// The Gemini API key lives only in the Keychain; Settings saves and removes it here.
    @ObservationIgnored let credentials = KeychainCredentialStore()
    @ObservationIgnored private(set) lazy var cloudRouting = CloudRoutingProvider(
        credentials: credentials, snapshot: { [settings] in settings.settings })
    /// The SQLite store, opened lazily off the main actor. Nil until opened; there is deliberately no
    /// in-memory fallback, so a failure is shown instead of silently losing results.
    @ObservationIgnored private var store: GRDBDigestStore?
    @ObservationIgnored private var didRecoverJobs = false
    @ObservationIgnored private let notifier = UserNotifier()
    /// The time source, injectable so previews can show a chosen moment.
    @ObservationIgnored let clock: any Clock
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
        self.clock = SystemClock()
        let logoService = SenderLogoService(store: DiskSenderLogoStore(), fetcher: SenderLogoFetcher(), clock: SystemClock())
        self.logoService = logoService
        self.senderLogos = SenderLogoProvider(service: logoService,
                                              networkSetting: { [settings] in settings.settings.showSenderLogos })
        self.review = ReviewViewModel()
        self.library = ReviewLibrary()
        self.coordinator = ReviewCoordinator(library: library, review: review)
        self.reminders = RemindersAccessModel()
        self.processed = ProcessedMailModel(review: review, settings: settings)
        reminders.attach(coordinator: coordinator)
        review.onSuggestionsSettled = { [processed] in await processed.refresh() }
        // Every existing `review.reload()` (job progress, run end, cleanup) also refreshes the sidebar and the shown canvas.
        review.onReloaded = { [coordinator] in await coordinator.storeDidChange() }
        review.listName = { [settings] in settings.settings.resolvedListName }
        review.settingsStore = settings
        settings.onChange = { [weak self] in self?.evaluateResources() }
    }

    /// Previews: fixed run state, no store or Mail access.
    init(preview: SettingsStore = SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard),
         review: ReviewViewModel = ReviewViewModel(),
         coordinator: ReviewCoordinator? = nil,
         reminders: RemindersAccessModel = RemindersAccessModel(preview: .granted), progress: JobProgress? = nil, banner: String? = nil, failedJobID: UUID? = nil,
         lastRunAt: Date? = nil, lastRunFoundNothing: Bool = false, lastRunSummary: String? = nil,
         jobs: [Job] = [], scheduledRunWaiting: Bool = false,
         bannerKind: JobFailureKind? = nil, dailyStartFailedAt: Date? = nil, mailboxes: [MailboxInfo] = [],
         clock: any Clock = SystemClock()) {
        self.clock = clock
        self.mailboxes = mailboxes
        self.settings = preview
        // Previews never touch the disk or the network.
        self.logoService = nil
        self.senderLogos = nil
        self.review = review
        let coordinator = coordinator ?? ReviewCoordinator.empty(review: review)
        self.coordinator = coordinator
        self.library = coordinator.library
        self.reminders = reminders
        self.processed = ProcessedMailModel(review: review, settings: preview, actions: RecordingMailActions(locations: [:]))
        self.progress = progress
        self.bannerText = banner
        if banner != nil { self.bannerContext = (bannerKind, dailyStartFailedAt) }
        self.failedJobID = failedJobID
        self.lastRunAt = lastRunAt
        self.lastRunFoundNothing = lastRunFoundNothing
        self.lastRunSummary = lastRunSummary
        self.pastJobs = jobs.map { PastJobRow(job: $0) }
        self.scheduledRunWaiting = scheduledRunWaiting
    }

    /// The runner's progress while a job is active (listing, running, pausing, paused or stopping), or a
    /// paused job restored from the store. A stopped job has no strip; it is resumed from Activity.
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

    /// Whether a new Daily run may start now: no Daily job is unresolved (Q52), and nothing is running or
    /// only a running Backlog job, which the runner pauses first (Daily goes before Backlog). A paused or
    /// stopped Backlog job never blocks it.
    var canStartDaily: Bool {
        dailyLifecycle == .none && canRunDailyWork
    }

    /// Whether a Run Now button (the toolbar's, or Today's empty state) can act: a Daily run may start and Mail is reachable.
    func canRunNow(mailUnavailable: Bool) -> Bool {
        canStartDaily && !mailUnavailable
    }

    /// Whether `action` can act now; shared by the toolbar button and Today's empty state so they agree.
    func canPerform(_ action: ToolbarRunAction, mailUnavailable: Bool) -> Bool {
        switch action.behavior {
        case .runNow: return canRunNow(mailUnavailable: mailUnavailable)
        case .pause: return true
        case .resumeJob: return !isRunning && !mailUnavailable
        case .resumeDaily, .retryDaily: return isDailyActionEnabled && !mailUnavailable
        case .unavailable: return false
        }
    }

    /// Carries out `action`; shared by the toolbar button and Today's empty state.
    func perform(_ action: ToolbarRunAction) {
        switch action.behavior {
        case .runNow: Task { await runNow() }
        case .pause: pause()
        case .resumeJob(let id): Task { await resumeJob(id) }
        case .resumeDaily(let id): Task { await resumeCurrentDaily(id) }
        case .retryDaily(let id): Task { await resumeDailyJob(id, expecting: .failed) }
        case .unavailable: break
        }
    }

    /// Nothing is running, or only a Backlog job a Daily job may pre-empt (Q23).
    private var canRunDailyWork: Bool {
        guard !dailyStarting else { return false }
        return !isRunning || backlogIsPreemptable
    }

    private var backlogIsPreemptable: Bool { progress?.kind == .backlog && progress?.state == .running }

    // MARK: Daily lifecycle (Q52)

    /// The current Daily job, from the persisted job list with the runner's live state on top, so it is
    /// right after a relaunch as well as mid-session.
    var dailyLifecycle: DailyLifecycle { DailyLifecycle(jobs: pastJobs.map(\.job), live: progress) }

    /// The menu's primary Daily action. A Daily run that is starting has no job yet but already counts as running.
    var dailyAction: DailyMenuAction {
        if dailyStarting { return .running }
        let action = dailyLifecycle.menuAction
        // A Daily start that failed before any job existed offers Retry, which starts the run again.
        return dailyStartFailedAt != nil && action.behavior == .startNew ? .retryStart : action
    }

    /// When the last Daily start failed its Ollama check (no job was created), while that banner shows.
    var dailyStartFailedAt: Date? { bannerContext?.dailyStartFailedAt }

    var isDailyActionEnabled: Bool {
        switch dailyAction.behavior {
        case .startNew: return canStartDaily
        case .resume, .retry: return canRunDailyWork
        case .review: return true
        case .none: return false
        }
    }

    /// Why the Daily action is not Run Now, or that a scheduled run is waiting; nil when there is nothing to say.
    var dailyNote: String? {
        let lifecycle = dailyLifecycle
        var lines: [String] = []
        // The banner already gives a failed job's error in this session.
        let bannerExplains = banner != nil && failedJobID != nil && lifecycle.jobs.first?.id == failedJobID
            // The attention card gives the persisted failed job's error after a relaunch.
            || (menuAttention?.job).map { $0.id == lifecycle.jobs.first?.id } ?? false
        if let note = dailyAction.note, !bannerExplains { lines.append(note) }
        if scheduledRunWaiting, lifecycle != .none {
            lines.append("Today's scheduled Daily digest will run once the unfinished Daily job is finished.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The banner's Retry, unless the menu's Daily action already retries the same failed job.
    var showsBannerRetry: Bool {
        guard let failedJobID else { return false }
        if case .failed(let job) = dailyLifecycle, job.id == failedJobID { return false }
        return true
    }

    /// Whether the menu's progress card shows its own Resume. Not for the paused Daily job, whose Resume is
    /// the menu's primary action (Q52); other surfaces keep theirs.
    func menuCardShowsResume(for progress: JobProgress) -> Bool {
        if case .paused(let job) = dailyLifecycle, job.id == progress.jobID { return false }
        return true
    }

    /// What the menu bar icon shows. Progress is bucketed to 5% so the icon is rarely redrawn.
    var menuBarIcon: MenuBarIconState {
        guard let p = activeProgress else { return menuAttention == nil ? .idle : .warning }
        switch p.state {
        case .paused: return .paused
        case .listing: return .listing
        default:
            guard p.total > 0 else { return .listing }
            return .progress(step: Int((Double(min(p.done, p.total)) / Double(p.total) * 20).rounded(.down)))
        }
    }

    // MARK: Menu panel

    /// The failure the menu panel shows in place of the job section, or nil. Covers a failed job from this
    /// session, a persisted failed Daily job after a relaunch, and any other banner.
    struct MenuAttention: Equatable {
        /// The failed job, when the failure belongs to one.
        var job: Job?
        var card: MenuAttentionCard
        /// Subtitle under the job title ("Started 6:30 am · stopped before reading any emails").
        var subtitle: String?
        var title: String?
        var showsRetry: Bool
    }

    /// Nil while a job is active; the progress card shows instead.
    var menuAttention: MenuAttention? {
        guard activeProgress == nil else { return nil }
        var failed: Job?
        if let failedJobID, let job = pastJobs.first(where: { $0.id == failedJobID })?.job, job.state == .failed {
            failed = job
        } else if case .failed(let job) = dailyLifecycle {
            failed = job
        }
        let startFailedAt = failed == nil ? dailyStartFailedAt : nil
        guard failed != nil || banner != nil else { return nil }
        let message = banner ?? failed?.lastError ?? "The job stopped before it finished."
        // A banner explains itself; the failed job's stored kind only applies when there is no banner.
        let kind = banner != nil ? bannerContext?.kind : failed?.failureKind
        let locale = Locale.current
        let calendar = library.calendar
        let title = failed.map { MenuPanelPresentation.jobTitle($0, calendar: calendar, locale: locale) }
            ?? startFailedAt.map { at in
                MenuPanelPresentation.jobTitle(kind: .daily, from: at, to: at, calendar: calendar, locale: locale)
            }
        let card = MenuPanelPresentation.attentionCard(kind: kind, jobTitle: title, message: message,
                                                       model: settings.settings.resolvedModel)
        var subtitle = failed.map {
            MenuPanelPresentation.attentionSubtitle(startedAt: $0.startedAt, done: $0.totals.done + $0.totals.failed,
                                                    total: $0.totals.done + $0.totals.failed + $0.totals.queued,
                                                    calendar: calendar, locale: locale)
        }
        if let startFailedAt {
            subtitle = MenuPanelPresentation.attentionSubtitle(startedAt: startFailedAt, done: 0, total: 0,
                                                               calendar: calendar, locale: locale)
        }
        return MenuAttention(job: failed, card: card, subtitle: subtitle, title: title,
                             showsRetry: failed != nil || startFailedAt != nil || showsBannerRetry)
    }

    /// The Retry in the attention card: continues the failed job by id. Disabled while anything runs.
    var isAttentionRetryEnabled: Bool {
        guard let job = menuAttention?.job else { return dailyStartFailedAt != nil ? canStartDaily : !isRunning }
        return job.kind == .daily ? canRunDailyWork : !isRunning
    }

    func retryAttention() async {
        guard let job = menuAttention?.job else {
            if dailyStartFailedAt != nil { return await runNow() }
            return await retryFailedJob()
        }
        if case .failed(let daily) = dailyLifecycle, daily.id == job.id {
            await resumeDailyJob(job.id, expecting: .failed)
        } else {
            await resumeJob(job.id)
        }
    }

    /// Title of the job in the progress card; Backlog jobs carry their date range.
    func menuJobTitle(for progress: JobProgress) -> String {
        if let job = pastJobs.first(where: { $0.id == progress.jobID })?.job {
            return MenuPanelPresentation.jobTitle(job, calendar: library.calendar, locale: .current)
        }
        return progress.kind == .daily ? "Daily Digest" : "Backlog"
    }

    /// The name a paused or stopped job goes by: "Daily Digest", or the Backlog job's sidebar title.
    func haltedJobName(_ job: Job) -> String {
        job.kind == .daily ? "Daily Digest" : BacklogRowText.title(job, calendar: library.calendar)
    }

    func haltedJobName(for progress: JobProgress) -> String {
        if let job = pastJobs.first(where: { $0.id == progress.jobID })?.job { return haltedJobName(job) }
        return progress.kind == .daily ? "Daily Digest" : "Backlog"
    }

    /// The newest Daily or Backlog job when it is stopped with work left and nothing is running: the menu shows
    /// "Stopped at 12 of 40" with a Resume button. A paused job is shown by the progress card instead.
    var menuStoppedJob: (job: Job, line: String)? {
        guard activeProgress == nil, !isRunning, let job = pastJobs.first?.job,
              job.state == .stopped, job.totals.queued > 0,
              let line = MenuPanelPresentation.haltedLine(job, jobTitle: haltedJobName(job)) else { return nil }
        return (job, line)
    }

    /// The Resume next to "Stopped at …". Continues that job in place; a stopped job only ever resumes from
    /// an explicit click like this one (Q48).
    func resumeStoppedJob(_ job: Job) async {
        if job.kind == .daily { await resumeDailyJob(job.id, expecting: .stopped) } else { await resumeJob(job.id) }
    }

    /// The menu or toolbar Resume for the current Daily job, whichever of paused or stopped it is.
    func resumeCurrentDaily(_ jobID: UUID) async {
        let state: JobState = dailyLifecycle.jobs.first(where: { $0.id == jobID })?.state == .stopped ? .stopped : .paused
        await resumeDailyJob(jobID, expecting: state)
    }

    /// "Local · Qwen3 4B".
    var menuModelLabel: String {
        "Local · " + RoutingPresentation.modelDisplayName(settings.settings.resolvedModel)
    }

    /// The latest Daily digest as a one-line row; follows approvals and dismissals through the archive.
    func menuSuggestionsRow(now: Date) -> MenuSuggestionsRow? {
        library.archive.latestDaily.map {
            MenuPanelPresentation.suggestionsRow($0, now: now, calendar: library.calendar, locale: .current)
        }
    }

    private func showBanner(_ text: String, kind: JobFailureKind?, dailyStartFailedAt: Date? = nil) {
        banner = text
        bannerContext = (kind, dailyStartFailedAt)
    }

    private func showError(_ error: Error) {
        let kind: JobFailureKind?
        if case JobRunnerError.providerUnavailable(_, let k) = error { kind = k } else { kind = nil }
        showBanner(Self.message(for: error), kind: kind)
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
        // `openStore` attaches the review models.
        guard let store = await openStore() else { return }
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
            await coordinator.attach(store: opened)
            await processed.attach(store: opened)
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
    /// While a Daily job is unresolved the run waits (Q52): no second Daily job, no resume of the old one,
    /// and the next check after the user resolves it starts the run if it is still due.
    func runIfDue() async {
        guard !dailyStarting, let store = await openStore() else { return }
        guard let jobs = try? await store.jobs() else { return }
        let s = settings.settings
        switch MorningSchedule.decision(now: clock.now(), hour: s.runHour, minute: s.runMinute, jobs: jobs,
                                        live: progress) {
        case .notDue:
            scheduledRunWaiting = false
        case .deferred:
            if !scheduledRunWaiting { Self.log.notice("scheduled daily run waiting for an unresolved daily job") }
            scheduledRunWaiting = true
        case .start:
            scheduledRunWaiting = false
            if canRunDailyWork { await runDaily(trigger: .scheduled) }
        }
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
        guard canStartDaily else {
            if trigger == .manual, !dailyStarting, dailyLifecycle != .none {
                banner = Self.message(for: JobRunnerError.dailyJobUnresolved)
            }
            return
        }
        // A Daily run that preempts a running Backlog job leaves that run's own bookkeeping alone.
        let preempting = isRunning
        Self.log.notice("daily run starting: trigger=\(trigger == .scheduled ? "scheduled" : "manual", privacy: .public)")
        dailyStarting = true
        if !preempting {
            busyFlag = true
            progressText = "Starting…"
        }
        banner = nil
        defer {
            dailyStarting = false
            if !preempting { busyFlag = false; progressText = nil }
        }

        guard let store = await openStore() else { return }

        // Check Ollama first so a down server doesn't cost a mail listing (Q25).
        let checkedAt = clock.now()
        do {
            try await llm.healthCheck()
        } catch let error as LLMError {
            showBanner(error.userMessage, kind: JobFailureKind(error), dailyStartFailedAt: checkedAt)
            return
        } catch {
            showBanner("Ollama is not reachable. Start Ollama, or run `ollama pull qwen3:4b`.", kind: .ollamaUnreachable,
                       dailyStartFailedAt: checkedAt)
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
            await runner.setResourceBlockers(currentBlockers(), overnight: currentOvernightBlock())
            try await runner.startDaily()
            evaluateResources(force: true)
            await runner.waitUntilIdle()
        } catch JobRunnerError.dailyJobUnresolved {
            // The store had a Daily job the menu had not loaded yet; show it rather than a second job.
            if trigger == .scheduled { scheduledRunWaiting = true } else {
                banner = Self.message(for: JobRunnerError.dailyJobUnresolved)
            }
            await refreshJobLists()
            return
        } catch {
            showError(error)
            return
        }
        await finishRun(startedAt: startedAt)
    }

    /// The menu's Resume (paused or stopped) or Retry (failed) for the current Daily job (Q52). Continues that exact job
    /// and its queue; never creates a job. The job is re-read first, so a click on a menu drawn before the job
    /// changed does nothing but refresh. A running Backlog job is pre-empted, as for Run Now.
    func resumeDailyJob(_ jobID: UUID, expecting state: JobState) async {
        guard canRunDailyWork, let store = await openStore() else { return }
        let preempting = isRunning
        dailyStarting = true
        if !preempting {
            busyFlag = true
            progressText = "Starting…"
        }
        banner = nil
        defer {
            dailyStarting = false
            if !preempting { busyFlag = false; progressText = nil }
        }
        guard let jobs = try? await store.jobs(), let job = jobs.first(where: { $0.id == jobID }),
              job.kind == .daily, job.state == state, DailyLifecycle(jobs: jobs).jobs.map(\.id) == [jobID] else {
            await refreshJobLists()
            return
        }
        if preempting {
            // Don't pause the Backlog job for a resume that would fail on a down Ollama anyway (Q25).
            do { try await llm.healthCheck() } catch {
                showBanner((error as? LLMError)?.userMessage
                           ?? "Ollama is not reachable. Start Ollama, or run `ollama pull qwen3:4b`.",
                           kind: (error as? LLMError).map { JobFailureKind($0) } ?? .ollamaUnreachable)
                return
            }
        }
        guard let runner = await ensureRunner() else { return }
        do {
            await runner.setResourceBlockers(currentBlockers(), overnight: currentOvernightBlock())
            try await runner.resume(jobID: jobID)
            restoredProgress = nil
            await runner.waitUntilIdle()
        } catch {
            showError(error)
            await refreshJobLists()
            return
        }
        await finishRun(jobID: jobID)
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

    /// Stop the job; finished items stay done and the rest can be resumed later. A paused job has no loop to
    /// stop, so it is stored as stopped directly (Q15).
    func stop() {
        guard let runner else { return }
        guard let paused = activeProgress, paused.state == .paused else {
            Task { await runner.stop() }
            return
        }
        let jobID = paused.jobID
        Task {
            do { try await runner.stopPaused(jobID: jobID) } catch {
                Self.log.error("stop paused job failed: \(String(describing: error), privacy: .public)")
            }
            if progress?.jobID == jobID, progress?.state == .paused { progress = nil }
            await refreshJobLists()
        }
    }

    /// Resumes a paused, stopped or failed job by id, including one from a previous session.
    func resumeJob(_ jobID: UUID) async {
        guard !isRunning else { return }
        busyFlag = true
        banner = nil
        progressText = "Starting…"
        defer { busyFlag = false; progressText = nil }
        guard let runner = await ensureRunner() else { return }
        do {
            await runner.setResourceBlockers(currentBlockers(), overnight: currentOvernightBlock())
            try await runner.resume(jobID: jobID)
            restoredProgress = nil
            await runner.waitUntilIdle()
        } catch {
            showError(error)
            // A blocked resume leaves the job paused with its reason; show that in the strip and Activity.
            await refreshJobLists()
            return
        }
        await finishRun(jobID: jobID)
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
            await runner.setResourceBlockers(currentBlockers(), overnight: currentOvernightBlock())
            try await runner.retryFailed(jobID: jobID)
            restoredProgress = nil
            await runner.waitUntilIdle()
        } catch {
            showError(error)
            await refreshJobLists()
            return
        }
        await finishRun(jobID: jobID)
    }

    /// Job setup: lists headers for the plan and reports what Start would queue. Nothing is queued.
    func previewJob(_ plan: JobPlan, secondsPerEmail: Double? = nil) async throws -> JobPreview {
        guard let runner = await ensureRunner() else { throw JobSetupError.databaseUnavailable }
        return try await runner.preview(plan, secondsPerEmail: secondsPerEmail)
    }

    /// Job setup (Q79): the median seconds per email of the last 5 completed jobs on the local model, or 360
    /// seconds when there is no such history. Reads job items only, never mail.
    func backlogSecondsPerEmail() async -> Double {
        guard let store = await openStore() else { return BacklogEstimate.fallbackSecondsPerEmail }
        let jobs = (try? await store.jobs()) ?? []
        var samples: [Double] = []
        for job in BacklogEstimate.completedJobs(jobs) where samples.count < BacklogEstimate.sampleJobCount {
            guard let items = try? await store.items(job: job.id) else { continue }
            if let seconds = BacklogEstimate.secondsPerEmail(of: items) { samples.append(seconds) }
        }
        return BacklogEstimate.secondsPerEmail(samples: samples)
    }

    /// Job setup, "Since Last Job": where the newest earlier Backlog job's scope ended.
    func lastBacklogScopeEnd() async -> Date? {
        guard let store = await openStore(), let jobs = try? await store.jobs() else { return nil }
        return jobs.first { $0.kind == .backlog && $0.state != .failed }?.scopeTo
    }

    /// Job setup: emails per day from the Mail index (Full Disk Access), or nil when it is unavailable.
    /// One grouped query; no message is opened and Mail is not scripted.
    func dailyVolume(in refs: [MailboxRef], from: Date, to: Date) async -> [DayCount]? {
        try? await source.dailyCounts(in: refs, from: from, to: to)
    }

    /// Job setup: queues exactly the confirmed plan and starts it in the background. Returns once the job is
    /// queued; progress then arrives through the progress strip. Returns the failure otherwise.
    func startBacklog(_ plan: JobPlan) async -> BacklogStartFailure? {
        guard !isRunning else { return BacklogStartFailure(message: "Another job is already running.") }
        busyFlag = true
        banner = nil
        progressText = "Starting…"
        guard let runner = await ensureRunner() else {
            busyFlag = false; progressText = nil
            return BacklogStartFailure(message: banner ?? "Could not open the Mail Digest database.")
        }
        do {
            // Q43: a job created while a rule applies is stored paused before any email is read.
            await runner.setResourceBlockers(currentBlockers(), overnight: currentOvernightBlock())
            try await runner.start(plan)
        } catch {
            busyFlag = false; progressText = nil
            return BacklogStartFailure(message: Self.message(for: error),
                                       previewOutdated: (error as? JobRunnerError) == .previewOutdated)
        }
        evaluateResources(force: true)
        // The new job shows in the sidebar and Activity at once, before it has a digest.
        await library.refresh()
        await refreshJobLists()
        Task {
            await runner.waitUntilIdle()
            busyFlag = false
            progressText = nil
            await finishRun()
        }
        return nil
    }

    /// Shows the outage banner if the job stopped as failed; otherwise summarises it. `jobID` names the job
    /// that was resumed, which need not be the newest one.
    private func finishRun(startedAt: Date? = nil, jobID: UUID? = nil) async {
        guard let store else { return }
        defer { Task { await refreshJobLists() } }
        let jobs = try? await store.jobs()
        let job = jobID.flatMap { id in jobs?.first { $0.id == id } } ?? jobs?.first
        if let job, job.state == .failed {
            failedJobID = job.id
            showBanner(job.lastError ?? "The run stopped. Try again.", kind: job.failureKind)
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
        await processed.refresh()
    }

    // MARK: Job lists, activity and resources

    /// The runner for the current settings, created on demand (for example to resume an old job at launch).
    private func ensureRunner() async -> JobRunner? {
        guard let store = await openStore() else { return nil }
        // Every job start or resume comes through here: one System One preflight per job, fresh key read.
        if !Self.isActive(progress?.state, includePaused: false) { await cloudRouting.resetForNewJob() }
        return await runner(for: mailboxes.filter { $0.kind == .inbox }.map(\.ref), store: store)
    }

    /// Reloads the job list and the paused-job strip from the store.
    func refreshJobLists() async {
        await refreshPastJobs()
        await restoreResumableJob()
    }

    func refreshPastJobs() async {
        guard let store, let jobs = try? await store.jobs() else { return }
        pastJobs = jobs.map { PastJobRow(job: $0) }
        // A scheduled run that waited for this Daily job is checked again as soon as the job is resolved,
        // rather than at the next 15-minute tick; the schedule rule still decides whether it is due.
        if scheduledRunWaiting, dailyLifecycle == .none, !dailyStarting {
            Task { await runIfDue() }
        }
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
        // After a wake or a boundary the readings may look unchanged although the window just opened.
        monitor.onTimeMayHaveChanged = { [weak self] in self?.evaluateResources(force: true) }
        monitor.start()
        evaluateResources(force: true)
    }

    /// Applies the core resource policy when the set of blocking reasons changes (or once more with `force`).
    /// Start and Resume check the same rules themselves (Q43), so a manual Resume never overrides them.
    /// Overnight-only jobs waiting for these rules are started here, also at launch and after a wake.
    func evaluateResources(force: Bool = false) {
        let policy = settings.settings.resourcePolicy()
        let now = clock.now()
        // The overnight window matters even with "Only run during this time window" off, because a job created
        // as "Overnight While Plugged In" waits for it; the boundary timer is what starts that job tonight.
        monitor.scheduleBoundary(at: policy.overnightWindow.nextBoundary(after: now, in: policy.timeZone))
        updateSleepAssertion()
        let windows: [QuietHours?] = [policy.overnightWindow, policy.quietHours]
        let windowChanged = windows != lastWindows
        lastWindows = windows
        let blocked = currentBlockers()
        let overnight = currentOvernightBlock()
        guard force || windowChanged || autoStartPending || blocked != lastBlocked
                || overnight != lastOvernightBlock else { return }
        lastBlocked = blocked
        lastOvernightBlock = overnight
        // Never start Mail work before onboarding and access checks pass; try again at the next evaluation.
        if !Self.isActive(progress?.state, includePaused: false), !autoStartGate() {
            autoStartPending = true
            return
        }
        autoStartPending = false
        Task { await applyResourceRulesNow() }
    }

    /// Hands the current rules to the runner. Without a runner it is only created when an overnight job is
    /// waiting, so nobody else gets one (or a Mail prompt) from this path.
    private func applyResourceRulesNow() async {
        var target = runner
        if target == nil {
            guard let store = await openStore(), let jobs = try? await store.jobs() else {
                autoStartPending = true
                return
            }
            guard jobs.contains(where: { $0.overnightOnly && OvernightPolicy.isAutoResumeCandidate($0, autoPausedThisSession: false) })
            else { return }
            target = await ensureRunner()
        }
        guard let target else { autoStartPending = true; return }
        do {
            try await target.applyResourceRules(currentBlockers(), overnight: currentOvernightBlock())
        } catch {
            Self.log.error("resource rules failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Holds the idle-sleep assertion only while an overnight-only job works on mains power. It reads the
    /// latest state every time, so any order of updates ends in the right answer.
    private func updateSleepAssertion() {
        guard let progress else { IdleSleepAssertion.shared.set(false); return }
        guard let overnightOnly = overnightJobFlags[progress.jobID] else {
            IdleSleepAssertion.shared.set(false)
            lookUpOvernightFlag(progress.jobID)
            return
        }
        IdleSleepAssertion.shared.set(OvernightPolicy.shouldPreventIdleSleep(
            state: progress.state, overnightOnly: overnightOnly, onBattery: monitor.conditions.onBattery))
    }

    private func lookUpOvernightFlag(_ id: UUID) {
        guard overnightLookups.insert(id).inserted else { return }
        Task {
            let job = try? await openStore()?.jobs().first { $0.id == id }
            overnightJobFlags[id] = job?.overnightOnly ?? false
            overnightLookups.remove(id)
            updateSleepAssertion()
        }
    }

    /// The extra rule for jobs created as overnight-only: outside the overnight window, or on battery.
    private func currentOvernightBlock() -> PauseReason? {
        settings.settings.resourcePolicy().overnightBlockingReason(conditions: monitor.conditions, now: clock.now())
    }

    /// The resource rules that apply right now, by job kind (Daily only honours Low Power Mode).
    private func currentBlockers() -> [JobKind: PauseReason] {
        settings.settings.resourcePolicy().blocked(conditions: monitor.conditions, now: clock.now())
    }

    // MARK: Senders

    /// Senders of recent mail for Settings > Senders' "Add from Recent Senders…", read only from `job_item` rows
    /// already on this Mac (the newest jobs). Addresses already on `list` are left out.
    func recentSenders(excluding list: SenderList) async -> [RecentSender] {
        guard let store = await openStore(), let jobs = try? await store.jobs() else { return [] }
        var items: [JobItem] = []
        for job in jobs.sorted(by: { $0.createdAt > $1.createdAt }).prefix(10) {
            items += (try? await store.items(job: job.id)) ?? []
        }
        return RecentSender.rank(items, excludingRules: settings.settings.senders(in: list))
    }

    // MARK: Delete all history

    /// Settings > General > Delete All History…. Uses the retention path: pinned digests and unfinished or
    /// resumable jobs (with their digests and context) are kept, processed ids and sender decisions are never
    /// deleted, and nothing in Mail or Reminders is touched. Returns the message to show.
    func deleteAllHistory() async -> DeleteHistoryResult {
        guard let store = await openStore() else { return .failure("The Mail Digest database could not be opened.") }
        do {
            let plan = RetentionPolicy().deleteAllPlan(digests: try await store.retainedDigests(),
                                                       jobs: try await store.jobs())
            try await store.apply(plan)
            Self.log.notice("delete all history: digests=\(plan.digestIDs.count, privacy: .public) jobs=\(plan.jobIDs.count, privacy: .public)")
            await review.reload()
            await processed.refresh()
            await refreshJobLists()
            if let digest = try? await store.latestDigest() {
                lastRunSummary = Self.summary(for: digest)
            } else {
                lastRunSummary = nil
            }
            let n = plan.digestIDs.count
            return .success(n == 0 ? "There was no history to delete."
                                   : "Deleted \(n) \(n == 1 ? "digest" : "digests"). Pinned items and unfinished jobs were kept.")
        } catch {
            Self.log.error("delete all history failed: \(String(describing: error), privacy: .public)")
            return .failure("History could not be deleted. Nothing was changed.")
        }
    }

    // MARK: Backlog job rename and delete (sidebar)

    /// Names a Backlog job; blank text clears the name, so the sidebar shows its mailbox title again.
    func renameBacklogJob(_ jobID: UUID, to name: String) async {
        guard let store = await openStore() else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.renameJob(id: jobID, name: trimmed.isEmpty ? nil : trimmed)
        } catch {
            Self.log.error("rename job failed: \(String(describing: error), privacy: .public)")
            banner = "The job could not be renamed."
            return
        }
        await library.refresh()
        await refreshPastJobs()
    }

    /// Deletes a Backlog job with its digest, results and items. Processed ids and sender decisions stay, and
    /// nothing in Mail or Reminders is touched. Refuses a job the runner holds.
    func deleteBacklogJob(_ jobID: UUID) async {
        guard activeProgress?.jobID != jobID, let store = await openStore() else { return }
        do {
            try await store.apply(RetentionPlan(digestIDs: [jobID], jobIDs: [jobID]))
        } catch {
            Self.log.error("delete job failed: \(String(describing: error), privacy: .public)")
            banner = "The job could not be deleted. Nothing was changed."
            return
        }
        // A selection on the deleted job falls back to Today in `loadSelected`.
        await review.reload()
        await processed.refresh()
        await refreshJobLists()
        await library.refresh()
        await coordinator.loadSelected()
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
        relevant.showSenderLogos = false // Read live by the logo provider; no runner needed.
        relevant.remindersListName = DigestSettings.defaultListName
        relevant.runHour = 6; relevant.runMinute = 30
        relevant.declinedIgnoreSuggestions = []
        relevant.autoFileProcessed = false
        relevant.autoFileEnabledAt = nil
        relevant.pauseBacklogOnBattery = true
        relevant.quietHoursEnabled = false
        relevant.quietHoursStartMinute = DigestSettings().quietHoursStartMinute
        relevant.quietHoursEndMinute = DigestSettings().quietHoursEndMinute
        // Cloud settings are read live for every email, so they never need a new runner.
        let cloudDefaults = DigestSettings()
        relevant.cloudDigestEnabled = cloudDefaults.cloudDigestEnabled
        relevant.geminiModel = cloudDefaults.geminiModel
        relevant.triageModel = cloudDefaults.triageModel
        relevant.privacyThreshold = cloudDefaults.privacyThreshold
        relevant.cloudPrivacyAcknowledgedRevision = nil
        let key = RunnerKey(settings: relevant, inboxes: Set(inboxes))
        if let runner, key == runnerKey { return runner }
        progressTask?.cancel()
        let provider = cloudRouting
        let new = JobRunner(source: source, llm: llm, store: store, notifier: notifier, clock: clock,
                            settings: settings.settings.runnerSettings(inboxes: inboxes),
                            localModel: settings.settings.resolvedModel,
                            routingConfig: { await provider.config() },
                            logoRecorder: logoService)
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
        let changed = progress?.jobID != update.jobID || progress?.state != update.state
        progress = update
        updateSleepAssertion()
        // Keeps the Daily lifecycle (built from the job list) in step, for example for a just-created job.
        if changed { Task { await refreshPastJobs() } }
        // Show finished results while the job runs. The runner already throttles updates to 2 a second.
        if update.state == .running, update.done != lastRefreshedDone {
            lastRefreshedDone = update.done
            Task {
                await review.reload()
                await refreshActivity(jobID: update.jobID)
                // Q42: file each newly finished result now, not when the whole job ends.
                await processed.refresh()
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
        if case JobRunnerError.providerUnavailable(let message, _) = error { return message }
        if case JobRunnerError.resourceBlocked(let reason) = error { return reason.blockedMessage }
        if case JobRunnerError.nothingToProcess = error { return "There are no emails to process in this selection." }
        if case JobRunnerError.previewOutdated = error {
            return "These emails changed after the preview. Check the updated preview, then start again."
        }
        if case JobRunnerError.dailyJobUnresolved = error {
            return "A Daily job is unfinished. Resume it, or review it in Activity, before a new Daily digest runs."
        }
        if case OsascriptError.automationDenied = error {
            return "Mail automation is off. Open Mail Access to allow it."
        }
        return "Could not read Mail. Open Mail Access to check permissions."
    }
}


/// A stored job, for the Daily lifecycle and the menu panel.
struct PastJobRow: Identifiable, Equatable, Sendable {
    var job: Job

    var id: UUID { job.id }
}

enum JobSetupError: Error { case databaseUnavailable }

/// Why a Backlog start did not begin. `previewOutdated` tells the setup window to reload its preview.
struct BacklogStartFailure: Equatable {
    var message: String
    var previewOutdated = false
}

/// What "Delete All History Now" reports back to Settings.
enum DeleteHistoryResult: Equatable {
    case success(String)
    case failure(String)
}
