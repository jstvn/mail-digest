import Foundation
import Testing
@testable import MailDigestCore

@Suite struct JobSummaryTextTests {
    private let icloud = MailboxRef(account: "iCloud", name: "Inbox")
    private let outlook = MailboxRef(account: "Outlook", name: "Inbox")
    private let tz = TimeZone(identifier: "Australia/Brisbane")!
    private let us = Locale(identifier: "en_US")

    private func job(_ state: JobState, boxes: [MailboxRef]? = nil, totals: JobTotals = JobTotals(queued: 0, done: 5, failed: 0, skipped: 0),
                     from: Date = Date(timeIntervalSince1970: 1_790_000_000), reason: PauseReason? = nil) -> Job {
        Job(id: UUID(), kind: .backlog, mailboxes: boxes ?? [icloud, outlook], scopeFrom: from,
            scopeTo: Date(timeIntervalSince1970: 1_793_000_000), state: state, createdAt: from, totals: totals,
            autoPaused: reason != nil, pauseReason: reason)
    }

    @Test func mailboxTitleHasNoKindPrefixAndNormalisesInbox() {
        #expect(JobSummaryText.mailboxTitle(job(.paused)) == "iCloud Inbox and Outlook Inbox")
        #expect(JobSummaryText.mailboxTitle(job(.paused, boxes: [MailboxRef(account: "Gmail", name: "INBOX")])) == "Gmail Inbox")
        #expect(JobSummaryText.mailboxTitle(job(.paused, boxes: [MailboxRef(account: "Gmail", name: "inbox")])) == "Gmail Inbox")
        #expect(JobSummaryText.mailboxTitle(job(.paused, boxes: [MailboxRef(account: "Gmail", name: "INBOX/Receipts")])) == "Gmail INBOX/Receipts")
        #expect(JobSummaryText.mailboxTitle(job(.paused, boxes: [])) == "no mailboxes")
        #expect(JobSummaryText.title(job(.paused, boxes: [MailboxRef(account: "Gmail", name: "INBOX")])) == "Backlog · Gmail Inbox")
    }

    @Test func titleNamesMailboxes() {
        #expect(JobSummaryText.title(job(.paused)) == "Backlog · iCloud Inbox and Outlook Inbox")
        #expect(JobSummaryText.title(job(.paused, boxes: [icloud])) == "Backlog · iCloud Inbox")
        #expect(JobSummaryText.title(job(.paused, boxes: [icloud, outlook, MailboxRef(account: "X", name: "Y")])) == "Backlog · 3 mailboxes")
    }

    @Test func scopeTextIncludingEverything() {
        let j = job(.finished)
        #expect(JobSummaryText.scope(j, timeZone: tz, locale: us) == "22 Sep 2026 to 26 Oct 2026")
        let all = job(.finished, from: Date(timeIntervalSince1970: 0))
        #expect(JobSummaryText.scope(all, timeZone: tz, locale: us) == "Everything up to 26 Oct 2026")
    }

    @Test func totalsLeaveOutZeroParts() {
        #expect(JobSummaryText.totals(job(.finished)) == "5 done")
        let t = JobTotals(queued: 2100, done: 812, failed: 6, skipped: 40)
        #expect(JobSummaryText.totals(job(.paused, totals: t)) == "812 done · 6 failed · 40 skipped · 2,100 left")
    }

    @Test func stateTextAndActions() {
        #expect(JobSummaryText.state(job(.paused, reason: .battery)) == "Paused (battery power)")
        #expect(JobSummaryText.state(job(.stopped)) == "Stopped")
        let left = JobTotals(queued: 3, done: 1, failed: 2, skipped: 0)
        #expect(JobSummaryText.canResume(job(.paused, totals: left)))
        #expect(JobSummaryText.canResume(job(.stopped, totals: left)))
        #expect(JobSummaryText.canResume(job(.failed, totals: left)))
        #expect(!JobSummaryText.canResume(job(.finished, totals: left)))
        #expect(!JobSummaryText.canResume(job(.paused)))
        #expect(JobSummaryText.canRetryFailed(job(.finished, totals: left)))
        #expect(!JobSummaryText.canRetryFailed(job(.running, totals: left)))
    }
}
