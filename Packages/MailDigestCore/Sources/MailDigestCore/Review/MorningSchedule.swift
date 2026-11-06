import Foundation

/// Decides whether the scheduled morning run is due. Pure, so it is tested without a scheduler.
public enum MorningSchedule {
    /// The same default zone as `RunnerSettings`.
    public static var defaultTimeZone: TimeZone { RunnerSettings().timeZone }

    /// Today's run time in `timeZone`. Falls forward through a DST gap and never returns nil for valid input.
    public static func runTime(on now: Date, hour: Int, minute: Int, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: now)
        let clampedHour = min(max(hour, 0), 23), clampedMinute = min(max(minute, 0), 59)
        return calendar.date(bySettingHour: clampedHour, minute: clampedMinute, second: 0, of: startOfDay,
                             matchingPolicy: .nextTime)
            ?? startOfDay.addingTimeInterval(TimeInterval(clampedHour * 3600 + clampedMinute * 60))
    }

    /// True when `now` is past today's run time and no Daily job created since then is still useful.
    /// An empty Daily job writes no digest (Q24), so the rule looks at jobs, not digests. A `.failed` job
    /// (provider outage, Q25) does not count as having run, so the next check retries. Paused, stopped or
    /// running jobs count as run: the user or the runner already owns them. Use `decision` to also respect
    /// an unresolved Daily job from an earlier day (Q52).
    public static func isDue(now: Date, hour: Int, minute: Int, jobs: [Job],
                             timeZone: TimeZone = defaultTimeZone) -> Bool {
        let due = runTime(on: now, hour: hour, minute: minute, timeZone: timeZone)
        guard now >= due else { return false }
        let ranToday = jobs.contains { $0.kind == .daily && $0.createdAt >= due && $0.state != .failed }
        return !ranToday
    }

    /// What a scheduler check should do (Q52). A due run waits while any Daily job is unresolved: the
    /// scheduler neither creates a second Daily job nor resumes the old one. Nothing is recorded for a
    /// deferred check, so the next check after the job is resolved finds the run due again.
    public static func decision(now: Date, hour: Int, minute: Int, jobs: [Job], live: JobProgress? = nil,
                                timeZone: TimeZone = defaultTimeZone) -> ScheduledDailyDecision {
        guard isDue(now: now, hour: hour, minute: minute, jobs: jobs, timeZone: timeZone) else { return .notDue }
        let lifecycle = DailyLifecycle(jobs: jobs, live: live)
        return lifecycle == .none ? .start : .deferred(lifecycle)
    }
}

/// The outcome of one scheduler check.
public enum ScheduledDailyDecision: Equatable, Sendable {
    case notDue
    /// Create today's Daily job.
    case start
    /// The run is due but waits for this unresolved Daily job (Q52).
    case deferred(DailyLifecycle)
}
