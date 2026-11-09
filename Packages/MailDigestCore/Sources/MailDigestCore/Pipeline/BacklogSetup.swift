import Foundation

// Pure logic behind the New Backlog Job window: date presets, default name, time estimate, counts text and
// the volume histogram. No I/O and no clock; every function takes what it needs.

/// The four date presets of step 2.
public enum BacklogRangePreset: String, Sendable, CaseIterable, Identifiable {
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"
    case sinceLastJob = "Since Last Job"
    case custom = "Custom"

    public var id: String { rawValue }
}

/// A resolved date range for a plan: `from` is the start of a day, `to` the end of one (never after `now`).
public struct BacklogDateRange: Sendable, Equatable {
    public var from: Date
    public var to: Date

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }

    /// Resolves a preset. `lastJobEnd` is the end of the newest earlier Backlog job's scope, if any; without
    /// one, "Since Last Job" covers the last 30 days. `custom` bounds are taken in either order.
    public static func resolve(_ preset: BacklogRangePreset, now: Date, calendar: Calendar,
                               lastJobEnd: Date?, customFrom: Date, customTo: Date) -> BacklogDateRange {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }
        func endOfDay(_ d: Date) -> Date {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: d)) ?? d
            return min(next.addingTimeInterval(-1), now)
        }
        switch preset {
        case .last7: return BacklogDateRange(from: daysAgo(6), to: now)
        case .last30: return BacklogDateRange(from: daysAgo(29), to: now)
        case .sinceLastJob:
            let start = lastJobEnd.map { calendar.startOfDay(for: $0) } ?? daysAgo(29)
            return BacklogDateRange(from: min(start, today), to: now)
        case .custom:
            let lo = min(customFrom, customTo), hi = max(customFrom, customTo)
            return BacklogDateRange(from: calendar.startOfDay(for: lo), to: endOfDay(hi))
        }
    }
}

/// The title of a Backlog job, and the date-range wording.
public enum BacklogJobNaming {
    /// The job's date range as a title: "21 Oct 2026" for one day, "1–31 Oct 2026" within a month,
    /// "21 Oct – 4 Nov 2026" across months and "21 Dec 2025 – 4 Jan 2026" across years. Shown whenever the
    /// user has not named the job, and as the Name field's placeholder.
    public static func defaultName(from: Date, to: Date, calendar: Calendar,
                                   locale: Locale = Locale(identifier: "en_AU")) -> String {
        func fmt(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let a = calendar.dateComponents([.year, .month, .day], from: from)
        let b = calendar.dateComponents([.year, .month, .day], from: to)
        if a == b { return fmt("d MMM yyyy", to) }
        // Spaced en dash across months, tight en dash within one month.
        if a.year == b.year, a.month == b.month { return "\(fmt("d", from))\u{2013}\(fmt("d MMM yyyy", to))" }
        if a.year == b.year { return "\(fmt("d MMM", from)) \u{2013} \(fmt("d MMM yyyy", to))" }
        return "\(fmt("d MMM yyyy", from)) \u{2013} \(fmt("d MMM yyyy", to))"
    }

    /// The name to store: nil when the typed text is blank or just the default, so the job keeps showing its
    /// date range; otherwise the trimmed text, which is the user's own name.
    public static func resolvedName(_ typed: String, defaultName: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultName ? nil : trimmed
    }

    /// "1 to 31 Oct 2026", "9 Nov 2026", "20 Sep to 14 Oct 2026" or "20 Dec 2025 to 14 Jan 2026".
    public static func rangeText(from: Date, to: Date, calendar: Calendar,
                                 locale: Locale = Locale(identifier: "en_AU")) -> String {
        func fmt(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let a = calendar.dateComponents([.year, .month, .day], from: from)
        let b = calendar.dateComponents([.year, .month, .day], from: to)
        if a == b { return fmt("d MMM yyyy", to) }
        if a.year == b.year, a.month == b.month { return "\(fmt("d", from)) to \(fmt("d MMM yyyy", to))" }
        if a.year == b.year { return "\(fmt("d MMM", from)) to \(fmt("d MMM yyyy", to))" }
        return "\(fmt("d MMM yyyy", from)) to \(fmt("d MMM yyyy", to))"
    }
}

/// The wizard's time estimate (Q79): the median seconds per email of the last five completed jobs that ran
/// on the local model, or 360 seconds per email when there is no such history.
public enum BacklogEstimate {
    public static let fallbackSecondsPerEmail: Double = 360
    public static let sampleJobCount = 5

    /// The newest completed (finished) jobs first, the ones worth reading items for.
    public static func completedJobs(_ jobs: [Job]) -> [Job] {
        jobs.filter { $0.state == .finished }
            .sorted { ($0.endedAt ?? $0.createdAt) > ($1.endedAt ?? $1.createdAt) }
    }

    /// Seconds per email for one job: the mean time of its finished emails that ran locally (older rows
    /// without a recorded provider were all local). Nil when the job processed no such email.
    public static func secondsPerEmail(of items: [JobItem]) -> Double? {
        let times = items.filter { $0.state == .done && $0.provider != .cloud }.compactMap(\.seconds).filter { $0 > 0 }
        guard !times.isEmpty else { return nil }
        return times.reduce(0, +) / Double(times.count)
    }

    /// Median across job samples (mean of the middle two for an even count); the fallback without samples.
    public static func secondsPerEmail(samples: [Double]) -> Double {
        let sorted = samples.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return fallbackSecondsPerEmail }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Convenience over `completedJobs`, `secondsPerEmail(of:)` and the median, for callers that hold every
    /// job's items already. A job with no processed emails is not a sample, so the next older job fills in.
    public static func secondsPerEmail(jobs: [Job], items: [UUID: [JobItem]]) -> Double {
        var samples: [Double] = []
        for job in completedJobs(jobs) where samples.count < sampleJobCount {
            if let s = secondsPerEmail(of: items[job.id] ?? []) { samples.append(s) }
        }
        return secondsPerEmail(samples: samples)
    }

    /// "About 40 minutes", "About 6 hours", "About 36 hours", "About 3 days".
    public static func friendlyDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "Under a minute" }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 {
            // Round to five minutes once the exact number stops mattering.
            let m = minutes < 10 ? minutes : Int((Double(minutes) / 5).rounded()) * 5
            if m >= 60 { return "About an hour" }
            return m == 1 ? "About a minute" : "About \(m) minutes"
        }
        let hours = Int((s / 3600).rounded())
        if hours < 2 { return "About an hour" }
        if hours < 72 { return "About \(hours) hours" }
        let days = Int((Double(hours) / 24).rounded())
        return "About \(days) days"
    }

