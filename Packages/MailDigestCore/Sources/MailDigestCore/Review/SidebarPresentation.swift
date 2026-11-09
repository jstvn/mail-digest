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
        "Next digest " + when(now: now, hour: hour, minute: minute, timeZone: timeZone)
    }

    /// "tomorrow at 6:30 am": the part of `text` after "Next digest", for sentences such as the empty Today state.
    public static func when(now: Date, hour: Int, minute: Int, timeZone: TimeZone) -> String {
        let runTime = MorningSchedule.runTime(on: now, hour: hour, minute: minute, timeZone: timeZone)
        let h = min(max(hour, 0), 23), m = min(max(minute, 0), 59)
        let clock = "\(h % 12 == 0 ? 12 : h % 12):" + (m < 10 ? "0\(m)" : "\(m)") + (h < 12 ? " am" : " pm")
        return "\(now < runTime ? "today" : "tomorrow") at \(clock)"
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
    /// Whole-percent progress from stored totals; nil when the job has no emails.
    public static func percent(_ totals: JobTotals) -> Int? {
        let total = totals.queued + totals.done + totals.failed + totals.skipped
        guard total > 0 else { return nil }
        return Int((Double(total - totals.queued) / Double(total) * 100).rounded(.down))
    }

    /// True while an overnight-only job waits for its window (paused, "outside the run window"). A job the user
    /// paused or stopped is not scheduled, and neither is one waiting on battery, Low Power Mode or heat.
    public static func isScheduled(_ job: Job) -> Bool {
        job.overnightOnly && job.state == .paused && job.pauseReason == .quietHours
    }

    // MARK: Two-line sidebar row

    /// Line 1: the name the user typed, or the job's date range ("1–31 Oct 2026"). A job that reads
    /// everything up to a date (scope starting before 1990) says so.
    public static func title(_ job: Job, calendar: Calendar, locale: Locale = Locale(identifier: "en_AU")) -> String {
        if let name = job.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if job.scopeFrom.timeIntervalSince1970 < 631_152_000 {
            return JobSummaryText.scope(job, timeZone: calendar.timeZone, locale: locale)
        }
        return BacklogJobNaming.defaultName(from: job.scopeFrom, to: job.scopeTo, calendar: calendar, locale: locale)
    }

    /// "iCloud, Outlook Archive": distinct account names for Inbox mailboxes, and "Account Folder" for any
    /// other folder, so an Inbox is never spelled out.
    public static func locations(of job: Job) -> String {
        var seen = Set<String>()
        return job.mailboxes
            .map { JobSummaryText.displayName(of: $0) == "Inbox" ? $0.account : "\($0.account) \(JobSummaryText.displayName(of: $0))" }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// Line 2: the locations, then the status: "iCloud, Outlook · 52%", "… · Waiting for 10 pm",
    /// "… · Paused", "… · Stopped", "… · Done".
    /// - Parameters:
    ///   - state: the job's effective state (the runner's live one when it holds the job).
    ///   - percent: whole-percent progress, shown while the job runs.
    ///   - startMinute: when the overnight window opens (`quietHoursStartMinute`), for a waiting job.
    public static func subtitle(_ job: Job, state: JobState, percent: Int?, startMinute: Int) -> String {
        let status: String?
        switch state {
        case .listing, .running, .pausing:
            status = percent.map { "\($0)%" } ?? "Starting…"
        case .paused:
            status = isScheduled(job) ? "Waiting for \(BacklogEstimate.clockText(minute: startMinute))" : "Paused"
        case .stopped, .stopping: status = "Stopped"
        case .finished: status = "Done"
        case .failed: status = "Failed"
        case .idle: status = "Not started"
        }
        let places = locations(of: job)
        guard let status else { return places }
        return places.isEmpty ? status : "\(places) · \(status)"
    }
}
