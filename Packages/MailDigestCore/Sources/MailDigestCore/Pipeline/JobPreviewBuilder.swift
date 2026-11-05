import Foundation

/// Rough split of the emails in a preview by processing tier, worked out from sender addresses only.
public struct TierEstimate: Sendable, Equatable {
    public var skip: Int
    public var infoOnly: Int
    public var full: Int

    public init(skip: Int, infoOnly: Int, full: Int) {
        self.skip = skip
        self.infoOnly = infoOnly
        self.full = full
    }
}

/// What the job setup sheet shows before the user confirms. Built from headers only (no bodies, no model calls).
public struct JobPreview: Sendable, Equatable {
    /// The plan to pass to `JobRunner.start`. Its `to` is fixed at preview time; start never re-reads "now".
    public var plan: JobPlan
    /// Emails found in the date range, per mailbox (before skipping processed or excluded mail).
    public var mailboxTotals: [MailboxRef: Int]
    public var totalFound: Int
    /// Found emails that were processed before or are already queued in a job.
    public var alreadyProcessed: Int
    /// Found emails the user unticked.
    public var excluded: Int
    /// Exactly what `start` will queue, newest first.
    public var toProcess: [MessageHeader]
    public var dateRangeFound: ClosedRange<Date>?
    /// An estimate: headers have no bulk-mail signals, so real tiers can differ.
    public var estimatedTiers: TierEstimate
    public var estimatedSeconds: TimeInterval
    /// The first 200 emails of `toProcess`, for the checkbox list.
    public var firstItems: [MessageHeader]
}

/// Builds a `JobPreview` and the confirm-button text. Pure: no I/O, no clock.
public struct JobPreviewBuilder: Sendable {
    public var filter: MailFilter
    /// Seconds per email before there is any speed history.
    public var defaultSecondsPerEmail: Double
    public var listLimit: Int

    public init(filter: MailFilter = MailFilter(), defaultSecondsPerEmail: Double = 20, listLimit: Int = 200) {
        self.filter = filter
        self.defaultSecondsPerEmail = defaultSecondsPerEmail
        self.listLimit = listLimit
    }

    /// `headers` holds the listed mail per mailbox; `isProcessedOrQueued` the ids to skip.
    /// `limit` caps what is queued (Daily jobs only).
    public func build(plan: JobPlan, headers: [MailboxRef: [MessageHeader]], isProcessedOrQueued: Set<String>,
                      averageSecondsPerEmail: Double?, limit: Int? = nil) -> JobPreview {
        let sel = Self.select(plan: plan, headers: headers, unavailable: isProcessedOrQueued, limit: limit)
        var tiers = TierEstimate(skip: 0, infoOnly: 0, full: 0)
        for h in sel.toProcess {
            switch filter.estimatedTier(for: h) {
            case .skip: tiers.skip += 1
            case .infoOnly: tiers.infoOnly += 1
            case .full: tiers.full += 1
            }
        }
        let dates = sel.found.map(\.receivedAt)
        var range: ClosedRange<Date>?
        if let lo = dates.min(), let hi = dates.max() { range = lo...hi }
        var totals: [MailboxRef: Int] = [:]
        for h in sel.found { totals[h.mailboxRef, default: 0] += 1 }
        let perEmail = averageSecondsPerEmail ?? defaultSecondsPerEmail
        return JobPreview(plan: plan, mailboxTotals: totals, totalFound: sel.found.count,
                          alreadyProcessed: sel.alreadyProcessed, excluded: sel.excluded,
                          toProcess: sel.toProcess, dateRangeFound: range, estimatedTiers: tiers,
                          estimatedSeconds: perEmail * Double(sel.toProcess.count),
                          firstItems: Array(sel.toProcess.prefix(listLimit)))
    }

    /// Text for the Start button, e.g. "Process 1,081 emails from iCloud Inbox and Outlook Inbox (about 6 h)".
    public func startTitle(for preview: JobPreview) -> String {
        let n = preview.toProcess.count
        var seen = Set<MailboxRef>()
        let boxes = preview.plan.mailboxes.filter { seen.insert($0).inserted }
        let names = boxes.map { "\($0.account) \($0.name)" }
        let where_: String
        switch names.count {
        case 0: where_ = ""
        case 1: where_ = " from \(names[0])"
        case 2: where_ = " from \(names[0]) and \(names[1])"
        default: where_ = " from \(names.count) mailboxes"
        }
        return "Process \(JobFormat.number(n)) \(n == 1 ? "email" : "emails")\(where_) "
            + "(\(JobFormat.duration(preview.estimatedSeconds)))"
    }

    // MARK: Shared with JobRunner.start

    /// Result of deduping and filtering listed headers.
    struct Selection {
        /// Unique headers in range, in listing order.
        var found: [MessageHeader] = []
        var toProcess: [MessageHeader] = []
        var alreadyProcessed = 0
        var excluded = 0
    }

    /// The single place that decides what gets queued, so preview and start can't drift apart.
    static func select(plan: JobPlan, headers: [MailboxRef: [MessageHeader]], unavailable: Set<String>,
                       limit: Int?) -> Selection {
        var sel = Selection()
        var seen = Set<String>()
        var mailboxSeen = Set<MailboxRef>()
        for mailbox in plan.mailboxes where mailboxSeen.insert(mailbox).inserted {
            for h in headers[mailbox] ?? [] {
                // The same message can show up in two mailboxes (labels); keep the first.
                guard seen.insert(h.id).inserted else { continue }
                sel.found.append(h)
                if plan.excludedMessageIDs.contains(h.id) { sel.excluded += 1; continue }
                if unavailable.contains(h.id) { sel.alreadyProcessed += 1; continue }
                sel.toProcess.append(h)
            }
        }
        // Newest first across mailboxes; the index keeps equal timestamps in listing order.
        sel.toProcess = sel.toProcess.enumerated()
            .sorted { $0.element.receivedAt != $1.element.receivedAt
                ? $0.element.receivedAt > $1.element.receivedAt : $0.offset < $1.offset }
            .map(\.element)
        if let limit { sel.toProcess = Array(sel.toProcess.prefix(limit)) }
        return sel
    }
}

/// Number and duration text shared by the preview and the progress strip.
public enum JobFormat {
    /// "1,081", always with a comma regardless of the user's locale.
    public static func number(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// "about 6 h", "about 1 h 40 min", "about 4 min" or "under a minute"; rounds to the nearest minute.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }
}
