import Foundation

/// Lifecycle transitions recorded in `job_event` (never per-email work; that is `job_item`).
public enum JobEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case created, started, paused, autoPaused, resumed, stopped
    case completed, completedWithFailures, failed, retryRequested, recoveredAfterInterruption
}

/// Who or what caused a resume or a recovery.
public enum JobEventTrigger: String, Codable, Sendable, Equatable {
    case user, automatic, launch
}

/// Small, content-free detail for an event. Never holds email content, raw error text or keys.
public struct JobEventPayload: Codable, Sendable, Equatable {
    public var pauseReason: PauseReason?
    public var trigger: JobEventTrigger?
    public var count: Int?
    /// Short code such as `provider` or `mail`; never an error message.
    public var errorCategory: String?

    public init(pauseReason: PauseReason? = nil, trigger: JobEventTrigger? = nil, count: Int? = nil,
                errorCategory: String? = nil) {
        self.pauseReason = pauseReason
        self.trigger = trigger
        self.count = count
        self.errorCategory = errorCategory
    }

    public static let empty = JobEventPayload()
}

/// A row of the append-only `job_event` table.
public struct JobEvent: Codable, Sendable, Equatable, Identifiable {
    /// Assigned by the store on insert; nil before.
    public var id: Int64?
    public var jobID: UUID
    public var kind: JobEventKind
    public var at: Date
    public var payload: JobEventPayload

    public init(id: Int64? = nil, jobID: UUID, kind: JobEventKind, at: Date, payload: JobEventPayload = .empty) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.at = at
        self.payload = payload
    }
}

/// Keyset position in the `(createdAt DESC, id DESC)` job order; pages start strictly after it.
public struct ActivityCursor: Codable, Sendable, Equatable {
    public var createdAt: Date
    public var id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }

    /// The cursor that continues after `job`.
    public init(after job: Job) {
        self.init(createdAt: job.createdAt, id: job.id)
    }
}

/// One page request for the Activity list.
public struct ActivityQuery: Sendable, Equatable {
    public var kind: JobKind?
    /// Keeps jobs with at least one item executed by this provider.
    public var path: ExecutionProvider?
    public var before: ActivityCursor?
    public var limit: Int

    public init(kind: JobKind? = nil, path: ExecutionProvider? = nil, before: ActivityCursor? = nil, limit: Int = 30) {
        self.kind = kind
        self.path = path
        self.before = before
        self.limit = limit
    }
}
