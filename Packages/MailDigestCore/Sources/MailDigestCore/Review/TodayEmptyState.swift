import Foundation

/// The text of Today's empty state while today's digest does not exist yet. Pure: the time and every fact
/// it words come in as arguments, so it never reads the clock.
public struct TodayEmptyState: Equatable, Sendable {
    /// What the app knows went wrong with today's Daily run. Nil means it knows nothing.
    public enum Problem: Equatable, Sendable {
        /// A Daily job is listing or running; the digest appears as it finishes.
        case running
        /// The Daily job failed; `reason` is its stored error.
        case failed(reason: String?)
        /// The Daily job is paused, with the recorded reason when there is one.
        case paused(PauseReason?)
        /// The Daily job was stopped before it finished.
        case stopped
        /// Several unfinished Daily jobs wait for a decision in Activity.
        case unfinished
        /// The run could not start (for example Ollama was unreachable); `reason` is the message shown.
        case startFailed(reason: String?)
    }

    public var title: String
    public var description: String

    /// - Parameters:
    ///   - now: the current time.
    ///   - runHour, runMinute: the configured daily run time.
    ///   - timeZone: the zone the run time is read in.
    ///   - hasEverRun: whether any digest has ever been created.
    ///   - problem: what the app knows about a missed or failed run; any known problem outranks the
    ///     first-launch and before-schedule wording.
    public init(now: Date, runHour: Int, runMinute: Int, timeZone: TimeZone, hasEverRun: Bool, problem: Problem?) {
        let h = min(max(runHour, 0), 23), m = min(max(runMinute, 0), 59)
        let time = Self.clockText(hour: h, minute: m)
        let scheduled = MorningSchedule.runTime(on: now, hour: h, minute: m, timeZone: timeZone)
        // Order: running, then any known problem (whatever the time or history), then the no-problem variants.
        if problem == .running {
            title = "Today's Digest Is Running"
            description = "It will appear here as soon as it finishes."
        } else if let problem {
            title = "Today's Digest Didn't Run"
            description = Self.reason(problem, time: time)
        } else if !hasEverRun {
            // The very first launch: nothing has run, so there is nothing to explain yet.
            title = "No Digest Yet"
            description = "Your first digest runs at \(time)."
        } else if now < scheduled {
            title = "Not Ready Yet"
            description = "Today's digest runs at \(time). You can run it now instead."
        } else {
            // Exactly at the scheduled time counts as after.
            title = "Today's Digest Didn't Run"
            description = Self.reason(problem, time: time)
        }
    }

    /// The reason in plain words. With nothing known, it says only what could be true and names no cause as fact.
    private static func reason(_ problem: Problem?, time: String) -> String {
        switch problem {
        case .failed(let reason?) where !reason.trimmingCharacters(in: .whitespaces).isEmpty:
            return "The digest stopped before it finished. " + sentence(reason)
        case .failed:
            return "The digest stopped before it finished."
        case .paused(let reason?):
            return "The digest is paused (\(reason.displayText))."
        case .paused(nil):
            return "The digest is paused."
        case .stopped:
            return "The digest was stopped before it finished."
        case .unfinished:
            return "More than one unfinished digest is waiting for a decision in Activity."
        case .startFailed(let reason?) where !reason.trimmingCharacters(in: .whitespaces).isEmpty:
            return "Mail Digest couldn't start the digest. " + sentence(reason)
        case .startFailed:
            return "Mail Digest couldn't start the digest."
        case .running, nil:
            return "Your Mac may have been asleep or Mail Digest wasn't open at \(time)."
        }
    }

    /// `text` trimmed and ended with a full stop unless it already ends in punctuation.
    private static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?…".contains(last) ? t : t + "."
    }

    /// "6:30 am" or "12:00 pm": 12-hour with lowercase am/pm.
    public static func clockText(hour: Int, minute: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h):" + (minute < 10 ? "0\(minute)" : "\(minute)") + (hour < 12 ? " am" : " pm")
    }

    /// The next moment after `now` when Today's greeting or this empty state can change: the next top of the
    /// hour (every greeting boundary) or the scheduled run time, whichever comes first.
    public static func nextChange(after now: Date, runHour: Int, runMinute: Int,
                                  calendar: Calendar, runTimeZone: TimeZone) -> Date {
        let hourly = calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0),
                                       matchingPolicy: .nextTime) ?? now.addingTimeInterval(3_600)
        let tomorrow = now.addingTimeInterval(86_400)
        let runs = [now, tomorrow].map {
            MorningSchedule.runTime(on: $0, hour: runHour, minute: runMinute, timeZone: runTimeZone)
        }
        return ([hourly] + runs.filter { $0 > now }).min() ?? hourly
    }
}
