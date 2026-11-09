import Foundation

/// A calendar day in the settings time zone; the unit Recent Digests groups by.
public struct DigestDay: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    public static func < (a: DigestDay, b: DigestDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// A calendar month, the section header of Recent Digests.
public struct DigestMonth: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ day: DigestDay) { self.init(year: day.year, month: day.month) }

    public static func < (a: DigestMonth, b: DigestMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// One Recent Digests row: every Daily run of one calendar day, merged.
public struct ArchiveDay: Sendable, Equatable, Identifiable {
    public var day: DigestDay
    /// The day's Daily digests in creation order.
    public var digestIDs: [UUID]
    /// Summed email counts of those digests.
    public var emailCount: Int
    /// Pending plus failed suggestions, the sidebar badge.
    public var actionableCount: Int
    public var id: DigestDay { day }
}

/// A month section of Recent Digests; `days` are newest first.
public struct ArchiveMonth: Sendable, Equatable, Identifiable {
    public var month: DigestMonth
    public var days: [ArchiveDay]
    public var id: DigestMonth { month }
}

/// One Backlog entry in the sidebar.
public struct ArchiveBacklog: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var emailCount: Int
    /// Pending plus failed suggestions.
    public var actionableCount: Int
    /// False for a job that has not stored a digest yet, for example one waiting for the overnight window.
    public var hasDigest: Bool = true
}

/// The sidebar's view of every digest (Q54 to Q56), built purely from summaries, a `now` and a calendar
/// (whose time zone is the settings time zone) so day boundaries are testable.
public struct DigestArchive: Sendable, Equatable {
    /// Daily digests created today, in creation order.
    public let todayDigestIDs: [UUID]
    /// Start of today; Daily digests created before it are carried over into Today.
    public let startOfToday: Date
    /// Today's actionable badge: today's Daily digests plus unreviewed Daily digests from earlier days.
    public let todayCount: Int
    /// Actionable suggestions in Daily digests created before today (the whole carry-over).
    public let carryOverCount: Int
    /// Review Queue and menu bar badge: pending plus failed suggestions in every digest, Backlog included.
    public let reviewQueueCount: Int
    /// Days before today that have a Daily digest, grouped by month; newest first.
    public let months: [ArchiveMonth]
    /// Backlog digests, newest first.
    public let backlogs: [ArchiveBacklog]
    /// The newest Daily digest of any day, for the menu panel's last-run row; never a Backlog digest.
    public let latestDaily: DigestSummary?

    private let digestsByDay: [DigestDay: [UUID]]
    private let today: DigestDay

    /// - Parameter backlogJobs: Backlog jobs from the store. A job that has no digest yet (nothing finished,
    ///   or not started) is still listed, so a new job shows in the sidebar at once.
    public init(summaries: [DigestSummary], backlogJobs: [Job] = [], now: Date, calendar: Calendar) {
        let today = DigestDay(now, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        self.today = today
        startOfToday = start

        let dailies = summaries.filter { $0.kind == .daily }.sorted { $0.createdAt < $1.createdAt }
        func actionable(_ s: DigestSummary) -> Int { s.pendingCount + s.failedCount }

        latestDaily = dailies.last
        todayDigestIDs = dailies.filter { DigestDay($0.createdAt, calendar: calendar) == today }.map(\.id)
        todayCount = dailies
            .filter { $0.createdAt < start || DigestDay($0.createdAt, calendar: calendar) == today }
            .reduce(0) { $0 + actionable($1) }
        carryOverCount = dailies.filter { $0.createdAt < start }.reduce(0) { $0 + actionable($1) }
        reviewQueueCount = summaries.reduce(0) { $0 + actionable($1) }

        var byDay: [DigestDay: [DigestSummary]] = [:]
        for s in dailies {
            let d = DigestDay(s.createdAt, calendar: calendar)
            if d < today { byDay[d, default: []].append(s) }
        }
        digestsByDay = byDay.mapValues { $0.map(\.id) }
        let days = byDay.map { day, list in
            ArchiveDay(day: day, digestIDs: list.map(\.id), emailCount: list.reduce(0) { $0 + $1.emailCount },
                       actionableCount: list.reduce(0) { $0 + actionable($1) })
        }
        months = Dictionary(grouping: days) { DigestMonth($0.day) }
            .map { ArchiveMonth(month: $0.key, days: $0.value.sorted { $0.day > $1.day }) }
            .sorted { $0.month > $1.month }

        let digestBacklogs = summaries.filter { $0.kind == .backlog }.sorted { $0.createdAt > $1.createdAt }
            .map { ArchiveBacklog(id: $0.id, createdAt: $0.createdAt, emailCount: $0.emailCount, actionableCount: actionable($0)) }
        let withDigest = Set(summaries.map(\.id))
        // A job that finished without a digest, or failed before queuing anything, has nothing to show.
        let digestless = backlogJobs.filter { job in
            job.kind == .backlog && !withDigest.contains(job.id) && job.state != .finished
                && (job.state != .failed || job.totals.queued + job.totals.done + job.totals.failed + job.totals.skipped > 0)
        }.map { ArchiveBacklog(id: $0.id, createdAt: $0.createdAt, emailCount: 0, actionableCount: 0, hasDigest: false) }
        backlogs = (digestBacklogs + digestless).sorted { $0.createdAt > $1.createdAt }
    }

    /// The Daily digests of an earlier day, in creation order; empty for today or a day without a digest.
    public func digestIDs(for day: DigestDay) -> [UUID] {
        day < today ? digestsByDay[day] ?? [] : []
    }

    /// What the sidebar calendar shows for `day`: today (when Today has digests) or an earlier day with a
    /// digest; nil for any other day.
    public func calendarEntry(for day: DigestDay) -> CalendarDigestEntry? {
        if day == today {
            return todayDigestIDs.isEmpty ? nil : CalendarDigestEntry(unreviewed: todayCount)
        }
        guard day < today, let ids = digestsByDay[day], !ids.isEmpty else { return nil }
        let unreviewed = months.first { $0.month == DigestMonth(day) }?.days.first { $0.day == day }?.actionableCount ?? 0
        return CalendarDigestEntry(unreviewed: unreviewed)
    }

    /// Months the calendar can show: from the oldest month with a digest (or this month) to this month.
    public var calendarMonthRange: ClosedRange<DigestMonth> {
        let latest = DigestMonth(today)
        let earliest = months.map(\.month).min().map { min($0, latest) } ?? latest
        return earliest...latest
    }

    /// The calendar day that is today.
    public var todayDay: DigestDay { today }

    /// Whether this digest belongs to Today's Daily digests.
    public func isToday(digestID: UUID) -> Bool { todayDigestIDs.contains(digestID) }

    /// The earlier day whose Daily digests include this digest, or nil for today, a Backlog or an unknown id.
    public func day(ofDigest id: UUID) -> DigestDay? {
        digestsByDay.first { $0.value.contains(id) }?.key
    }

    /// Whether `item` still points at something the sidebar lists, so a stale selection can fall back to Today.
    public func hasBacklog(_ id: UUID) -> Bool { backlogs.contains { $0.id == id } }
}

/// A digest on a calendar day, with how many of its suggestions still need a decision.
public struct CalendarDigestEntry: Sendable, Equatable {
    public var unreviewed: Int

    public init(unreviewed: Int) { self.unreviewed = unreviewed }
}
