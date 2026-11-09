import Foundation

/// Pure rules for jobs created as "Overnight While Plugged In" (a deliberate exception to Q44 for these jobs).
public enum OvernightPolicy {
    /// True when `job` may be started by the resource rules once nothing blocks it.
    ///
    /// An overnight-only Backlog job waiting for a resource reason (battery, Low Power Mode, heat, outside
    /// the window) is always a candidate, including after a relaunch or a runner rebuild. Any other job only
    /// when this runner session auto-paused it (Q44). A job the user paused (no reason), a stopped job and a
    /// job waiting for a Daily job (`.dailyJob`, which has its own hand-off) are never candidates here.
    public static func isAutoResumeCandidate(_ job: Job, autoPausedThisSession: Bool) -> Bool {
        guard job.state == .paused, let reason = job.pauseReason else { return false }
        if job.kind == .backlog && job.overnightOnly { return reason != .dailyJob }
        return autoPausedThisSession
    }

    /// True while the Mac must be kept from idle sleep: an overnight-only job is actually working and the
    /// Mac is on mains power. Idle system sleep only; the display may still sleep.
    public static func shouldPreventIdleSleep(state: JobState, overnightOnly: Bool, onBattery: Bool) -> Bool {
        guard overnightOnly, !onBattery else { return false }
        return state == .listing || state == .running
    }
}
