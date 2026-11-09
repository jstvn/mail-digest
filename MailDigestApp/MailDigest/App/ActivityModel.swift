import Foundation
import MailDigestCore
import Observation
import OSLog

private let activityLog = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "activity")

/// What one expanded job shows: lifecycle events and per-email rows, loaded on demand.
struct ActivityJobDetail: Equatable {
    var events: [JobEvent] = []
    var items: [JobItem] = []
    var isLoaded = false
    var loadFailed = false
}

/// The Activity canvas: keyset pages of jobs, the two filters, section and job expansion, and lazily loaded
/// details. Store calls are awaited (off the main actor); only the merge into state happens here.
@MainActor @Observable
final class ActivityModel {
    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", daily = "Daily", backlog = "Backlog"
        var id: String { rawValue }
        var kind: JobKind? { self == .daily ? .daily : self == .backlog ? .backlog : nil }
    }

    enum PathFilter: String, CaseIterable, Identifiable {
        case all = "All", local = "Local", cloud = "Cloud"
        var id: String { rawValue }
        var provider: ExecutionProvider? { self == .local ? .local : self == .cloud ? .cloud : nil }
    }

    static let pageSize = 30

    private(set) var timeline = ActivityTimeline()
    private(set) var hasMore = false
    private(set) var isLoaded = false
    private(set) var isLoadingMore = false
    private(set) var loadFailed = false
    private(set) var details: [UUID: ActivityJobDetail] = [:]
    /// Jobs the user expanded; their details refresh while the job is live.
    private(set) var expandedJobs: Set<UUID> = []
    /// Sections the user opened or closed; others follow the default (newest open).
    private(set) var sectionExpansion: [Date: Bool] = [:]

    /// Shows jobs that finished having found no emails. Off by default; a running, paused, stopped or failed
    /// job is always shown (`ActivityTimeline.isEmptyRun`).
    var showEmptyRuns = false
    var kindFilter: KindFilter = .all { didSet { if kindFilter != oldValue { filtersChanged() } } }
    var pathFilter: PathFilter = .all { didSet { if pathFilter != oldValue { filtersChanged() } } }

    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private let gate = ReloadGate()
    /// Bumped by a filter change so an older in-flight page is discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var trailing: Task<Void, Never>?

    init() {}

    /// Previews: fixed jobs and details.
    init(preview jobs: [Job], details: [UUID: ActivityJobDetail] = [:], hasMore: Bool = false) {
        self.timeline = ActivityTimeline(jobs: jobs)
        self.details = details
        self.hasMore = hasMore
        self.isLoaded = true
    }

    private var query: ActivityQuery {
        ActivityQuery(kind: kindFilter.kind, path: pathFilter.provider, before: nil, limit: Self.pageSize)
    }

    // MARK: Pages

    /// Loads or refreshes the first page and merges it by id, so rows, scroll position and expansion stay put.
    /// Expanded jobs that are still live reload their details too.
    func load(store: any DigestStore) async {
        self.store = store
        await gate.run { await refreshFirstPage(store: store) }
    }

    /// Like `load`, but at most once a second: a call inside the window schedules one trailing refresh.
    func liveRefresh() {
        guard let store else { return }
        let clock = ContinuousClock()
        if let last = lastRefresh, last.duration(to: clock.now) < .seconds(1) {
            guard trailing == nil else { return }
            trailing = Task { [weak self] in
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.trailing = nil
                await self?.load(store: store)
            }
            return
        }
        Task { await load(store: store) }
    }

    private func refreshFirstPage(store: any DigestStore) async {
        lastRefresh = ContinuousClock.now
        let gen = generation
        let q = query
        do {
            let page = try await store.activityJobs(q)
            guard gen == generation else { return }
            let first = !isLoaded
            timeline.merge(page)
            // Only the very first page decides whether older ones exist.
            if first { hasMore = page.count >= Self.pageSize }
            loadFailed = false
        } catch {
            activityLog.error("could not load activity: \(String(describing: error), privacy: .public)")
            if gen == generation { loadFailed = true }
        }
        if gen == generation { isLoaded = true }
        // Keep live, expanded jobs current.
        for job in timeline.jobs where expandedJobs.contains(job.id) && ActivityJobStatus(job).isLive {
            await loadDetail(job.id, store: store)
        }
    }

    /// Loads the next older page. Does nothing while loading or at the end.
    func loadMore() async {
        guard let store, hasMore, !isLoadingMore, let cursor = timeline.cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = generation
        var q = query
        q.before = cursor
        do {
            let page = try await store.activityJobs(q)
            guard gen == generation else { return }
            timeline.merge(page)
            hasMore = page.count >= Self.pageSize
        } catch {
            activityLog.error("could not load earlier activity: \(String(describing: error), privacy: .public)")
        }
    }

    /// A filter changed: start again from the first page.
    private func filtersChanged() {
        generation += 1
        timeline = ActivityTimeline()
        details = [:]
        hasMore = false
        isLoaded = false
        loadFailed = false
        trailing?.cancel()
        trailing = nil
        guard let store else { return }
        Task { await load(store: store) }
    }

    // MARK: Expansion

    func isSectionExpanded(_ id: Date, newest: Date?) -> Bool {
        sectionExpansion[id] ?? (id == newest)
    }

    func setSection(_ id: Date, expanded: Bool) { sectionExpansion[id] = expanded }

    func isJobExpanded(_ id: UUID) -> Bool { expandedJobs.contains(id) }

    /// Expanding loads the job's events and items once; collapsing keeps them for a quick reopen.
    func setJob(_ job: Job, expanded: Bool) {
        if expanded {
            expandedJobs.insert(job.id)
            if details[job.id]?.isLoaded != true, let store {
                Task { await loadDetail(job.id, store: store) }
            }
        } else {
            expandedJobs.remove(job.id)
        }
    }

    private func loadDetail(_ id: UUID, store: any DigestStore) async {
        do {
            let events = try await store.jobEvents(job: id)
            let items = try await store.items(job: id)
            details[id] = ActivityJobDetail(events: events, items: items, isLoaded: true)
        } catch {
            activityLog.error("could not load job detail: \(String(describing: error), privacy: .public)")
            var d = details[id] ?? ActivityJobDetail()
            d.loadFailed = true
            details[id] = d
        }
    }
}
