import Foundation

public enum JobKind: String, Codable, Sendable, Equatable { case daily, backlog }

public enum JobState: String, Codable, Sendable, Equatable {
    /// `stopped` is an explicit user Stop (Q15): resumable by hand from Past Jobs, never automatically.
    case idle, listing, running, pausing, paused, stopping, stopped, finished, failed
}

/// Why a job was paused by the app rather than by the user.
public enum PauseReason: String, Codable, Sendable, Equatable, CaseIterable {
    case battery, lowPowerMode, heat, quietHours, dailyJob

    /// Short text for "Paused after #412 … (battery power)".
    public var displayText: String {
        switch self {
        case .battery: return "battery power"
        case .lowPowerMode: return "Low Power Mode"
        case .heat: return "Mac is hot"
        case .quietHours: return "quiet hours"
        case .dailyJob: return "Daily job running"
        }
    }
}

public enum JobStage: String, Codable, Sendable, Equatable {
    case listing, fetching, summarising, validating, saving
}

public enum JobItemState: String, Codable, Sendable, Equatable {
    case queued, processing, done, failed, skipped
}

/// What the user confirmed in the preview; saved with the job unchanged.
public struct JobPlan: Codable, Sendable, Equatable {
    public var kind: JobKind
    public var mailboxes: [MailboxRef]
    public var from: Date
    public var to: Date
    public var excludedMessageIDs: Set<String>

    public init(kind: JobKind, mailboxes: [MailboxRef], from: Date, to: Date, excludedMessageIDs: Set<String>) {
        self.kind = kind
        self.mailboxes = mailboxes
        self.from = from
        self.to = to
        self.excludedMessageIDs = excludedMessageIDs
    }
}

public struct JobTotals: Codable, Sendable, Equatable {
    public var queued: Int
    public var done: Int
    public var failed: Int
    public var skipped: Int

    public init(queued: Int, done: Int, failed: Int, skipped: Int) {
        self.queued = queued
        self.done = done
        self.failed = failed
        self.skipped = skipped
    }
}

/// A row of the `job` table.
public struct Job: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: JobKind
    public var mailboxes: [MailboxRef]
    public var scopeFrom: Date
    public var scopeTo: Date
    public var state: JobState
    public var createdAt: Date
    public var totals: JobTotals
    public var autoPaused: Bool
    /// Why the app auto-paused the job; nil when the user paused it or it isn't paused. Older stored jobs
    /// have none.
    public var pauseReason: PauseReason?
    /// Why the job stopped as `.failed` (for example "Ollama is not reachable…"). Safe to show; never
    /// contains email content. Cleared when the job is resumed.
    public var lastError: String?

    public init(id: UUID, kind: JobKind, mailboxes: [MailboxRef], scopeFrom: Date, scopeTo: Date,
                state: JobState, createdAt: Date, totals: JobTotals, autoPaused: Bool, lastError: String? = nil,
                pauseReason: PauseReason? = nil) {
        self.pauseReason = pauseReason
        self.lastError = lastError
        self.id = id
        self.kind = kind
        self.mailboxes = mailboxes
        self.scopeFrom = scopeFrom
        self.scopeTo = scopeTo
        self.state = state
        self.createdAt = createdAt
        self.totals = totals
        self.autoPaused = autoPaused
    }

    /// Clears the pause markers when a job starts running again.
    mutating func clearPause() {
        autoPaused = false
        pauseReason = nil
    }
}

