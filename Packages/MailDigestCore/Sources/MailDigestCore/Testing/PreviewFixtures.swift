import Foundation

/// Sample data for SwiftUI previews and tests: a realistic digest, job progress, and the email facts behind it.
/// Fixed dates only, so previews and tests are deterministic.
public enum PreviewFixtures {
    /// Wed 4 Nov 2026, 06:45 in Brisbane (UTC+10).
    public static let now = Date(timeIntervalSince1970: 1_793_738_700)
    public static let timeZone = TimeZone(identifier: "Australia/Brisbane")!

    public static let icloudInbox = MailboxRef(account: "iCloud", name: "Inbox")
    public static let outlookInbox = MailboxRef(account: "Outlook", name: "Inbox")

    private static func day(_ days: Double, hour: Double = 0) -> Date { now.addingTimeInterval(days * 86_400 + hour * 3600) }

    /// Fixed ids so previews and tests can refer to a suggestion.
    public enum ID {
        public static let payRent = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        public static let submitA2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        public static let replySam = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        public static let scam = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        public static let parcel = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    }

    private static func suggestion(_ id: UUID, email: String, _ title: String, due: Date?, hasTime: Bool = false,
                                   _ priority: Priority, evidence: String, confidence: Double,
                                   flags: [String] = [], category: Category?) -> Suggestion {
        Suggestion(id: id, emailID: email, title: title, due: due, dueHasTime: hasTime, priority: priority,
                   evidence: evidence, confidence: confidence, preselected: confidence >= 0.75 && flags.isEmpty,
                   flags: flags, status: .pending, reminderID: nil, category: category)
    }

    /// Four pending suggestions (one flagged scam, one without a date), info in several categories
    /// including nine collapsed newsletters, and three skipped emails with reasons.
    public static let digest: Digest = {
        let suggestions = [
            suggestion(ID.payRent, email: "rent@raywhite.example", "Pay rent", due: day(2), .high,
                       evidence: "Rent of $540 is due this Friday", confidence: 0.92, category: .finance),
            suggestion(ID.submitA2, email: "canvas@qut.example", "Submit INN700 A2", due: day(5, hour: 17), hasTime: true,
                       .medium, evidence: "Assessment 2 is due Monday 9 November at 5pm", confidence: 0.88,
                       category: .uni),
            suggestion(ID.replySam, email: "sam@example.com", "Reply to Sam about Saturday", due: nil, .low,
                       evidence: "Are you free on Saturday? Let me know", confidence: 0.55, category: .personal),
            suggestion(ID.scam, email: "billing@parcel-pay.example", "Pay $1.99 redelivery fee", due: day(1), .high,
                       evidence: "Pay the redelivery fee by tomorrow or the parcel is returned", confidence: 0.8,
                       flags: ["money-new-sender"], category: .deliveries),
        ]
        var info = [
            InfoItem(id: "exam@qut.example", emailID: "exam@qut.example", category: .uni, importance: 4,
                     summary: "IFN735 exam timetable released.", keyFacts: ["IFN735 exam: 18 Nov, 9am", "Room GP-S503"],
                     pinned: false),
            InfoItem(id: "canvas@qut.example", emailID: "canvas@qut.example", category: .uni, importance: 3,
                     summary: "Assessment 2 for INN700 is open for submission.", keyFacts: ["Due Mon 9 Nov, 5pm"],
                     pinned: false),
            InfoItem(id: "tutor@qut.example", emailID: "tutor@qut.example", category: .uni, importance: 2,
                     summary: "Tutorial 7 moved to Thursday.", keyFacts: [], pinned: false),
            InfoItem(id: "auspost@example.com", emailID: "auspost@example.com", category: .deliveries, importance: 3,
                     summary: "Your parcel arrives on Thursday.", keyFacts: ["AusPost", "Thursday between 9am and 1pm"],
                     pinned: false),
            InfoItem(id: "shop@example.com", emailID: "shop@example.com", category: .deliveries, importance: 2,
                     summary: "Your order has shipped.", keyFacts: ["Tracking sent by SMS"], pinned: false),
            InfoItem(id: "bank@example.com", emailID: "bank@example.com", category: .finance, importance: 3,
                     summary: "Your card statement is ready.", keyFacts: ["Closing balance $412.80"], pinned: false),
            InfoItem(id: "rent@raywhite.example", emailID: "rent@raywhite.example", category: .finance, importance: 4,
                     summary: "Rent reminder for this week.", keyFacts: ["$540 due Friday"], pinned: false),
        ]
        for n in 1...9 {
            info.append(InfoItem(id: "news\(n)@example.com", emailID: "news\(n)@example.com", category: .newsletters,
                                 importance: 1, summary: "Weekly roundup number \(n).", keyFacts: [], pinned: false))
        }
        let skipped = [
            SkippedEmail(id: "promo1@example.com", sender: "Temu <deals@temu.example>", subject: "Your deals today",
                         reason: "ignored sender"),
            SkippedEmail(id: "fail1@example.com", sender: "Ray White <rent@raywhite.example>", subject: "Statement",
                         reason: "failed: model timeout"),
            SkippedEmail(id: "empty1@example.com", sender: "no-reply@example.com", subject: "(no subject)",
                         reason: "empty body"),
        ]
        return Digest(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, createdAt: now,
                      headline: "IFN735 exam timetable is out and your rent is due Friday.", emailCount: 23,
                      suggestions: suggestions, info: info, skipped: skipped)
    }()

