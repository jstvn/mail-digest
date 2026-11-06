import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = brisbane
    return c
}

/// A Brisbane wall-clock date.
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func summary(_ kind: JobKind, _ date: Date, emails: Int = 1, pending: Int = 0, failed: Int = 0) -> DigestSummary {
    DigestSummary(id: UUID(), createdAt: date, kind: kind, emailCount: emails, pendingCount: pending, failedCount: failed)
}

@Suite struct DigestArchiveTests {
    @Test func dayBucketingUsesTheSettingsTimeZoneAroundMidnight() {
        // 23:59 and 00:01 Brisbane are the same instant range as 13:59 and 14:01 UTC on the earlier date.
        let late = at(2026, 3, 10, 23, 59), early = at(2026, 3, 11, 0, 1)
        #expect(DigestDay(late, calendar: cal) == DigestDay(year: 2026, month: 3, day: 10))
        #expect(DigestDay(early, calendar: cal) == DigestDay(year: 2026, month: 3, day: 11))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(DigestDay(early, calendar: utc) == DigestDay(year: 2026, month: 3, day: 10))
    }

    @Test func monthBoundaryGroupsAndOrdersNewestFirst() {
        let a = summary(.daily, at(2026, 2, 28, 23, 30)), b = summary(.daily, at(2026, 3, 1, 0, 30))
        let c = summary(.daily, at(2026, 3, 2))
        let archive = DigestArchive(summaries: [a, b, c], now: at(2026, 3, 5), calendar: cal)
        #expect(archive.months.map(\.month) == [DigestMonth(year: 2026, month: 3), DigestMonth(year: 2026, month: 2)])
        #expect(archive.months[0].days.map(\.day.day) == [2, 1])
        #expect(archive.months[1].days.map(\.day.day) == [28])
        #expect(archive.digestIDs(for: DigestDay(year: 2026, month: 3, day: 1)) == [b.id])
    }

    @Test func severalRunsOnOneDayMerge() {
        let first = summary(.daily, at(2026, 3, 3, 8), emails: 4, pending: 2)
        let second = summary(.daily, at(2026, 3, 3, 18), emails: 6, pending: 1, failed: 1)
        let archive = DigestArchive(summaries: [second, first], now: at(2026, 3, 5), calendar: cal)
        let day = archive.months[0].days[0]
        #expect(archive.months[0].days.count == 1)
        #expect(day.digestIDs == [first.id, second.id])
        #expect(day.emailCount == 10 && day.actionableCount == 4)
    }

    @Test func todayIsExcludedFromRecentAndListedSeparately() {
        let today1 = summary(.daily, at(2026, 3, 5, 6)), today2 = summary(.daily, at(2026, 3, 5, 9))
        let old = summary(.daily, at(2026, 3, 4, 20))
        let archive = DigestArchive(summaries: [today2, old, today1], now: at(2026, 3, 5, 10), calendar: cal)
        #expect(archive.todayDigestIDs == [today1.id, today2.id])
        #expect(archive.months.flatMap(\.days).map(\.day.day) == [4])
        #expect(archive.digestIDs(for: DigestDay(year: 2026, month: 3, day: 5)).isEmpty)
        #expect(archive.startOfToday == at(2026, 3, 5, 0))
    }

    @Test func carryOverCutoffIsStartOfToday() {
        let justBefore = summary(.daily, at(2026, 3, 4, 23, 59), pending: 2)
        let justAfter = summary(.daily, at(2026, 3, 5, 0, 1), pending: 3)
        let archive = DigestArchive(summaries: [justBefore, justAfter], now: at(2026, 3, 5, 8), calendar: cal)
        #expect(archive.todayCount == 5)
        #expect(archive.todayDigestIDs == [justAfter.id])
    }

    @Test func backlogIsOutsideTodayButInTheReviewQueue() {
        let daily = summary(.daily, at(2026, 3, 4), pending: 1, failed: 1)
        let todayDaily = summary(.daily, at(2026, 3, 5, 7), pending: 2)
        let oldBacklog = summary(.backlog, at(2026, 3, 1), emails: 30, pending: 5, failed: 1)
        let newBacklog = summary(.backlog, at(2026, 3, 2), emails: 20, pending: 4)
        let archive = DigestArchive(summaries: [daily, oldBacklog, todayDaily, newBacklog], now: at(2026, 3, 5, 8), calendar: cal)
        #expect(archive.todayCount == 4)
        #expect(archive.reviewQueueCount == 14)
        #expect(archive.carryOverCount == 2)
        // Menu bar and Review Queue share one count, failed suggestions included.
        #expect(archive.reviewQueueCount == 14)
        #expect(archive.backlogs.map(\.id) == [newBacklog.id, oldBacklog.id])
        #expect(archive.backlogs.map(\.actionableCount) == [4, 6] && archive.backlogs.map(\.emailCount) == [20, 30])
        #expect(!archive.months.flatMap(\.days).flatMap(\.digestIDs).contains(oldBacklog.id))
    }

    @Test func locatesADigestsSidebarEntry() {
        let today = summary(.daily, at(2026, 3, 5, 6)), earlier = summary(.daily, at(2026, 3, 2))
        let backlog = summary(.backlog, at(2026, 3, 1))
        let archive = DigestArchive(summaries: [today, earlier, backlog], now: at(2026, 3, 5), calendar: cal)
        #expect(archive.isToday(digestID: today.id) && !archive.isToday(digestID: earlier.id))
        #expect(archive.day(ofDigest: earlier.id) == DigestDay(year: 2026, month: 3, day: 2))
        #expect(archive.day(ofDigest: today.id) == nil && archive.day(ofDigest: backlog.id) == nil)
        #expect(archive.hasBacklog(backlog.id) && !archive.hasBacklog(earlier.id))
    }
}
