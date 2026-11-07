import Foundation

/// A job's state as the Activity list names it.
public enum ActivityJobStatus: String, Sendable, Equatable, CaseIterable {
    case notStarted, running, pausing, paused, stopping, stopped
    case completed, completedWithFailures, failed

    /// Derives the status from a stored job. A finished job with failed emails is "Completed with failures".
    public init(_ job: Job) {
        switch job.state {
        case .idle: self = .notStarted
        case .listing, .running: self = .running
        case .pausing: self = .pausing
        case .paused: self = .paused
        case .stopping: self = .stopping
        case .stopped: self = .stopped
        case .finished: self = job.totals.failed > 0 ? .completedWithFailures : .completed
        case .failed: self = .failed
        }
    }

    public var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .running: return "Running"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .completed: return "Completed"
        case .completedWithFailures: return "Completed with failures"
        case .failed: return "Failed"
        }
    }

    /// True while the runner is working on the job, so the row shows live progress and keeps refreshing.
    public var isLive: Bool { self == .running || self == .pausing || self == .stopping }
}

/// One day of jobs in the Activity list.
public struct ActivityDaySection: Sendable, Equatable, Identifiable {
    /// Start of the day in the calendar's time zone.
    public var id: Date
    /// "Today", "Yesterday" or "Fri, 6 Nov".
    public var title: String
    public var jobs: [Job]
}

/// The Activity list's jobs: merged pages in `(createdAt DESC, id DESC)` order, grouped by day.
/// Each job stays its own record, even when several share a day.
public struct ActivityTimeline: Sendable, Equatable {
    public private(set) var jobs: [Job]

    public init(jobs: [Job] = []) {
        self.jobs = []
        merge(jobs)
    }

    /// Adds jobs, replacing any with the same id in place of the old data, then restores the order.
    public mutating func merge(_ page: [Job]) {
        var byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for job in page { byID[job.id] = job }
        jobs = byID.values.sorted(by: Self.isBefore)
    }

    /// Where the next older page starts; nil when empty.
    public var cursor: ActivityCursor? { jobs.last.map(ActivityCursor.init(after:)) }

    /// Newest first; ties by id descending, compared as text like the store's `ORDER BY id DESC`.
    static func isBefore(_ a: Job, _ b: Job) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString > b.id.uuidString
    }

    /// Day sections by each job's `createdAt` day in `calendar`, relative to `now`.
    public func sections(calendar: Calendar, now: Date) -> [ActivityDaySection] {
        var out: [ActivityDaySection] = []
        let today = calendar.startOfDay(for: now)
        for job in jobs {
            let day = calendar.startOfDay(for: job.createdAt)
            if out.last?.id == day {
                out[out.count - 1].jobs.append(job)
            } else {
                out.append(ActivityDaySection(id: day, title: Self.sectionTitle(day: day, today: today, calendar: calendar),
                                              jobs: [job]))
            }
        }
        return out
    }

    /// "Today", "Yesterday", "Fri, 6 Nov", or "Fri, 6 Nov 2025" outside the current year.
    public static func sectionTitle(day: Date, today: Date, calendar: Calendar) -> String {
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "Yesterday" }
        let f = DateFormatter()
        // POSIX locale: stable English names ("Sep", not "Sept") on every platform.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        f.dateFormat = sameYear ? "EEE, d MMM" : "EEE, d MMM yyyy"
        return f.string(from: day)
    }
}

/// Text for one job row and for lifecycle events.
public enum ActivityText {
    /// "Daily Digest", or "Backlog · iCloud Inbox".
    public static func title(_ job: Job) -> String {
        job.kind == .daily ? "Daily Digest" : JobSummaryText.title(job)
    }

    /// Seconds from start to end, or to `now` while the job is live; nil when it never started.
    public static func elapsed(_ job: Job, now: Date) -> TimeInterval? {
        guard let start = job.startedAt else { return nil }
        let end = ActivityJobStatus(job).isLive ? now : (job.endedAt ?? now)
        return max(0, end.timeIntervalSince(start))
    }

    /// "1 h 05 min", "12 min 30 s", "45 s"; "—" when unknown.
    public static func elapsedText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d h %02d min", h, m) }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }

    /// "412 of 1,081 emails".
    public static func progressText(_ job: Job) -> String {
        let t = job.totals
        let finished = t.done + t.failed + t.skipped
        let total = finished + t.queued
        return "\(JobFormat.number(finished)) of \(JobFormat.number(total)) \(total == 1 ? "email" : "emails")"
    }

    /// "Created", "Paused automatically · On battery", "Resumed · Automatic"...
    public static func eventText(_ event: JobEvent) -> String {
        let p = event.payload
        switch event.kind {
        case .created: return "Created"
        case .started: return "Started"
        case .paused: return join("Paused", p.pauseReason?.displayText.capitalizedFirst)
        case .autoPaused: return join("Paused automatically", p.pauseReason.map { reason in
            reason == .battery ? "On battery" : reason.displayText.capitalizedFirst })
        case .resumed: return join("Resumed", p.trigger.map(triggerText))
        case .stopped: return "Stopped"
        case .completed: return join("Completed", p.count.map { "\(JobFormat.number($0)) \($0 == 1 ? "email" : "emails")" })
        case .completedWithFailures:
            return join("Completed with failures", p.count.map { "\(JobFormat.number($0)) failed" })
        case .failed: return join("Failed", p.errorCategory.map(errorCategoryText))
        case .retryRequested: return join("Retry requested", p.count.map { "\(JobFormat.number($0)) failed \($0 == 1 ? "email" : "emails")" })
        case .recoveredAfterInterruption:
            return join("Recovered after interruption", p.count.map { "\(JobFormat.number($0)) \($0 == 1 ? "email" : "emails") requeued" })
        }
    }

    private static func join(_ head: String, _ detail: String?) -> String {
        detail.map { "\(head) · \($0)" } ?? head
    }

    private static func triggerText(_ t: JobEventTrigger) -> String {
        switch t {
        case .user: return "By you"
        case .automatic: return "Automatic"
        case .launch: return "At launch"
        }
    }

    private static func errorCategoryText(_ code: String) -> String {
        switch code {
        case "provider": return "Model unavailable"
        case "mail": return "Mail unavailable"
        default: return code
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
