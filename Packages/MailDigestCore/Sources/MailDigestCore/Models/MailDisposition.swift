import Foundation

/// What the app has done with a processed email, persisted with its owning digest (Q39, Q42).
public enum MailDispositionKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Moved to Trash or the Mail Digest folder by a cleanup that succeeded. Cleared by a successful Undo.
    case moved
    /// Hidden from Processed with Keep; the mail itself was not touched. Not undoable.
    case kept
    /// Auto-file must not move this email (again): it already tried, or Undo restored the email.
    case autoFileAttempted
}

/// One disposition record, keyed by (digest, email, kind).
public struct MailDisposition: Codable, Sendable, Equatable, Hashable {
    public var digestID: UUID
    public var emailID: String
    public var kind: MailDispositionKind
    public var recordedAt: Date

    public init(digestID: UUID, emailID: String, kind: MailDispositionKind, recordedAt: Date) {
        self.digestID = digestID
        self.emailID = emailID
        self.kind = kind
        self.recordedAt = recordedAt
    }
}

/// A digest's dispositions grouped for the Processed list and auto-file.
public struct MailDispositions: Sendable, Equatable {
    public var moved: Set<String>
    public var kept: Set<String>
    public var autoFileAttempted: Set<String>

    public init(moved: Set<String> = [], kept: Set<String> = [], autoFileAttempted: Set<String> = []) {
        self.moved = moved
        self.kept = kept
        self.autoFileAttempted = autoFileAttempted
    }

    public init(_ records: [MailDisposition]) {
        self.init()
        for r in records {
            switch r.kind {
            case .moved: moved.insert(r.emailID)
            case .kept: kept.insert(r.emailID)
            case .autoFileAttempted: autoFileAttempted.insert(r.emailID)
            }
        }
    }

    /// Emails the Processed list no longer shows: moved or kept.
    public var hidden: Set<String> { moved.union(kept) }
}
