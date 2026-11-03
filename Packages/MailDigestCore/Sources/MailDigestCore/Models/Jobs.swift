import Foundation

public enum JobKind: String, Codable, Sendable, Equatable { case daily, backlog }

public enum JobState: String, Codable, Sendable, Equatable {
    case idle, listing, running, pausing, paused, stopping, finished, failed
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

    public init(id: UUID, kind: JobKind, mailboxes: [MailboxRef], scopeFrom: Date, scopeTo: Date,
                state: JobState, createdAt: Date, totals: JobTotals, autoPaused: Bool) {
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

    public init(id: UUID, jobID: UUID, messageID: String, mailbox: MailboxRef, sender: String,
                subject: String, receivedAt: Date, position: Int, state: JobItemState,
                outcome: String?, seconds: Double?, attempts: Int, lastError: String?) {
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

    public init(jobID: UUID, kind: JobKind, state: JobState, done: Int, total: Int, failed: Int,
                avgSecondsPerEmail: Double?, eta: TimeInterval?, stage: JobStage,
                current: JobItemSummary?, lastFinished: JobItemSummary?, nextUp: JobItemSummary?,
                countsByMailbox: [MailboxRef: MailboxProgress]) {
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
