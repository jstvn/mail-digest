import Foundation

/// Everything a resume changes in a job's queue, applied by `DigestStore.applyResumeRefresh` in one
/// atomic step so a failure part-way never leaves a half-refreshed queue.
public struct QueueRefresh: Sendable, Equatable {
    /// An open item that now lives in another selected mailbox.
    public struct Relocation: Sendable, Equatable {
        public var itemID: UUID
        public var mailbox: MailboxRef
        /// Replaces the old locator hint (nil clears it).
        public var storeRowID: Int64?

        public init(itemID: UUID, mailbox: MailboxRef, storeRowID: Int64?) {
            self.itemID = itemID
            self.mailbox = mailbox
            self.storeRowID = storeRowID
        }
    }

    public var jobID: UUID
    /// Open items whose mail is gone: marked skipped with `skipOutcome`, no attempt, no error.
    public var skippedItemIDs: [UUID]
    public var skipOutcome: String
    public var skippedAt: Date
    public var relocations: [Relocation]
    /// Newly discovered mail, appended after the job's last item.
    public var appended: [MessageHeader]
    /// The job's new scope end (Daily discovery); nil leaves the scope as it is.
    public var scopeTo: Date?

    public init(jobID: UUID, skippedItemIDs: [UUID] = [], skipOutcome: String = "", skippedAt: Date = .distantPast,
                relocations: [Relocation] = [], appended: [MessageHeader] = [], scopeTo: Date? = nil) {
        self.jobID = jobID
        self.skippedItemIDs = skippedItemIDs
        self.skipOutcome = skipOutcome
        self.skippedAt = skippedAt
        self.relocations = relocations
        self.appended = appended
        self.scopeTo = scopeTo
    }

    /// True when applying it would change nothing.
    public var isEmpty: Bool {
        skippedItemIDs.isEmpty && relocations.isEmpty && appended.isEmpty && scopeTo == nil
    }
}
