import Foundation

/// Pages a Backlog digest into review batches of 50 source emails (Q16). The order is the job's own
/// (newest mail first), and only emails that already have a persisted result take part, so a batch fills
/// up live as the job runs and the panel never lists more than one batch of suggestions.
public struct BacklogBatching: Sendable, Equatable {
    public static let defaultSize = 50

    public let size: Int
    /// Emails with a result, in job order.
    public let emailIDs: [String]

    /// `jobOrder` lists the job's message ids by position; `resultIDs` are the ids that have a result.
    public init(jobOrder: [String], resultIDs: Set<String>, size: Int = BacklogBatching.defaultSize) {
        self.size = max(1, size)
        var seen = Set<String>()
        self.emailIDs = jobOrder.filter { resultIDs.contains($0) && seen.insert($0).inserted }
    }

    public var batchCount: Int { max(1, (emailIDs.count + size - 1) / size) }

    /// Clamps to a valid batch number, so a stale selection never points past the end.
    public func clamped(_ batch: Int) -> Int { min(max(batch, 0), batchCount - 1) }

    /// The source emails of one batch.
    public func ids(inBatch batch: Int) -> Set<String> {
        let b = clamped(batch)
        let lower = b * size
        guard lower < emailIDs.count else { return [] }
        return Set(emailIDs[lower..<min(lower + size, emailIDs.count)])
    }

    /// "Batch 2 of 7 · emails 51 to 100"; just the range when there is a single batch.
    public func title(batch: Int) -> String {
        guard !emailIDs.isEmpty else { return "No results yet" }
        let b = clamped(batch)
        let first = b * size + 1
        let last = min((b + 1) * size, emailIDs.count)
        let range = first == last ? "email \(first)" : "emails \(first) to \(last)"
        return batchCount == 1 ? range.prefix(1).uppercased() + range.dropFirst()
            : "Batch \(b + 1) of \(batchCount) · \(range)"
    }

    /// The digest restricted to one batch's emails; headline and id are kept.
    public func digest(_ digest: Digest, batch: Int) -> Digest {
        let keep = ids(inBatch: batch)
        return Digest(id: digest.id, createdAt: digest.createdAt, headline: digest.headline,
                      emailCount: keep.count,
                      suggestions: digest.suggestions.filter { keep.contains($0.emailID) },
                      info: digest.info.filter { keep.contains($0.emailID) },
                      skipped: digest.skipped.filter { keep.contains($0.id) })
    }
}
