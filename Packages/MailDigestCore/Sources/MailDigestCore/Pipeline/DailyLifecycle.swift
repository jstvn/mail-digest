import Foundation

/// The current Daily job, derived from persisted jobs (Q52). Finished Daily jobs are history; at most one
/// Daily job may be unresolved at a time, and a new Daily job is only created when none is.
///
/// Unresolved means the job still needs the runner or a deliberate user decision: listing, running,
/// pausing or stopping, or paused, stopped or failed with queued work left. A paused, stopped or failed
/// job with nothing queued has nothing to continue, so it does not block a new Daily job; a failed one is
/// also excluded from the Daily cursor (Q23), so its window is listed again. Backlog jobs never count.
public enum DailyLifecycle: Equatable, Sendable {
    /// No unresolved Daily job: a new Daily job may be created.
    case none
    /// Listing, running or pausing.
    case running(Job)
    case stopping(Job)
    case paused(Job)
    case stopped(Job)
    /// Stopped by a provider, Mail or store failure with its queue intact (Q25).
    case failed(Job)
    /// More than one unresolved Daily job, newest first (data from an earlier version). Nothing is picked
    /// for the user; each is resolved explicitly from Activity.
    case conflict([Job])

    /// Derives the state from `jobs`. `live` overlays the runner's in-memory state (for example `.pausing`)
    /// on the matching persisted job, so the result is current between store refreshes.
    public init(jobs: [Job], live: JobProgress? = nil) {
        let unresolved = jobs.compactMap { job -> Job? in
            var job = job
            if let live, live.jobID == job.id {
                job.state = live.state
                job.totals.queued = max(0, live.total - live.done)
            }
            return job.kind == .daily && Self.isUnresolved(job) ? job : nil
        }
        guard let job = unresolved.first else { self = .none; return }
        guard unresolved.count == 1 else { self = .conflict(unresolved); return }
        switch job.state {
        case .stopping: self = .stopping(job)
        case .paused: self = .paused(job)
        case .stopped: self = .stopped(job)
        case .failed: self = .failed(job)
        default: self = .running(job)
        }
    }

    /// Whether `job` still needs the runner or the user. Ignores the job's kind.
    public static func isUnresolved(_ job: Job) -> Bool {
        switch job.state {
        case .listing, .running, .pausing, .stopping: return true
        case .paused, .stopped, .failed: return job.totals.queued > 0
        case .idle, .finished: return false
        }
    }

    /// The unresolved Daily jobs, newest first.
    public var jobs: [Job] {
        switch self {
        case .none: return []
        case .running(let job), .stopping(let job), .paused(let job), .stopped(let job), .failed(let job):
            return [job]
        case .conflict(let jobs): return jobs
        }
    }

    /// The menu's primary Daily action for this state.
    public var menuAction: DailyMenuAction {
        switch self {
        case .none:
            return DailyMenuAction(title: "Run Daily Digest Now", systemImage: "play", behavior: .startNew)
        case .running:
            return .running
        case .stopping:
            return DailyMenuAction(title: "Stopping…", systemImage: "stop", behavior: .none)
        case .paused(let job):
            return DailyMenuAction(title: "Resume", systemImage: "play", behavior: .resume(job.id),
                                   accessibilityLabel: "Resume Daily Digest")
        case .stopped:
            return DailyMenuAction(title: "Review Daily Job…", systemImage: "list.bullet.rectangle",
                                   behavior: .review,
                                   note: "The Daily job was stopped. Resume it from Activity before a new Daily digest can run.")
        case .failed(let job):
            return DailyMenuAction(title: "Retry Daily Digest", systemImage: "arrow.clockwise", behavior: .retry(job.id),
                                   note: job.lastError ?? "The Daily job stopped before it finished.")
        case .conflict(let jobs):
            return DailyMenuAction(title: "Review Daily Jobs…", systemImage: "list.bullet.rectangle",
                                   behavior: .review,
                                   note: "\(jobs.count) Daily jobs are unfinished. Resume them from Activity before a new Daily digest can run.")
        }
    }
}

/// What the menu's primary Daily row shows and does (Q52).
public struct DailyMenuAction: Equatable, Sendable {
    public enum Behavior: Equatable, Sendable {
        /// Create a new Daily job (`JobRunner.startDaily()`).
        case startNew
        /// Resume this paused Daily job and its existing queue.
        case resume(UUID)
        /// Resume this failed Daily job by id, the Q25 recovery path.
        case retry(UUID)
        /// Open Activity so the user resolves the job(s) explicitly.
        case review
        /// A Daily job is busy; the row is disabled.
        case none
    }

    public var title: String
    public var systemImage: String
    public var behavior: Behavior
    /// VoiceOver label when the title alone is ambiguous.
    public var accessibilityLabel: String
    /// A short explanation shown under the row, or nil.
    public var note: String?

    public init(title: String, systemImage: String, behavior: Behavior, accessibilityLabel: String? = nil,
                note: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.behavior = behavior
        self.accessibilityLabel = accessibilityLabel ?? title
        self.note = note
    }

    /// A Daily job is listing, running or pausing, or a Daily run or resume is starting.
    public static let running = DailyMenuAction(title: "Daily Digest Running…", systemImage: "hourglass",
                                                behavior: .none)

    /// After a Daily start failed its Ollama check, before any job existed: the same start, offered as Retry.
    public static let retryStart = DailyMenuAction(title: "Retry Daily Digest", systemImage: "arrow.clockwise",
                                                   behavior: .startNew)

    /// Whether the row can be clicked at all; the app adds its own conditions (Mail access, a running job).
    public var isActionable: Bool { behavior != .none }
}
