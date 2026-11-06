import Foundation

/// Rebuilds a `JobProgress` from persisted rows, for a job that isn't running in this session (for
/// example one paused before the app was quit), so its strip and Resume button can show again.
public enum JobProgressSnapshot {
    public static func progress(job: Job, items: [JobItem]) -> JobProgress {
        var counts: [MailboxRef: MailboxProgress] = [:]
        var done = 0, failed = 0
        for item in items {
            var c = counts[item.mailbox] ?? MailboxProgress(done: 0, total: 0)
            c.total += 1
            switch item.state {
            case .queued, .processing: break
            case .done: done += 1; c.done += 1
            case .failed: failed += 1; done += 1; c.done += 1
            case .skipped: done += 1; c.done += 1
            }
            counts[item.mailbox] = c
        }
        let ordered = items.sorted { $0.position < $1.position }
        let last = ordered.last { $0.state != .queued && $0.state != .processing }
        let next = ordered.first { $0.state == .queued || $0.state == .processing }
        let seconds = Array(ordered.filter { $0.state == .done }.compactMap(\.seconds).suffix(20))
        let avg = seconds.isEmpty ? nil : seconds.reduce(0, +) / Double(seconds.count)
        func summary(_ i: JobItem) -> JobItemSummary {
            JobItemSummary(messageID: i.messageID, sender: i.sender, subject: i.subject, mailbox: i.mailbox,
                           position: i.position, outcome: i.outcome)
        }
        return JobProgress(jobID: job.id, kind: job.kind, state: job.state, done: done, total: items.count,
                           failed: failed, avgSecondsPerEmail: avg,
                           eta: avg.map { $0 * Double(items.count - done) }, stage: .fetching, current: nil,
                           lastFinished: last.map(summary), nextUp: next.map(summary), countsByMailbox: counts,
                           error: job.lastError, pauseReason: job.pauseReason)
    }
}
