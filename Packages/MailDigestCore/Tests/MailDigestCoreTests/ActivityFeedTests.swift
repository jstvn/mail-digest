import Foundation
import Testing
@testable import MailDigestCore

private let t0 = FixtureLoader.today
private let icloud = MailboxRef(account: "iCloud", name: "Inbox")
private let outlook = MailboxRef(account: "Outlook", name: "Inbox")

private func item(_ pos: Int, _ state: JobItemState, finished: Double? = nil, sender: String = "Ray White <rent@raywhite.example>",
                  subject: String = "Rent due Friday", box: MailboxRef = outlook) -> JobItem {
    JobItem(id: UUID(), jobID: UUID(), messageID: "m\(pos)", mailbox: box, sender: sender, subject: subject,
            receivedAt: t0, position: pos, state: state, outcome: state == .done ? "info only" : nil,
            seconds: finished == nil ? nil : 12, attempts: 1, lastError: nil,
            finishedAt: finished.map { t0.addingTimeInterval($0) })
}

private func summary(_ pos: Int, _ sender: String, _ subject: String, box: MailboxRef = outlook) -> JobItemSummary {
    JobItemSummary(messageID: "m\(pos)", sender: sender, subject: subject, mailbox: box, position: pos, outcome: nil)
}

private func progress(state: JobState = .running, done: Int = 412, total: Int = 1081, failed: Int = 6,
                      eta: TimeInterval? = 3 * 3600 + 50 * 60, stage: JobStage = .summarising,
                      current: JobItemSummary? = nil, last: JobItemSummary? = nil, next: JobItemSummary? = nil) -> JobProgress {
    JobProgress(jobID: UUID(), kind: .backlog, state: state, done: done, total: total, failed: failed,
                avgSecondsPerEmail: nil, eta: eta, stage: stage, current: current, lastFinished: last,
                nextUp: next, countsByMailbox: [:])
}

@Suite struct ActivityFeedTests {
    let feed = ActivityFeed()

    @Test func rowsAreOrderedByPositionAndFilterable() {
        let items = [item(3, .done, finished: 3), item(1, .failed, finished: 1), item(2, .done, finished: 2), item(4, .queued)]
        #expect(feed.rows(items).map(\.position) == [1, 2, 3, 4])
        #expect(feed.rows(items, filter: .done).map(\.position) == [2, 3])
        #expect(feed.rows(items, filter: .failed).map(\.state) == [.failed])
        let row = feed.rows(items)[1]
        #expect(row.id == items[2].id && row.outcome == "info only" && row.seconds == 12
            && row.finishedAt == t0.addingTimeInterval(2) && row.mailbox == outlook)
    }

    @Test func recentIsLastFiveFinishedNewestFirstWithPositionTieBreak() {
        var items = (1...8).map { item($0, .done, finished: Double($0)) }
        items.append(item(9, .queued))
        items.append(item(10, .processing))
        // Positions 4 and 5 finish at the same instant; the higher position comes first.
        items[3] = item(4, .done, finished: 5)
        let recent = feed.recent(items)
        #expect(recent.map(\.position) == [8, 7, 6, 5, 4])
        #expect(feed.recent(items, limit: 2).map(\.position) == [8, 7])
    }

    @Test func pausedSummaryText() {
        let last = summary(412, "Ray White <rent@raywhite.example>", "Rent due Friday")
        let next = summary(413, "QUT Canvas <canvas@qut.edu.au>", "Assessment 2 reminder", box: icloud)
        #expect(feed.pausedSummary(progress: progress(state: .paused, last: last, next: next))
            == "Paused after #412 · Ray White · Rent due Friday. Next: #413 · QUT Canvas · Assessment 2 reminder")
        #expect(feed.pausedSummary(progress: progress(state: .running, last: last, next: next)) == nil)
        #expect(feed.pausedSummary(progress: progress(state: .paused, last: last, next: nil))
            == "Paused after #412 · Ray White · Rent due Friday")
        let bare = summary(1, "bob@example.com", "Hi")
        #expect(feed.pausedSummary(progress: progress(state: .paused, last: nil, next: bare)) == "Paused. Next: #1 · bob@example.com · Hi")
        #expect(feed.pausedSummary(progress: progress(state: .paused)) == "Paused")
    }

    @Test func nowLineText() {
        let cur = summary(412, "\"Ray White\" <rent@raywhite.example>", "Rent due Friday")
        #expect(feed.nowLine(progress: progress(current: cur)) == "Summarising · Ray White · Rent due Friday · Outlook Inbox")
        #expect(feed.nowLine(progress: progress(stage: .fetching, current: cur)) == "Fetching · Ray White · Rent due Friday · Outlook Inbox")
        #expect(feed.nowLine(progress: progress(current: nil)) == nil)
    }

    @Test func statusLineVariants() {
        #expect(feed.statusLine(progress: progress()) == "412 of 1,081 · 6 failed · about 3 h 50 min left")
        #expect(feed.statusLine(progress: progress(failed: 0)) == "412 of 1,081 · about 3 h 50 min left")
        #expect(feed.statusLine(progress: progress(eta: nil)) == "412 of 1,081 · 6 failed")
        #expect(feed.statusLine(progress: progress(failed: 0, eta: nil)) == "412 of 1,081")
        #expect(feed.statusLine(progress: progress(failed: 0, eta: 20)) == "412 of 1,081 · under a minute left")
    }
}
