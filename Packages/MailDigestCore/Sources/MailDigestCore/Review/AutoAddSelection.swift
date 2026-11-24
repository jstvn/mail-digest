import Foundation

/// Which suggestions the "Add Suggested Reminders Automatically" setting approves (Q101).
public enum AutoAddSelection {
    /// The pending, preselected suggestions of the digest a finished Daily job created, as records ready for
    /// `ReviewActions.approve`. Backlog jobs, other digests (carry-over), and suggestions that are failed,
    /// approved, dismissed or not preselected (every `money-new-sender` item) are never returned.
    /// - Parameters:
    ///   - digest: the digest whose id equals the job's id.
    ///   - items: the job's queue items, which supply each email's sender, subject and mailbox.
    public static func candidates(digest: Digest, jobKind: JobKind, items: [JobItem]) -> [SuggestionRecord] {
        guard jobKind == .daily else { return [] }
        let emails = Dictionary(items.map { ($0.messageID, EmailContext(item: $0)) }, uniquingKeysWith: { first, _ in first })
        return digest.suggestions
            .filter { $0.status == .pending && $0.preselected }
            .map { s in
                SuggestionRecord(suggestion: s, digestID: digest.id, digestCreatedAt: digest.createdAt, kind: jobKind,
                                 category: ReviewActions.category(for: s, info: digest.info), email: emails[s.emailID])
            }
    }
}