    /// How many overnight windows the job needs (at least one). A window with equal start and end is
    /// unrestricted, so it counts as a full day.
    public static func nights(seconds: TimeInterval, window: QuietHours) -> Int {
        let span = (window.endMinute - window.startMinute + 1440) % 1440
        let windowSeconds = Double(span == 0 ? 1440 : span) * 60
        return max(1, Int((max(0, seconds) / windowSeconds).rounded(.up)))
    }

    /// "10 pm" or "6:30 am": 12-hour, lowercase, minutes only when needed.
    public static func clockText(minute: Int) -> String {
        let h = (minute / 60) % 24, m = minute % 60
        let hour = h % 12 == 0 ? 12 : h % 12
        return (m == 0 ? "\(hour)" : "\(hour):" + (m < 10 ? "0\(m)" : "\(m)")) + (h < 12 ? " am" : " pm")
    }

    /// The "Overnight While Plugged In" description, from the configured window and the estimate.
    public static func overnightDescription(window: QuietHours, estimatedSeconds: TimeInterval) -> String {
        guard window.startMinute != window.endMinute else {
            return "Runs whenever your Mac is plugged in. Your Mac stays quick on battery."
        }
        let n = nights(seconds: estimatedSeconds, window: window)
        let length = n == 1 ? "done in one night" : "about \(n) nights"
        return "Runs \(clockText(minute: window.startMinute)) to \(clockText(minute: window.endMinute)), "
            + "\(length). Your Mac stays quick during the day."
    }
}

/// Wording for counts in the wizard footer and summary.
public enum BacklogSetupText {
    /// "2 mailboxes · 3,630 emails".
    public static func mailboxFooter(mailboxCount: Int, emailCount: Int) -> String {
        guard mailboxCount > 0 else { return "No mailboxes selected" }
        return "\(mailboxCount) \(mailboxCount == 1 ? "mailbox" : "mailboxes") · "
            + "\(JobFormat.number(emailCount)) \(emailCount == 1 ? "email" : "emails")"
    }

    /// Batches of 50 (Q47) needed for `emails` emails.
    public static func batchCount(_ emails: Int, size: Int = BacklogBatching.defaultSize) -> Int {
        emails <= 0 ? 0 : (emails + size - 1) / size
    }

    /// "374 emails to read · 8 batches", plus " · 12 held back" when the run limit defers some (Q26).
    public static func readFooter(toProcess: Int, deferredByLimit: Int = 0) -> String {
        guard toProcess > 0 else { return "Nothing to read in this range" }
        let batches = batchCount(toProcess)
        var text = "\(JobFormat.number(toProcess)) \(toProcess == 1 ? "email" : "emails") to read · "
            + "\(batches) \(batches == 1 ? "batch" : "batches")"
        if deferredByLimit > 0 { text += " · \(JobFormat.number(deferredByLimit)) held back" }
        return text
    }

    /// "374 to read · 38 already processed", plus the deferred count when there is one.
    public static func emailsRow(toProcess: Int, alreadyProcessed: Int, deferredByLimit: Int = 0) -> String {
        var text = "\(JobFormat.number(toProcess)) to read · \(JobFormat.number(alreadyProcessed)) already processed"
        if deferredByLimit > 0 { text += " · \(JobFormat.number(deferredByLimit)) held back by the run limit" }
        return text
    }