    /// A digest with no mail in it.
    public static let emptyDigest = Digest(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!,
                                           createdAt: now, headline: "", emailCount: 0, suggestions: [], info: [],
                                           skipped: [])

    /// Sender, subject and mailbox for the sample emails, keyed by email id.
    public static let emails: [String: EmailContext] = [
        "rent@raywhite.example": EmailContext(sender: "Ray White <rent@raywhite.example>", subject: "Rent due Friday", mailbox: outlookInbox),
        "canvas@qut.example": EmailContext(sender: "QUT Canvas <canvas@qut.example>", subject: "Assessment 2 reminder", mailbox: icloudInbox),
        "sam@example.com": EmailContext(sender: "Sam <sam@example.com>", subject: "Saturday?", mailbox: icloudInbox),
        "billing@parcel-pay.example": EmailContext(sender: "Parcel Pay <billing@parcel-pay.example>", subject: "Redelivery fee", mailbox: icloudInbox),
    ]

    private static func summary(_ n: Int, _ sender: String, _ subject: String, outcome: String? = nil,
                                box: MailboxRef = outlookInbox) -> JobItemSummary {
        JobItemSummary(messageID: "m\(n)", sender: sender, subject: subject, mailbox: box, position: n, outcome: outcome)
    }

    public static let jobID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!

    /// A Backlog job part-way through, with an hours-long estimate.
    public static let runningProgress = JobProgress(
        jobID: jobID, kind: .backlog, state: .running, done: 412, total: 1_081, failed: 6,
        avgSecondsPerEmail: 20.6, eta: 3 * 3600 + 50 * 60, stage: .summarising,
        current: summary(413, "Ray White <rent@raywhite.example>", "Rent due Friday"),
        lastFinished: summary(412, "QUT Canvas <canvas@qut.example>", "Assessment 2 reminder", outcome: "2 reminders"),
        nextUp: summary(414, "Sam <sam@example.com>", "Saturday?"),
        countsByMailbox: [icloudInbox: MailboxProgress(done: 300, total: 828),
                          outlookInbox: MailboxProgress(done: 112, total: 253)])

    /// The same job paused between emails #412 and #413.
    public static let pausedProgress = JobProgress(
        jobID: jobID, kind: .backlog, state: .paused, done: 412, total: 1_081, failed: 6,
        avgSecondsPerEmail: 20.6, eta: nil, stage: .saving, current: nil,
        lastFinished: summary(412, "Ray White <rent@raywhite.example>", "Rent due Friday", outcome: "1 reminder"),
        nextUp: summary(413, "QUT Canvas <canvas@qut.example>", "Assessment 2 reminder", box: icloudInbox),
        countsByMailbox: [:])

    /// A short Daily job that is 12 emails in.
    public static let dailyRunningProgress = JobProgress(
        jobID: jobID, kind: .daily, state: .running, done: 11, total: 23, failed: 0,
        avgSecondsPerEmail: 20, eta: 240, stage: .summarising,
        current: summary(12, "Ray White <rent@raywhite.example>", "Rent due Friday"),
        lastFinished: nil, nextUp: nil, countsByMailbox: [:])
}
