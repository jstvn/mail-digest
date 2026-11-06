import Foundation
import Testing
@testable import MailDigestCore

@Suite struct JobProgressSnapshotTests {
    private let box = MailboxRef(account: "iCloud", name: "Inbox")
    private let jobID = UUID()

    private func item(_ n: Int, _ state: JobItemState, seconds: Double? = nil) -> JobItem {
        JobItem(id: UUID(), jobID: jobID, messageID: "m\(n)", mailbox: box, sender: "Ray <r@x.com>",
                subject: "S\(n)", receivedAt: PreviewFixtures.now, position: n, state: state,
                outcome: state == .done ? "info only" : nil, seconds: seconds, attempts: 0, lastError: nil)
    }

    @Test func pausedJobReportsLastFinishedNextUpAndReason() {
        let job = Job(id: jobID, kind: .backlog, mailboxes: [box], scopeFrom: PreviewFixtures.now,
                      scopeTo: PreviewFixtures.now, state: .paused, createdAt: PreviewFixtures.now,
                      totals: JobTotals(queued: 2, done: 2, failed: 1, skipped: 0), autoPaused: true,
                      pauseReason: .battery)
        let items = [item(1, .done, seconds: 10), item(2, .done, seconds: 20), item(3, .failed),
                     item(4, .queued), item(5, .queued)]
        let p = JobProgressSnapshot.progress(job: job, items: items)
        #expect(p.state == .paused && p.done == 3 && p.total == 5 && p.failed == 1)
        #expect(p.lastFinished?.position == 3 && p.nextUp?.position == 4)
        #expect(p.avgSecondsPerEmail == 15 && p.eta == 30)
        #expect(p.pauseReason == .battery)
        #expect(p.countsByMailbox[box] == MailboxProgress(done: 3, total: 5))
    }
}
