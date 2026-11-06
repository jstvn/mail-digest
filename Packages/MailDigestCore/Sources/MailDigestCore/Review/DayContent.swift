import Foundation

extension SuggestionRecord {
    /// Records for every suggestion of a loaded digest, in digest order. `emails` is keyed by email id.
    public static func records(from digest: Digest, kind: JobKind, emails: [String: EmailContext]) -> [SuggestionRecord] {
        digest.suggestions.map { s in
            SuggestionRecord(suggestion: s, digestID: digest.id, digestCreatedAt: digest.createdAt, kind: kind,
                             category: ReviewActions.category(for: s, info: digest.info), email: emails[s.emailID])
        }
    }
}

/// Several digests of one day shown as one canvas (Q54): runs merged in creation order.
public struct DayContent: Sendable, Equatable {
    public var digestIDs: [UUID]
    /// Records in digest-creation order, then digest order.
    public var records: [SuggestionRecord]
    public var info: [InfoItem]
    public var skipped: [SkippedEmail]
    public var emailCount: Int
    /// The latest non-empty headline, or empty when none has one.
    public var headline: String

    public init(digests: [Digest], kind: JobKind = .daily, emails: [String: EmailContext] = [:]) {
        let ordered = digests.enumerated().sorted {
            ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset)
        }.map(\.element)
        digestIDs = ordered.map(\.id)
        records = ordered.flatMap { SuggestionRecord.records(from: $0, kind: kind, emails: emails) }
        info = ordered.flatMap(\.info)
        skipped = ordered.flatMap(\.skipped)
        emailCount = ordered.reduce(0) { $0 + $1.emailCount }
        headline = ordered.last { !$0.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.headline ?? ""
    }
}
