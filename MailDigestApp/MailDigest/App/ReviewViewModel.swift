import Foundation
import MailDigestCore
import Observation
import OSLog

/// What the review panel body shows (banners and the progress strip are layered on top of it).
enum ReviewPanelState: Equatable {
    case loading
    /// No digest exists yet.
    case neverRun
    /// The last run found no new mail.
    case noNewMail(lastRun: Date?)
    case digest
}

/// Owns the digest being reviewed and the user's selection. Store work happens off the main actor;
/// the pure decisions live in `ReviewActions` and `ReviewPresentation` (core).
@MainActor @Observable
final class ReviewViewModel {
    private(set) var state: ReviewState?
    /// Sender, subject and mailbox per email id, from the job's `job_item` rows.
    private(set) var emails: [String: EmailContext] = [:]
    private(set) var jobKind: JobKind = .daily
    private(set) var isLoaded = false
    private(set) var isWorking = false
    /// Latest user-facing problem from an approve, dismiss or edit; cleared by the next successful action.
    private(set) var message: String?
    /// Daily shows the top 25 first (Q16); this reveals the rest.
    var showAllSuggestions = false
    /// Nil until T14 provides the EventKit writer; "Add selected" stays disabled until then.
    private(set) var reminderWriter: (any ReminderWriter)?

    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private let clock = SystemClock()
    /// Bumped by every local change so a slow reload can't overwrite newer edits.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored var listName: @MainActor () -> String = { DigestSettings.defaultListName }
    private static let listIDKey = "remindersListID"
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init() {}

    /// Previews and tests: shows a fixed state without a store.
    init(preview state: ReviewState?, emails: [String: EmailContext] = [:], jobKind: JobKind = .daily,
         writer: (any ReminderWriter)? = nil) {
        self.state = state
        self.emails = emails
        self.jobKind = jobKind
        self.reminderWriter = writer
        self.isLoaded = true
    }

    // MARK: Derived

    var digest: Digest? { state?.digest }
    var actionable: [Suggestion] { ReviewPresentation.actionable(state?.digest.suggestions ?? []) }
    var pendingCount: Int { ReviewPresentation.pendingCount(state?.digest) }
    var selectedCount: Int {
        guard let state else { return 0 }
        return ReviewActions.split(state).approve.count
    }
    var unselectedCount: Int {
        guard let state else { return 0 }
        return ReviewActions.split(state).dismiss.count
    }
    var canAddSelected: Bool { reminderWriter != nil && selectedCount > 0 && !isWorking }

    /// Q16: Daily shows 25 first; a Backlog has no digest-wide cap.
    var page: SuggestionPage {
        ReviewPresentation.page(actionable, limit: jobKind == .daily ? 25 : nil, showAll: showAllSuggestions)
    }

    func category(for suggestion: Suggestion) -> Category {
        state.map { ReviewActions.category(for: suggestion, in: $0) } ?? .other
    }

    /// T14 injects the EventKit writer here; nothing else changes.
    func setReminderWriter(_ writer: (any ReminderWriter)?) { reminderWriter = writer }

    // MARK: Loading

    /// Connects the store and loads the latest digest.
    func attach(store: any DigestStore) async {
        self.store = store
        await reload()
    }

    /// Loads the latest digest. Safe to call often (a running job calls it as results arrive): overlapping
    /// calls coalesce, and a result that raced with a local edit is discarded and reloaded.
    func reload() async {
        guard let store else { return }
        if isReloading { needsReload = true; return }
        isReloading = true
        defer { isReloading = false }
        repeat {
            needsReload = false
            let startedAt = generation
            do {
                let latest = try await store.latestDigest()
                var kind = jobKind
                var context = emails
                if let latest {
                    let ids = Set(latest.info.map(\.emailID) + latest.suggestions.map(\.emailID))
                    if !ids.isSubset(of: context.keys) {
                        let items = try await store.items(job: latest.id)
                        context = Dictionary(items.map { ($0.messageID, EmailContext(sender: $0.sender, subject: $0.subject, mailbox: $0.mailbox)) },
                                             uniquingKeysWith: { first, _ in first })
                    }
                    if let job = try await store.jobs().first(where: { $0.id == latest.id }) { kind = job.kind }
                }
                guard startedAt == generation else { needsReload = true; continue }
                if let latest {
                    state = state.map { $0.digest.id == latest.id ? $0.refreshed(with: latest) : ReviewState(digest: latest) }
                        ?? ReviewState(digest: latest)
                } else {
                    state = nil
                }
                emails = context
                jobKind = kind
                isLoaded = true
            } catch {
                Self.log.error("could not load digest: \(String(describing: error), privacy: .public)")
                message = "Could not load the latest digest."
                isLoaded = true
            }
        } while needsReload
    }

    // MARK: Selection

    func toggle(_ id: UUID) { mutate { ReviewActions.toggle(id, in: $0) } }
    func selectAll() { mutate { ReviewActions.selectAll($0) } }
    func selectNone() { mutate { ReviewActions.selectNone($0) } }

    private func mutate(_ change: (ReviewState) -> ReviewState) {
        guard let state else { return }
        self.state = change(state)
        generation += 1
    }

    // MARK: Editing

    /// Applies and persists an edit (title, due, priority, category). Throws `ReviewError` for a bad edit,
    /// in which case nothing changes and the caller reverts its field.
    func edit(_ edit: SuggestionEdit, id: UUID) async throws {
        guard let state, let store else { throw ReviewError.unknownSuggestion }
        generation += 1
        let updated = try await ReviewActions.edit(edit, id: id, state: state, store: store)
        // Keep selection changes made while the write was in flight.
        guard var current = self.state else { return }
        if let sug = updated.digest.suggestions.first(where: { $0.id == id }),
           let i = current.digest.suggestions.firstIndex(where: { $0.id == id }) {
            current.digest.suggestions[i] = sug
        }
        self.state = current
        generation += 1
        message = nil
    }

    // MARK: Approve and dismiss

    /// "Add selected": writes the selected suggestions to Reminders. Does nothing without a writer.
    func addSelected() async {
        guard let state, let store, let writer = reminderWriter, !isWorking else { return }
        let toAdd = ReviewActions.split(state).approve
        guard !toAdd.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome = await ReviewActions.approve(
            toAdd, state: state, emails: emails, writer: writer, store: store, listName: listName(),
            storedListID: UserDefaults.standard.string(forKey: Self.listIDKey), clock: clock)
        if let id = outcome.listID { UserDefaults.standard.set(id, forKey: Self.listIDKey) }
        apply(outcome)
        let failed = outcome.results.filter { $0.status == .failed }.count
        message = failed == 0 ? nil : "\(failed) \(failed == 1 ? "reminder" : "reminders") couldn't be added. They stay selected so you can try again."
    }

    /// "Dismiss unselected".
    func dismissUnselected() async {
        guard let state else { return }
        await dismiss(ReviewActions.split(state).dismiss)
    }

    /// ⌫ on a focused row.
    func dismiss(id: UUID) async {
        guard let sug = state?.digest.suggestions.first(where: { $0.id == id }), sug.status == .pending else { return }
        await dismiss([sug])
    }

    private func dismiss(_ suggestions: [Suggestion]) async {
        guard let state, let store, !suggestions.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await ReviewActions.dismiss(suggestions, state: state, emails: emails, store: store, clock: clock))
            message = nil
        } catch {
            message = "Could not dismiss those suggestions."
            await reload()
        }
    }

    private func apply(_ outcome: ApprovalOutcome) {
        guard let current = state else { return }
        state = ReviewActions.merge(outcome.results, into: current)
        generation += 1
    }
}