/// A row of the `job_item` table.
public struct JobItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var jobID: UUID
    public var messageID: String
    public var mailbox: MailboxRef
    public var sender: String
    public var subject: String
    public var receivedAt: Date
    public var position: Int
    public var state: JobItemState
    public var outcome: String?
    public var seconds: Double?
    public var attempts: Int
    public var lastError: String?
    /// When the item reached a final state; the activity log's "time".
    public var finishedAt: Date?
    /// Private locator from the SQLite listing; a hint only, never identity.
    public var storeRowID: Int64?

    /// Identity plus locator, as passed to `MailSource.fetchMessages`.
    public var reference: MailMessageReference {
        MailMessageReference(messageID: messageID, storeRowID: storeRowID)
    }

    public init(id: UUID, jobID: UUID, messageID: String, mailbox: MailboxRef, sender: String,
                subject: String, receivedAt: Date, position: Int, state: JobItemState,
                outcome: String?, seconds: Double?, attempts: Int, lastError: String?, finishedAt: Date? = nil,
                storeRowID: Int64? = nil) {
        self.storeRowID = storeRowID
        self.id = id
        self.jobID = jobID
        self.messageID = messageID
        self.mailbox = mailbox
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.position = position
        self.state = state
        self.outcome = outcome
        self.seconds = seconds
        self.attempts = attempts
        self.lastError = lastError
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, jobID, messageID, mailbox, sender, subject, receivedAt, position, state, outcome
        case seconds, attempts, lastError, finishedAt, storeRowID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), jobID: try c.decode(UUID.self, forKey: .jobID),
                  messageID: try c.decode(String.self, forKey: .messageID),
                  mailbox: try c.decode(MailboxRef.self, forKey: .mailbox),
                  sender: try c.decode(String.self, forKey: .sender),
                  subject: try c.decode(String.self, forKey: .subject),
                  receivedAt: try c.decode(Date.self, forKey: .receivedAt),
                  position: try c.decode(Int.self, forKey: .position),
                  state: try c.decode(JobItemState.self, forKey: .state),
                  outcome: try c.decodeIfPresent(String.self, forKey: .outcome),
                  seconds: try c.decodeIfPresent(Double.self, forKey: .seconds),
                  attempts: try c.decode(Int.self, forKey: .attempts),
                  lastError: try c.decodeIfPresent(String.self, forKey: .lastError),
                  finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt),
                  storeRowID: try c.decodeIfPresent(Int64.self, forKey: .storeRowID))
    }
}

/// Short description of an item for progress displays.
public struct JobItemSummary: Codable, Sendable, Equatable {
    public var messageID: String
    public var sender: String
    public var subject: String
    public var mailbox: MailboxRef
    public var position: Int
    public var outcome: String?

    public init(messageID: String, sender: String, subject: String, mailbox: MailboxRef, position: Int, outcome: String?) {
        self.messageID = messageID
        self.sender = sender
        self.subject = subject
        self.mailbox = mailbox
        self.position = position
        self.outcome = outcome
    }
}

public struct MailboxProgress: Codable, Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public struct JobProgress: Codable, Sendable, Equatable {
    public var jobID: UUID
    public var kind: JobKind
    public var state: JobState
    public var done: Int
    public var total: Int
    public var failed: Int
    public var avgSecondsPerEmail: Double?   // rolling average of the last 20 emails
    public var eta: TimeInterval?
    public var stage: JobStage               // listing, fetching, summarising, validating, saving
    public var current: JobItemSummary?      // sender, subject, mailbox, position
    public var lastFinished: JobItemSummary? // with outcome, shown when paused
    public var nextUp: JobItemSummary?       // first queued item, shown when paused
    public var countsByMailbox: [MailboxRef: MailboxProgress] // done/total per mailbox
    /// The job's `lastError` when it stopped as `.failed` (for example a provider outage).
    public var error: String?
    /// Why the app auto-paused the job, when it did.
    public var pauseReason: PauseReason?

    public init(jobID: UUID, kind: JobKind, state: JobState, done: Int, total: Int, failed: Int,
                avgSecondsPerEmail: Double?, eta: TimeInterval?, stage: JobStage,
                current: JobItemSummary?, lastFinished: JobItemSummary?, nextUp: JobItemSummary?,
                countsByMailbox: [MailboxRef: MailboxProgress], error: String? = nil,
                pauseReason: PauseReason? = nil) {
        self.pauseReason = pauseReason
        self.error = error
        self.jobID = jobID
        self.kind = kind
        self.state = state
        self.done = done
        self.total = total
        self.failed = failed
        self.avgSecondsPerEmail = avgSecondsPerEmail
        self.eta = eta
        self.stage = stage
        self.current = current
        self.lastFinished = lastFinished
        self.nextUp = nextUp
        self.countsByMailbox = countsByMailbox
    }
}
