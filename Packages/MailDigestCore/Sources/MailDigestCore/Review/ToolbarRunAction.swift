import Foundation

/// What the review window's trailing toolbar button shows and does. It follows the job state the same way the
/// menu bar's Daily row does: Pause while a job runs, Resume for a paused one, Retry after a failure, and
/// Run Now otherwise. The Daily wording and behaviour come from `DailyLifecycle.menuAction`, not from copies.
public struct ToolbarRunAction: Equatable, Sendable {
    public enum Behavior: Equatable, Sendable {
        /// Start a Daily run (`runNow`); also a retry of a start that failed before any job existed.
        case runNow
        /// Pause the running job after the email in flight.
        case pause
        /// Resume the paused job held by the progress strip, whatever its kind.
        case resumeJob(UUID)
        /// Resume this paused Daily job (Q52).
        case resumeDaily(UUID)
        /// Retry this failed Daily job (Q25).
        case retryDaily(UUID)
        /// The button is shown but cannot act (a Daily job needs a decision in Activity, or is stopping).
        case unavailable
    }

    public var title: String
    public var systemImage: String
    public var behavior: Behavior
    /// Tooltip text.
    public var help: String

    public init(title: String, systemImage: String, behavior: Behavior, help: String) {
        self.title = title
        self.systemImage = systemImage
        self.behavior = behavior
        self.help = help
    }

    /// - Parameters:
    ///   - progress: the progress strip's job (`DigestRunModel.activeProgress`), if any.
    ///   - daily: the menu's Daily action (`DigestRunModel.dailyAction`).
    public init(progress: JobProgress?, daily: DailyMenuAction) {
        if let progress {
            switch progress.state {
            case .listing, .running:
                self.init(title: "Pause", systemImage: "pause.fill", behavior: .pause, help: "Pause after the current email")
                return
            case .pausing, .stopping:
                // Already on its way to a stop: shown, not clickable.
                self.init(title: "Pause", systemImage: "pause.fill", behavior: .unavailable,
                          help: progress.state == .pausing ? "Pausing after the current email" : "Stopping the job")
                return
            case .paused:
                let behavior: Behavior = daily.behavior == .resume(progress.jobID) ? .resumeDaily(progress.jobID)
                    : .resumeJob(progress.jobID)
                self.init(title: "Resume", systemImage: "play.fill", behavior: behavior, help: "Continue the paused job")
                return
            default: break
            }
        }
        switch daily.behavior {
        case .retry(let id):
            self.init(title: "Retry", systemImage: "arrow.clockwise", behavior: .retryDaily(id),
                      help: "Retry the Daily digest")
        case .resume(let id):
            self.init(title: "Resume", systemImage: "play.fill", behavior: .resumeDaily(id), help: "Continue the paused Daily job")
        case .startNew where daily == .retryStart:
            self.init(title: "Retry", systemImage: "arrow.clockwise", behavior: .runNow, help: "Try the Daily digest again")
        case .startNew:
            self.init(title: "Run Now", systemImage: "play.fill", behavior: .runNow, help: "Read your new mail now")
        case .review, .none:
            // A stopped or conflicting Daily job is resolved in Activity first; Run Now stays disabled.
            self.init(title: "Run Now", systemImage: "play.fill", behavior: .unavailable,
                      help: "Resume or review the unfinished Daily job first.")
        }
    }
}
