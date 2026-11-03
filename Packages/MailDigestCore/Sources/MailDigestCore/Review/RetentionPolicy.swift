import Foundation

/// The "History retention" setting.
public enum HistoryRetention: String, Codable, Sendable, CaseIterable {
    case forever, oneYear, ninetyDays, thirtyDays

    public static let `default`: HistoryRetention = .ninetyDays

    /// Maximum record age in seconds, or nil to keep everything.
    public var maxAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .oneYear: return 365 * 86_400
        case .ninetyDays: return 90 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }
}

/// Ids of records due for deletion. It deliberately has no field for processed email ids or
/// decisions, so a cleanup built from a plan cannot delete them (old mail must never be
/// reprocessed and learned sender rules must survive). Job items go with their job.
public struct RetentionPlan: Sendable, Equatable {
    public var digestIDs: [UUID]
    public var jobIDs: [UUID]

    public init(digestIDs: [UUID] = [], jobIDs: [UUID] = []) {
        self.digestIDs = digestIDs
        self.jobIDs = jobIDs
    }
}

/// Decides which digests and jobs the daily cleanup deletes.
public struct RetentionPolicy: Sendable {
    public init() {}

    /// Digests and finished or failed jobs strictly older than the limit. Pinned digests are kept.
    public func plan(retention: HistoryRetention, now: Date, digests: [Digest], jobs: [Job]) -> RetentionPlan {
        guard let maxAge = retention.maxAge else { return RetentionPlan() }
        let cutoff = now.addingTimeInterval(-maxAge)
        return RetentionPlan(
            digestIDs: digests.filter { $0.createdAt < cutoff && !Self.hasPinned($0) }.map(\.id),
            // Paused or stopped jobs can still be resumed, so only terminal states are cleaned.
            jobIDs: jobs.filter { $0.createdAt < cutoff && Self.isTerminal($0) }.map(\.id))
    }

    /// "Delete all history now": everything except pinned digests and unfinished (running or resumable) jobs.
    public func deleteAllPlan(digests: [Digest], jobs: [Job]) -> RetentionPlan {
        RetentionPlan(
            digestIDs: digests.filter { !Self.hasPinned($0) }.map(\.id),
            jobIDs: jobs.filter(Self.isTerminal).map(\.id))
    }

    private static func hasPinned(_ digest: Digest) -> Bool { digest.info.contains { $0.pinned } }
    private static func isTerminal(_ job: Job) -> Bool { job.state == .finished || job.state == .failed }
}
