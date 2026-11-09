import Foundation

/// One cell of the sidebar's mini month calendar.
public struct MonthGridCell: Sendable, Equatable {
    public var day: DigestDay
    /// False for the leading and trailing days that belong to the neighbouring months.
    public var isInMonth: Bool
}

/// Pure logic for the sidebar's mini calendar. Everything is injected, so it is tested without a clock.
public enum MonthGrid {
    /// Always six weeks of seven days, Monday first, so the calendar keeps its height between months. Leading
    /// and trailing days from the neighbouring months fill the first and last rows.
    public static func weeks(for month: DigestMonth, calendar: Calendar) -> [[MonthGridCell]] {
        guard let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))
        else { return [] }
        // Gregorian weekday: 1 = Sunday ... 7 = Saturday. Monday-first offset: Monday 0 ... Sunday 6.
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: first) else { return [] }
        let cells: [MonthGridCell] = (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let day = DigestDay(date, calendar: calendar)
            return MonthGridCell(day: day, isInMonth: DigestMonth(day) == month)
        }
        guard cells.count == 42 else { return [] }
        return stride(from: 0, to: 42, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// The month `offset` months from `month`.
    public static func month(_ month: DigestMonth, adding offset: Int) -> DigestMonth {
        let index = month.year * 12 + (month.month - 1) + offset
        return DigestMonth(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1)
    }

    /// VoiceOver label of a day button: "Sunday 8 November, digest with 2 unreviewed". A day without a digest
    /// is just its date; today says so.
    public static func accessibilityLabel(for day: DigestDay, entry: CalendarDigestEntry?, isToday: Bool,
                                          calendar: Calendar, locale: Locale = .current) -> String {
        var parts = [dateText(day, calendar: calendar, locale: locale)]
        if isToday { parts.append("today") }
        if let entry {
            parts.append(entry.unreviewed == 0 ? "digest, all reviewed" : "digest with \(entry.unreviewed) unreviewed")
        }
        return parts.joined(separator: ", ")
    }

    private static func dateText(_ day: DigestDay, calendar: Calendar, locale: Locale) -> String {
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
        else { return "" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: date)
    }
}

/// The idle line at the foot of the sidebar.
public enum NextDigestText {
    /// "Next digest tomorrow at 6:30 am". It says "today at" while today's run time is still ahead and
    /// "tomorrow at" otherwise. The time is written 12-hour with lowercase am/pm whatever the locale.
    public static func text(now: Date, hour: Int, minute: Int, timeZone: TimeZone) -> String {
        let runTime = MorningSchedule.runTime(on: now, hour: hour, minute: minute, timeZone: timeZone)
        let h = min(max(hour, 0), 23), m = min(max(minute, 0), 59)
        let clock = "\(h % 12 == 0 ? 12 : h % 12):" + (m < 10 ? "0\(m)" : "\(m)") + (h < 12 ? " am" : " pm")
        return "Next digest \(now < runTime ? "today" : "tomorrow") at \(clock)"
    }
}

/// Which context-menu actions a Backlog job in the sidebar allows.
public struct BacklogJobActions: Sendable, Equatable {
    public var canPause: Bool
    public var canResume: Bool
    public var canStop: Bool
    public var canRename: Bool
    public var canDelete: Bool

    /// - Parameters:
    ///   - state: the job's state; for the job the runner holds, its live state.
    ///   - isLoaded: whether the runner holds this job (a running job, or the paused one in the progress strip).
    ///   - anotherJobRuns: whether a different job occupies the runner, which blocks a resume.
    public init(state: JobState, isLoaded: Bool, anotherJobRuns: Bool) {
        // Pause and Stop act on the job the runner holds. A stopped job stays distinct from a paused one and
        // only an explicit Resume continues it (Q48, Q78).
        canPause = isLoaded && state == .running
        canStop = isLoaded && (state == .running || state == .paused)
        canResume = (state == .paused || state == .stopped) && !anotherJobRuns && !(isLoaded && state != .paused)
        canRename = true
        // A running job is never deletable; neither is a paused one the runner still holds.
        switch state {
        case .listing, .running, .pausing, .stopping: canDelete = false
        case .paused: canDelete = !isLoaded
        case .idle, .stopped, .finished, .failed: canDelete = true
        }
    }
}

/// Text for a Backlog job's sidebar row.
public enum BacklogRowText {
    /// "iCloud, Outlook": the distinct account names, in order.
    public static func accounts(of job: Job) -> String {
        var seen = Set<String>()
        return job.mailboxes.map(\.account).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// Whole-percent progress from stored totals; nil when the job has no emails.
    public static func percent(_ totals: JobTotals) -> Int? {
        let total = totals.queued + totals.done + totals.failed + totals.skipped
        guard total > 0 else { return nil }
        return Int((Double(total - totals.queued) / Double(total) * 100).rounded(.down))
    }

    /// "iCloud, Outlook · 52%". Falls back to the accounts alone when the percentage is unknown.
    public static func runningSubtitle(accounts: String, percent: Int?) -> String {
        guard let percent else { return accounts }
        return accounts.isEmpty ? "\(percent)%" : "\(accounts) · \(percent)%"
    }
}
