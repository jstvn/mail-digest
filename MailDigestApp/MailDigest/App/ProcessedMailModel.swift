import Foundation
import MailDigestCore
import Observation
import OSLog

/// One email a cleanup could not move, with the reason to show beside it.
struct CleanupFailure: Identifiable, Equatable {
    var id: String
    var title: String
    var reason: String
}

/// The Processed tab's state: which rows are ticked, what has been moved or kept, the Undo history and
/// auto-file. Mail work goes through `MailCleanup` / `MailActions`; nothing here touches mail except from
/// a click (or, when the user turned it on, auto-file, which only moves into the "Mail Digest" folder).
@MainActor @Observable
final class ProcessedMailModel {
    /// Rows the user unticked; every other row counts as ticked (the default).
    private(set) var unticked: Set<String> = []
    /// Mirrors of the undo ledger, which lives for the app session.
    private(set) var movedIDs: Set<String> = []
    private(set) var hiddenIDs: Set<String> = []
    private(set) var lastBatch: CleanupBatch?
    private(set) var isWorking = false
    /// Emails the latest action could not move.
    private(set) var failures: [CleanupFailure] = []
    /// Emails Undo could not put back; they stay recorded so Undo can be tried again.
    private(set) var undoProblem: String?

    private let review: ReviewViewModel
    private let settings: SettingsStore
    private let cleanup: MailCleanup
    private let ledger = UndoLedger()
    private let selector = ProcessedEmailSelector()
    /// Emails auto-file already tried or the user undid: never moved automatically again this session.
    @ObservationIgnored private var autoFileSkipped: Set<String> = []
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "cleanup")

    init(review: ReviewViewModel, settings: SettingsStore, actions: (any MailActions)? = nil) {
        self.review = review
        self.settings = settings
        let actions = actions ?? AppleScriptMailActions(locate: { ids in await review.locations(for: ids) })
        self.cleanup = MailCleanup(actions: actions)
    }

    // MARK: Derived

    /// Eligible emails, minus anything moved or kept this session.
    var processed: ProcessedEmails {
        guard let digest = review.digest else { return ProcessedEmails(handled: [], blocked: []) }
        return selector.entries(digest: digest, emails: review.emails, excluding: movedIDs.union(hiddenIDs))
    }

    var allEntries: [ProcessedEntry] { processed.handled + processed.blocked }
    var groupedHandled: [ProcessedAccountGroup] { selector.grouped(processed.handled) }
    var groupedBlocked: [ProcessedAccountGroup] { selector.grouped(processed.blocked) }
    var hasNewsletters: Bool { !selector.newsletterIDs(allEntries).isEmpty }

    func isTicked(_ id: String) -> Bool { !unticked.contains(id) }
    var tickedIDs: [String] { allEntries.map(\.id).filter(isTicked) }
    var tickedCount: Int { tickedIDs.count }
    var canAct: Bool { tickedCount > 0 && !isWorking }
    var needsAutomationAccess: Bool { failures.contains { $0.reason == MailActionFailure.automationDenied } }

    // MARK: Selection

    func setTicked(_ ticked: Bool, id: String) {
        if ticked { unticked.remove(id) } else { unticked.insert(id) }
    }

    func selectAll() { unticked = [] }

    func selectNone() { unticked = Set(allEntries.map(\.id)) }

    /// "Select all newsletters": ticks exactly the newsletter rows.
    func selectNewsletters() {
        let newsletters = selector.newsletterIDs(allEntries)
        unticked = Set(allEntries.map(\.id)).subtracting(newsletters)
    }

    // MARK: Actions (only from a click)

    func moveToTrash() async { await perform(.trash, ids: tickedIDs) }

    func moveToDigestFolder() async { await perform(.moveToFolder(MailCleanup.digestFolderName), ids: tickedIDs) }

    /// Keep: hides the ticked rows and leaves the mail alone.
    func keep() async {
        let ids = tickedIDs
        guard !ids.isEmpty, !isWorking else { return }
        await ledger.hide(ids)
        unticked.subtract(ids)
        await refreshLedger()
    }

    /// Undo for the latest batch: puts its emails back in their original mailboxes.
    func undo() async {
        guard let batch = lastBatch, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        _ = await ledger.take(batch.id)
        undoProblem = nil
        var failedIDs: Set<String> = []
        do {
            try await cleanup.undo(batch)
        } catch MailActionError.restoreFailed(let failed) {
            failedIDs = Set(failed.map(\.messageID))
            let reasons = Set(failed.map { MailActionFailure.explanation(for: $0.reason) }).sorted()
            let noun = failed.count == 1 ? "email" : "emails"
            undoProblem = "\(failed.count) \(noun) couldn't be moved back. \(reasons.joined(separator: " ")) Check the \(Self.place(batch.action)) in Mail."
        } catch {
            // Cancelled before it finished: keep the batch so Undo can be tried again.
            failedIDs = Set(batch.results.filter(\.succeeded).map(\.messageID))
        }
        // What could not be restored is still where it was moved to, so it stays recorded for another try.
        let remaining = batch.results.filter { $0.succeeded && failedIDs.contains($0.messageID) }
        if !remaining.isEmpty { await ledger.record(CleanupBatch(id: batch.id, action: batch.action, results: remaining)) }
        // An email the user put back is never auto-filed again this session.
        autoFileSkipped.formUnion(batch.results.filter(\.succeeded).map(\.messageID))
        failures = []
        await refreshLedger()
    }

    /// Auto-file (a setting, off by default): after a run or a decision, files newly processed emails into
    /// "Mail Digest" in their own account. Never trashes, never touches kept, moved or already-tried emails.
    func autoFileIfEnabled() async {
        guard settings.settings.autoFileProcessed, !isWorking else { return }
        let ids = selector.autoFileIDs(processed(excluding: autoFileSkipped))
        guard !ids.isEmpty else { return }
        autoFileSkipped.formUnion(ids)
        Self.log.notice("auto-file starting: candidates=\(ids.count, privacy: .public)")
        await perform(.moveToFolder(MailCleanup.digestFolderName), ids: ids)
    }

    private func processed(excluding extra: Set<String>) -> ProcessedEmails {
        guard let digest = review.digest else { return ProcessedEmails(handled: [], blocked: []) }
        return selector.entries(digest: digest, emails: review.emails,
                                excluding: movedIDs.union(hiddenIDs).union(extra))
    }

    func dismissFailures() { failures = [] }

    private func perform(_ action: CleanupAction, ids: [String]) async {
        guard !ids.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        failures = []
        undoProblem = nil
        do {
            let batch = try await cleanup.perform(action, ids: ids)
            // Nothing succeeded means nothing to undo, so no toast; the failures are listed instead.
            if batch.results.contains(where: \.succeeded) { await ledger.record(batch) }
            failures = batch.results.filter { !$0.succeeded }.map { result in
                let email = review.emails[result.messageID]
                let title = email.map { "\(ReviewPresentation.senderName($0.sender)) · \($0.subject)" } ?? "An email"
                return CleanupFailure(id: result.messageID, title: title, reason: result.error ?? "Unknown problem")
            }
            let done = batch.results.filter(\.succeeded).count
            Self.log.notice("cleanup finished: requested=\(ids.count, privacy: .public) moved=\(done, privacy: .public) failed=\(ids.count - done, privacy: .public)")
        } catch {
            Self.log.error("cleanup cancelled")
        }
        await refreshLedger()
    }

    private func refreshLedger() async {
        movedIDs = await ledger.movedIDs
        hiddenIDs = await ledger.hiddenIDs
        lastBatch = await ledger.lastBatch
    }

    private static func place(_ action: CleanupAction) -> String {
        switch action {
        case .trash: return "Trash"
        case .moveToFolder(let name): return "\(name) folder"
        }
    }
}
