import Foundation
import MailDigestCore
import Observation
import OSLog

/// What the sidebar can select (Q54). `day` and `backlog` carry the thing they show.
enum SidebarItem: Hashable, Sendable {
    case today
    case reviewQueue
    case logbook
    case mailCleanup
    case activity
    case day(DigestDay)
    case backlog(UUID)
}

/// Runs a reload so overlapping calls coalesce: a call during a run only asks for one more pass, and the
/// pass reads the latest request. Same idea as `ReviewViewModel.reload`.
@MainActor
final class ReloadGate {
    private var running = false
    private var again = false

    func run(_ work: () async -> Void) async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await work()
        } while again
    }
}

/// The sidebar's data (Q56): per-digest counts from `digestSummaries()` and Backlog job metadata from
/// `jobs()`. It never loads a digest's contents, so it stays cheap to refresh while a job runs.
@MainActor @Observable
final class ReviewLibrary {
    /// Sidebar days, months, Backlog entries and badges.
    private(set) var archive: DigestArchive
    /// Backlog jobs by id, for sidebar titles.
    private(set) var backlogJobs: [UUID: Job] = [:]
    private(set) var isLoaded = false
    private(set) var loadFailed = false
    /// Gregorian calendar in the settings time zone; the day boundary for Today and Recent Digests.
    let calendar: Calendar

    /// Called after the calendar day changed and the archive was rebuilt, so Today can reload.
    @ObservationIgnored var onDayChanged: (@MainActor () async -> Void)?

    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let gate = ReloadGate()
    @ObservationIgnored private var dayObserver: (any NSObjectProtocol)?
    /// One-shot sleep until the next start of day in the settings time zone; replaced on every re-arm.
    @ObservationIgnored private var dayTimer: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init(clock: any Clock = SystemClock(), timeZone: TimeZone = RunnerSettings().timeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.clock = clock
        self.archive = DigestArchive(summaries: [], now: clock.now(), calendar: calendar)
    }

    /// Previews and tests: a fixed archive and no store.
    init(preview archive: DigestArchive, calendar: Calendar, backlogJobs: [Job] = []) {
        self.calendar = calendar
        self.clock = SystemClock()
        self.archive = archive
        self.backlogJobs = Dictionary(backlogJobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.isLoaded = true
    }

    /// Connects the store, starts watching for midnight, and loads the summaries.
    func attach(store: any DigestStore) async {
        self.store = store
        if dayObserver == nil {
            // Today is derived from the clock, so a new day must rebuild the archive even if no job runs.
            dayObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.dayDidChange() }
            }
        }
        await refresh()
    }

    /// Rebuilds the archive for the new day, then lets Today reload. Shared by the system notification and the timer.
    private func dayDidChange() async {
        await refresh()
        await onDayChanged?()
    }

    /// `NSCalendarDayChanged` follows the system time zone, but "today" follows the settings one, so also
    /// wake at the next start of day in `calendar`. Re-armed by every refresh, which replaces the old timer.
    private func armDayTimer() {
        dayTimer?.cancel()
        let now = clock.now()
        // A second of slack so the wake-up lands after midnight, not just before it.
        let delay = ReviewCanvasLogic.nextStartOfDay(after: now, calendar: calendar).timeIntervalSince(now) + 1
        dayTimer = Task { [weak self] in
            // Continuous clock: keeps counting while the Mac sleeps.
            try? await ContinuousClock().sleep(for: .seconds(max(delay, 1)))
            guard !Task.isCancelled else { return }
            // A fresh task: the refresh re-arms (cancels) this timer and must not cancel its own work.
            Task { @MainActor in await self?.dayDidChange() }
        }
    }

    /// Reloads the summaries and re-derives "today". Safe to call often: overlapping calls coalesce.
    func refresh() async {
        guard let store else { return }
        await gate.run {
            do {
                let summaries = try await store.digestSummaries()
                let jobs = try await store.jobs()
                archive = DigestArchive(summaries: summaries, now: clock.now(), calendar: calendar)
                backlogJobs = Dictionary(jobs.filter { $0.kind == .backlog }.map { ($0.id, $0) },
                                         uniquingKeysWith: { a, _ in a })
                loadFailed = false
            } catch {
                Self.log.error("could not load summaries: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
            isLoaded = true
        }
        armDayTimer()
    }

    /// Whether the sidebar still lists this item; a selection that vanished (retention cleanup) falls back to Today.
    func contains(_ item: SidebarItem) -> Bool {
        switch item {
        case .today, .reviewQueue, .logbook, .mailCleanup, .activity: return true
        case .day(let day): return !archive.digestIDs(for: day).isEmpty
        case .backlog(let id): return archive.hasBacklog(id)
        }
    }

    /// "Backlog · iCloud Inbox"; plain "Backlog" when the job row is gone.
    func title(forBacklog id: UUID) -> String {
        backlogJobs[id].map(JobSummaryText.title) ?? ReviewPresentation.jobName(.backlog)
    }

    /// "Everything up to 2 Nov 2026"; nil when the job row is gone.
    func scope(forBacklog id: UUID) -> String? {
        backlogJobs[id].map { JobSummaryText.scope($0, timeZone: calendar.timeZone) }
    }
}
