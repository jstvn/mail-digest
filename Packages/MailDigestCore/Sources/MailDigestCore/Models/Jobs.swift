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
        // An allowed window (Q45), so "quiet hours" would suggest the opposite.
        case .quietHours: return "outside the run window"
        case .dailyJob: return "Daily job running"
        }
    }

    /// Why a Start or Resume left the job paused (Q43), for the banner.
    public var blockedMessage: String {
        switch self {
        case .battery:
            return "The Mac is on battery power, so the job stays paused. It resumes when you plug in, or turn off \"Pause on battery power\" in Settings."
        case .quietHours:
            return "It's outside the Backlog run window, so the job stays paused until the window opens. You can change the window in Settings."
        case .lowPowerMode:
            return "Low Power Mode is on, so the job stays paused until you turn it off."
        case .heat:
            return "The Mac is too hot, so the job stays paused until it cools down."
        case .dailyJob:
            return "A Daily job is running. This job continues after it."
        }
    }
}

public enum JobStage: String, Codable, Sendable, Equatable {
    case listing, fetching, summarising, validating, saving
}

public enum JobItemState: String, Codable, Sendable, Equatable {
    case queued, processing, done, failed, skipped
}

/// Why a job stopped as `.failed`, in a form the UI can act on (for example offering Start Ollama).
public enum JobFailureKind: String, Codable, Sendable, Equatable {
    /// Ollama did not answer: not running, or not reachable.
    case ollamaUnreachable
    /// Ollama runs but the configured model is not installed.
    case modelMissing
    /// Anything else: Mail, the store, a timeout or an unexpected model reply.
    case other

    /// Classifies an error from the model provider.
    public init(_ error: Error) {
        switch error as? LLMError {
        case .unreachable: self = .ollamaUnreachable
        case .modelMissing: self = .modelMissing
        default: self = .other
        }
    }
}

/// What the user confirmed in the preview; saved with the job unchanged.
public struct JobPlan: Codable, Sendable, Equatable {
    public var kind: JobKind
    public var mailboxes: [MailboxRef]
    public var from: Date
    public var to: Date
    public var excludedMessageIDs: Set<String>
    /// The exact emails the user confirmed in a Backlog preview (unticked ones removed). When set, `start`
    /// queues only these and refuses with `previewOutdated` if any is no longer selectable. Nil means
    /// "whatever the selection finds now" (Daily, and callers that never previewed).
    public var confirmedMessageIDs: Set<String>?

    public init(kind: JobKind, mailboxes: [MailboxRef], from: Date, to: Date, excludedMessageIDs: Set<String>,
                confirmedMessageIDs: Set<String>? = nil) {
        self.kind = kind
        self.mailboxes = mailboxes
        self.from = from
        self.to = to
        self.excludedMessageIDs = excludedMessageIDs
        self.confirmedMessageIDs = confirmedMessageIDs
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
    /// Structured form of `lastError`; nil for jobs stored before it existed (they show the generic failure).
    public var failureKind: JobFailureKind?
    /// When the job first started running; nil for jobs stored before v5 and jobs never started.
    public var startedAt: Date?
    /// When the job last reached a terminal state (stopped, finished, failed); cleared when it runs again.
    public var endedAt: Date?

    public init(id: UUID, kind: JobKind, mailboxes: [MailboxRef], scopeFrom: Date, scopeTo: Date,
                state: JobState, createdAt: Date, totals: JobTotals, autoPaused: Bool, lastError: String? = nil,
                pauseReason: PauseReason? = nil, startedAt: Date? = nil, endedAt: Date? = nil,
                failureKind: JobFailureKind? = nil) {
        self.failureKind = failureKind
        self.startedAt = startedAt
        self.endedAt = endedAt
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
    /// When the item last moved to `.processing`; nil for older rows.
    public var startedAt: Date?
    /// Privacy assessment and execution record; nil when none was recorded.
    public var routing: RoutingProvenance?
    /// Final executor, mirrored from `routing.execution` for filtering; nil when no model ran.
    public var provider: ExecutionProvider?

    /// Identity plus locator, as passed to `MailSource.fetchMessages`.
    public var reference: MailMessageReference {
        MailMessageReference(messageID: messageID, storeRowID: storeRowID)
    }

    public init(id: UUID, jobID: UUID, messageID: String, mailbox: MailboxRef, sender: String,
                subject: String, receivedAt: Date, position: Int, state: JobItemState,
                outcome: String?, seconds: Double?, attempts: Int, lastError: String?, finishedAt: Date? = nil,
                storeRowID: Int64? = nil, startedAt: Date? = nil, routing: RoutingProvenance? = nil,
                provider: ExecutionProvider? = nil) {
        self.startedAt = startedAt
        self.routing = routing
        self.provider = provider
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
        case seconds, attempts, lastError, finishedAt, storeRowID, startedAt, routing, provider
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
                  storeRowID: try c.decodeIfPresent(Int64.self, forKey: .storeRowID),
                  startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt),
                  routing: try c.decodeIfPresent(RoutingProvenance.self, forKey: .routing),
                  provider: try c.decodeIfPresent(ExecutionProvider.self, forKey: .provider))
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
