import Foundation

/// Text for the Past Jobs list. Pure; time zone and locale are injected.
public enum JobSummaryText {
    /// "Backlog · iCloud Inbox and Outlook Inbox".
    public static func title(_ job: Job) -> String {
        "\(ReviewPresentation.jobName(job.kind)) · \(mailboxTitle(job))"
    }

    /// "iCloud Inbox and Outlook Inbox": the mailbox text without the job-kind prefix.
    public static func mailboxTitle(_ job: Job) -> String {
        var seen = Set<MailboxRef>()
        let names = job.mailboxes.filter { seen.insert($0).inserted }
            .map { "\($0.account) \(displayName(of: $0))" }
        switch names.count {
        case 0: return "no mailboxes"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) mailboxes"
        }
    }

    /// IMAP reserves the name INBOX (any case); show it as "Inbox". Other folder names are left as they are.
    static func displayName(of mailbox: MailboxRef) -> String {
        mailbox.name.caseInsensitiveCompare("INBOX") == .orderedSame ? "Inbox" : mailbox.name
    }

    /// "3 Oct 2026 to 2 Nov 2026", or "Everything up to 2 Nov 2026" when the scope starts before 1990.
    public static func scope(_ job: Job, timeZone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy"
        let to = f.string(from: job.scopeTo)
        if job.scopeFrom.timeIntervalSince1970 < 631_152_000 { return "Everything up to \(to)" }
        return "\(f.string(from: job.scopeFrom)) to \(to)"
    }

    /// "812 done · 6 failed · 40 skipped · 2,100 left"; zero failed, skipped and left are left out.
    public static func totals(_ job: Job) -> String {
        var parts = ["\(JobFormat.number(job.totals.done)) done"]
        if job.totals.failed > 0 { parts.append("\(JobFormat.number(job.totals.failed)) failed") }
        if job.totals.skipped > 0 { parts.append("\(JobFormat.number(job.totals.skipped)) skipped") }
        if job.totals.queued > 0 { parts.append("\(JobFormat.number(job.totals.queued)) left") }
        return parts.joined(separator: " · ")
    }

    /// "Paused (battery power)", "Stopped", "Finished", "Stopped by an error"...
    public static func state(_ job: Job) -> String {
        switch job.state {
        case .paused:
            return job.pauseReason.map { "Paused (\($0.displayText))" } ?? "Paused"
        case .stopped, .stopping: return "Stopped"
        case .finished: return "Finished"
        case .failed: return "Stopped by an error"
        case .running, .pausing: return "Running"
        case .listing: return "Listing"
        case .idle: return "Not started"
        }
    }

    /// A paused or stopped job (or one an outage stopped) with emails left can be resumed by hand.
    public static func canResume(_ job: Job) -> Bool {
        [.paused, .stopped, .failed].contains(job.state) && job.totals.queued > 0
    }

    /// Failed emails can be retried once nothing is running and the job has any.
    public static func canRetryFailed(_ job: Job) -> Bool {
        job.totals.failed > 0 && ![.running, .pausing, .listing, .stopping].contains(job.state)
    }
}