    /// "About 36 hours · 8 batches of 50".
    public static func estimateRow(seconds: TimeInterval, toProcess: Int) -> String {
        let batches = batchCount(toProcess)
        guard batches > 0 else { return "Nothing to estimate" }
        return "\(BacklogEstimate.friendlyDuration(seconds)) · \(batches) \(batches == 1 ? "batch" : "batches") of \(BacklogBatching.defaultSize)"
    }

    /// "iCloud Inbox, Outlook Inbox".
    public static func mailboxList(_ refs: [MailboxRef]) -> String {
        var seen = Set<MailboxRef>()
        return refs.filter { seen.insert($0).inserted }
            .map { "\($0.account) \(JobSummaryText.displayName(of: $0))" }.joined(separator: ", ")
    }
}

// MARK: Volume histogram

/// Emails received on one calendar day in the chosen mailboxes.
public struct DayCount: Sendable, Equatable {
    public var day: DigestDay
    public var count: Int

    public init(day: DigestDay, count: Int) {
        self.day = day
        self.count = count
    }
}

/// Counts messages per day from the mail store without reading any message content. Returns nil when the
/// fast store is unavailable (no Full Disk Access), so the caller shows no chart instead of querying Mail
/// message by message.
public protocol MailVolumeSource: Sendable {
    func dailyCounts(in mailboxes: [MailboxRef], from: Date, to: Date) async throws -> [DayCount]?
}

/// One bar of the volume chart.
public struct VolumeBin: Sendable, Equatable, Identifiable {
    public var date: Date
    public var count: Int
    public var isInRange: Bool
    public var id: Date { date }
}

public enum VolumeHistogram {
    /// Two weeks before the range starts, up to today.
    public static let leadDays = 14

    /// The span to query and chart.
    public static func window(range: BacklogDateRange, now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let start = calendar.startOfDay(for: range.from)
        let from = calendar.date(byAdding: .day, value: -leadDays, to: start) ?? start
        // The query end is exclusive.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return (from, tomorrow)
    }

    /// One bin per day of the window, zero-filled, flagged when the day lies inside `range`.
    public static func bins(_ counts: [DayCount], range: BacklogDateRange, now: Date, calendar: Calendar) -> [VolumeBin] {
        let w = window(range: range, now: now, calendar: calendar)
        let byDay = Dictionary(counts.map { ($0.day, $0.count) }, uniquingKeysWith: +)
        let first = calendar.startOfDay(for: range.from)
        let last = calendar.startOfDay(for: range.to)
        var bins: [VolumeBin] = []
        var day = w.from
        while day < w.to, bins.count < 4_000 {
            let key = DigestDay(day, calendar: calendar)
            bins.append(VolumeBin(date: day, count: byDay[key] ?? 0, isInRange: day >= first && day <= last))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return bins
    }

    /// "412 emails" in range.
    public static func total(_ bins: [VolumeBin]) -> Int { bins.filter(\.isInRange).reduce(0) { $0 + $1.count } }

    /// VoiceOver summary of the chart.
    public static func accessibilitySummary(_ bins: [VolumeBin], calendar: Calendar,
                                            locale: Locale = Locale(identifier: "en_AU")) -> String {
        guard !bins.isEmpty else { return "No volume data" }
        let inRange = bins.filter(\.isInRange)
        let busiest = inRange.max { $0.count < $1.count }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMMM"
        var text = "Emails per day, \(f.string(from: bins[0].date)) to \(f.string(from: bins[bins.count - 1].date)). "
            + "\(JobFormat.number(total(bins))) emails in the chosen range"
        if let busiest, busiest.count > 0 {
            text += ", busiest day \(f.string(from: busiest.date)) with \(JobFormat.number(busiest.count))"
        }
        return text + "."
    }
}

// MARK: Confirming a preview

extension JobPreviewBuilder {
    /// The preview as Start will queue it (Q26): the same plan, minus the `excluded` ids and, when
    /// `skipIgnoredSenders` is on, mail from addresses on the Ignored list. The exact remaining ids become
    /// `confirmedMessageIDs`, and the time estimate is recomputed for the new count.
    public func confirmed(_ preview: JobPreview, excluded: Set<String>, skipIgnoredSenders: Bool,
                          secondsPerEmail: Double) -> JobPreview {
        var p = preview
        var removed = excluded
        if skipIgnoredSenders {
            for h in p.toProcess where filter.ignoredSenders.contains(MailFilter.address(from: h.sender)) {
                removed.insert(h.id)
            }
        }
        p.toProcess.removeAll { removed.contains($0.id) }
        p.plan.excludedMessageIDs = removed
        p.plan.confirmedMessageIDs = Set(p.toProcess.map(\.id))
        p.firstItems = Array(p.toProcess.prefix(listLimit))
        p.estimatedSeconds = secondsPerEmail * Double(p.toProcess.count)
        return p
    }
}
