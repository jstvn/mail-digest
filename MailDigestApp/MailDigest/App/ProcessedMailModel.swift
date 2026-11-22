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
/// a click (or, when the user turned it on, auto-file, which moves to the Mail Digest folder or Trash per Q94).
///
/// Successful moves and Keeps are persisted per digest (Q39), so those rows stay hidden after a relaunch;
/// the Undo history itself lasts for the app session, as the spec says.
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
    /// Moved, kept and auto-file-attempted emails of the shown digest, as stored.
    private(set) var persisted = MailDispositions()

    private let review: ReviewViewModel
    private let settings: SettingsStore
    private let cleanup: MailCleanup
    private let ledger = UndoLedger()
    private let selector = ProcessedEmailSelector()
    /// Emails auto-file already tried or the user undid: never moved automatically again. Mirrors the
    /// persisted `autoFileAttempted` records, and covers a failed write of them.
    @ObservationIgnored private var autoFileSkipped: Set<String> = []
    /// The digest each recorded cleanup batch belongs to, so Undo clears the right records.
    @ObservationIgnored private var batchDigests: [UUID: UUID] = [:]
    /// Auto-file was asked for while another action was running; it runs again once that finishes.
    @ObservationIgnored private var autoFilePending = false
    /// One auto-file pass at a time; progress updates can ask for several in quick succession.
    @ObservationIgnored private var autoFileRunning = false
    @ObservationIgnored private var store: (any DigestStore)?
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "cleanup")

    init(review: ReviewViewModel, settings: SettingsStore, actions: (any MailActions)? = nil) {
        self.review = review
        self.settings = settings
        let actions = actions ?? AppleScriptMailActions(locate: { ids in await review.locations(for: ids) })
        self.cleanup = MailCleanup(actions: actions)
    }

    /// Uses the app's database for moved/kept records and reloads them for the shown digest.
    func attach(store: any DigestStore) async {
        self.store = store
        await reloadDispositions()
    }

    /// Call after the review panel reloads: picks up the shown digest's records, then auto-files any
    /// newly finished results (Q42).
    func refresh() async {
        await reloadDispositions()
        await autoFileIfEnabled()
    }

    private func reloadDispositions() async {
        guard let store, let digest = review.digest else { persisted = MailDispositions(); return }
        do {
            persisted = MailDispositions(try await store.dispositions(digestID: digest.id))
            autoFileSkipped.formUnion(persisted.autoFileAttempted)
        } catch {
            Self.log.error("could not read moved/kept records")
        }
    }

    // MARK: Derived

    /// Eligible emails, minus anything moved or kept (this session or recorded earlier).
    var processed: ProcessedEmails {
        guard let digest = review.digest else { return ProcessedEmails(handled: [], blocked: []) }
        return selector.entries(digest: digest, emails: review.emails, excluding: excludedIDs)
    }

    private var excludedIDs: Set<String> { movedIDs.union(hiddenIDs).union(persisted.hidden) }

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
        await record(.kept, ids: ids, digestID: review.digest?.id)
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
        // Only emails actually put back lose their "moved" record (Q39), and they are never auto-filed again (Q42).
        let restored = batch.results.filter { $0.succeeded && !failedIDs.contains($0.messageID) }.map(\.messageID)
        let digestID = remaining.isEmpty ? batchDigests.removeValue(forKey: batch.id) : batchDigests[batch.id]
        autoFileSkipped.formUnion(restored)
        if let store, let digestID, !restored.isEmpty {
            do {
                try await store.removeDispositions(.moved, emailIDs: Set(restored), digestID: digestID)
            } catch {
                Self.log.error("could not clear moved records after Undo")
            }
            await record(.autoFileAttempted, ids: restored, digestID: digestID)
        }
        failures = []
        await reloadDispositions()
        await refreshLedger()
    }

    /// Auto-file (a setting, off by default, Q42): files each email of the shown digest into "Mail Digest" or
    /// Trash (Q94, per the two destination settings) in its own account as soon as its result is persisted and it is fully processed, including while the
    /// job still runs. Only results finished after the setting was switched on qualify, so older mail is
    /// never swept. Each email is tried once: the attempt is stored before the move, so a relaunch or a
    /// failure never repeats it. A failed move is never retried or redirected. Never touches kept, moved or undone emails.
    func autoFileIfEnabled() async {
        guard !autoFileRunning, !isWorking else { autoFilePending = true; return }
        autoFileRunning = true
        defer { autoFileRunning = false }
        repeat {
            autoFilePending = false
            await autoFileOnce()
        } while autoFilePending
    }

    private func autoFileOnce() async {
        let s = settings.settings
        guard s.autoFileProcessed, let enabledAt = s.autoFileEnabledAt, let store else { return }
        guard let digest = review.digest else { return }
        let finishedAt: [String: Date]
        do {
            finishedAt = Dictionary(try await store.items(job: digest.id).compactMap { item in
                item.finishedAt.map { (item.messageID, $0) }
            }, uniquingKeysWith: { first, _ in first })
        } catch {
            Self.log.error("auto-file could not read the job's items")
            return
        }
        var skip = persisted
        skip.moved.formUnion(movedIDs)
        skip.kept.formUnion(hiddenIDs)
        skip.autoFileAttempted.formUnion(autoFileSkipped)
        let ids = selector.autoFileIDs(digest: digest, emails: review.emails, dispositions: skip,
                                       finishedAt: finishedAt, enabledAt: enabledAt)
        guard !ids.isEmpty, review.digest?.id == digest.id else { return }
        // A click may have started an action meanwhile; try again when it finishes.
        guard !isWorking else { autoFilePending = true; return }
        // Hold the lock from here, so the ids marked as tried below are the ones actually moved.
        isWorking = true
        autoFileSkipped.formUnion(ids)
        // Persist the attempt first: if this can't be stored, don't move anything, or a relaunch could repeat it.
        guard await record(.autoFileAttempted, ids: ids, digestID: digest.id) else { isWorking = false; return }
        Self.log.notice("auto-file starting: candidates=\(ids.count, privacy: .public)")
        let action = selector.autoFileAction(ids: ids, digest: digest, handled: s.autoFileHandledDestination,
                                             dismissed: s.autoFileDismissedDestination)
        await performLocked(action, ids: ids)
    }

    func dismissFailures() { failures = [] }

    private func perform(_ action: CleanupAction, ids: [String]) async {
        guard !ids.isEmpty, !isWorking else { return }
        isWorking = true
        await performLocked(action, ids: ids)
    }

    /// The cleanup itself; the caller has set `isWorking`, which this clears when done.
    private func performLocked(_ action: CleanupAction, ids: [String]) async {
        failures = []
        undoProblem = nil
        let digestID = review.digest?.id
        do {
            let batch = try await cleanup.perform(action, ids: ids)
            // Nothing succeeded means nothing to undo, so no toast; the failures are listed instead.
            let moved = batch.results.filter(\.succeeded).map(\.messageID)
            if !moved.isEmpty {
                await ledger.record(batch)
                batchDigests[batch.id] = digestID
                // Only a confirmed move is recorded; "not found" and other failures never are (Q39).
                await record(.moved, ids: moved, digestID: digestID)
            }
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
        isWorking = false
        // Results that finished during a click's action are filed now rather than at the next trigger. (Within
        // an auto-file pass, its own loop picks the request up.)
        if autoFilePending, !autoFileRunning { await autoFileIfEnabled() }
    }

    /// Stores dispositions for the given emails of a digest. Returns false (and logs) if it could not.
    @discardableResult
    private func record(_ kind: MailDispositionKind, ids: [String], digestID: UUID?) async -> Bool {
        guard !ids.isEmpty else { return true }
        guard let store, let digestID else { return false }
        let now = Date()
        do {
            try await store.recordDispositions(ids.map {
                MailDisposition(digestID: digestID, emailID: $0, kind: kind, recordedAt: now)
            })
            if review.digest?.id == digestID {
                switch kind {
                case .moved: persisted.moved.formUnion(ids)
                case .kept: persisted.kept.formUnion(ids)
                case .autoFileAttempted: persisted.autoFileAttempted.formUnion(ids)
                }
            }
            return true
        } catch {
            Self.log.error("could not store \(kind.rawValue, privacy: .public) records")
            return false
        }
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
        case .split(let folder, _): return "Trash or \(folder) folder"
        }
    }
}
