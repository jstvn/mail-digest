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

/// Where an info card's "Save to Notes" stands.
enum NotesSaveState: Equatable {
    case idle, saving, saved
    case failed(String)
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
    /// Nil unless Reminders access is fully granted; "Add selected" stays disabled until then.
    private(set) var reminderWriter: (any ReminderWriter)?
    /// Pinned info from earlier digests, newest first; the current digest's own pins stay in its categories.
    private(set) var carriedPins: [PinnedInfo] = []
    /// "Save to Notes" progress per info id.
    private(set) var notesStates: [String: NotesSaveState] = [:]
    /// A sender the user keeps dismissing, offered as an Ignored sender. One at a time.
    private(set) var ignoreSuggestion: IgnoreSuggestion?
    /// Set by `DigestRunModel`; the ignore-rule notice reads and writes the sender lists here.
    @ObservationIgnored var settingsStore: SettingsStore?
    @ObservationIgnored var notesWriter: any NotesWriter = AppleScriptNotesWriter()
    /// Called after approve or dismiss changed what is pending; auto-file uses it to move newly processed mail.
    @ObservationIgnored var onSuggestionsSettled: (@MainActor () async -> Void)?

    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private let clock = SystemClock()
    /// Bumped by every local change so a slow reload can't overwrite newer edits.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var needsReload = false
    /// Addresses the user chose "Not Now" for; forgotten at relaunch.
    @ObservationIgnored private var snoozedSenders: Set<String> = []
    /// The digest whose senders were last checked for ignore suggestions on load.
    @ObservationIgnored private var evaluatedDigestID: UUID?
    @ObservationIgnored var listName: @MainActor () -> String = { DigestSettings.defaultListName }
    static let listIDKey = "remindersListID"
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init() {}

    /// Previews and tests: shows a fixed state without a store.
    init(preview state: ReviewState?, emails: [String: EmailContext] = [:], jobKind: JobKind = .daily,
         writer: (any ReminderWriter)? = nil, carriedPins: [PinnedInfo] = [],
         ignoreSuggestion: IgnoreSuggestion? = nil) {
        self.carriedPins = carriedPins
        self.ignoreSuggestion = ignoreSuggestion
        self.notesWriter = RecordingNotesWriter()
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

    /// Mailbox and Mail row id per email id, from the owning job's items (Q18), for mail actions.
    func locations(for ids: [String]) -> [String: MailLocation] {
        var out: [String: MailLocation] = [:]
        for id in ids {
            if let email = emails[id] { out[id] = MailLocation(mailbox: email.mailbox, storeRowID: email.storeRowID) }
        }
        return out
    }

    func category(for suggestion: Suggestion) -> Category {
        state.map { ReviewActions.category(for: suggestion, in: $0) } ?? .other
    }

    /// `RemindersAccessModel` sets the EventKit writer here when access is granted, and clears it otherwise.
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
                        Self.merge(try await store.items(job: latest.id), into: &context)
                    }
                    if let job = try await store.jobs().first(where: { $0.id == latest.id }) { kind = job.kind }
                }
                // Pins from other digests; an email already in the current digest shows there instead.
                let currentEmails = Set(latest?.info.map(\.emailID) ?? [])
                let carried = try await store.pinnedInfo().filter {
                    $0.digestID != latest?.id && !currentEmails.contains($0.item.emailID)
                }
                // Sender and subject for carried items come from their own job's items (Q18).
                for digestID in Set(carried.filter({ context[$0.item.emailID] == nil }).map(\.digestID)) {
                    Self.merge(try await store.items(job: digestID), into: &context)
                }
                guard startedAt == generation else { needsReload = true; continue }
                if let latest {
                    state = state.map { $0.digest.id == latest.id ? $0.refreshed(with: latest) : ReviewState(digest: latest) }
                        ?? ReviewState(digest: latest)
                } else {
                    state = nil
                }
                emails = context
                carriedPins = carried
                jobKind = kind
                isLoaded = true
                if let latest, evaluatedDigestID != latest.id {
                    evaluatedDigestID = latest.id
                    await evaluateIgnoreSuggestions(senders: Set(latest.suggestions.compactMap { context[$0.emailID]?.sender }))
                }
            } catch {
                Self.log.error("could not load digest: \(String(describing: error), privacy: .public)")
                message = "Could not load the latest digest."
                isLoaded = true
            }
        } while needsReload
    }

    /// Adds job items' sender/subject/mailbox to the lookup; the first item for an email wins.
    private static func merge(_ items: [JobItem], into context: inout [String: EmailContext]) {
        for item in items where context[item.messageID] == nil {
            context[item.messageID] = EmailContext(sender: item.sender, subject: item.subject, mailbox: item.mailbox,
                                                   receivedAt: item.receivedAt, storeRowID: item.storeRowID)
        }
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
        await onSuggestionsSettled?()
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
            await evaluateIgnoreSuggestions(senders: Set(suggestions.compactMap { emails[$0.emailID]?.sender }))
            await onSuggestionsSettled?()
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

    // MARK: Pinned info and Notes

    /// Pins or unpins one info item and saves it. Unpinning an item carried over from an older digest removes it
    /// from the panel.
    func setPinned(_ pinned: Bool, item: InfoItem) async {
        guard let store, let digestID = owningDigestID(of: item) else { return }
        generation += 1
        do {
            try await store.setPinned(pinned, infoID: item.id, digestID: digestID)
        } catch {
            Self.log.error("could not save pin: \(String(describing: error), privacy: .public)")
            message = "Could not save the pin."
            return
        }
        generation += 1
        if state?.digest.id == digestID, let i = state?.digest.info.firstIndex(where: { $0.id == item.id }) {
            state?.digest.info[i].pinned = pinned
        } else if let i = carriedPins.firstIndex(where: { $0.digestID == digestID && $0.item.id == item.id }) {
            if pinned { carriedPins[i].item.pinned = true } else { carriedPins.remove(at: i) }
        }
        message = nil
    }

    private func owningDigestID(of item: InfoItem) -> UUID? {
        if let state, state.digest.info.contains(where: { $0.id == item.id }) { return state.digest.id }
        return carriedPins.first { $0.item.id == item.id }?.digestID
    }

    /// "Save to Notes": runs only from a click. Logs success or failure, never the text.
    func saveToNotes(_ item: InfoItem) async {
        guard notesStates[item.id] != .saving else { return }
        let date: Date
        if let state, state.digest.info.contains(where: { $0.id == item.id }) {
            date = state.digest.createdAt
        } else {
            date = carriedPins.first { $0.item.id == item.id }?.digestCreatedAt ?? clock.now()
        }
        let entry = NotesEntry.make(for: item, email: emails[item.emailID], date: date)
        notesStates[item.id] = .saving
        do {
            try await notesWriter.append(entry)
            Self.log.notice("save to notes: succeeded")
            notesStates[item.id] = .saved
            try? await Task.sleep(for: .seconds(3))
            if notesStates[item.id] == .saved { notesStates[item.id] = nil }
        } catch {
            Self.log.error("save to notes: failed")
            notesStates[item.id] = .failed(Self.notesMessage(for: error))
        }
    }

    private static func notesMessage(for error: Error) -> String {
        switch error as? OsascriptError {
        case .automationDenied:
            return "Notes access is turned off. Allow Mail Digest to control Notes in System Settings > Privacy & Security > Automation."
        case .timedOut:
            return "Notes did not respond. Try again."
        default:
            return "Could not save to Notes."
        }
    }

    // MARK: Learned ignore rules

    /// Checks these senders' dismissals and shows the first match, unless a notice is already showing.
    private func evaluateIgnoreSuggestions(senders: Set<String>) async {
        guard let store, let settings = settingsStore?.settings, ignoreSuggestion == nil else { return }
        for sender in Set(senders.map(MailFilter.address(from:))).subtracting(snoozedSenders).sorted() {
            guard let decisions = try? await store.decisions(for: sender),
                  let found = IgnoreRuleSuggester.suggestion(for: sender, decisions: decisions, settings: settings)
            else { continue }
            ignoreSuggestion = found
            return
        }
    }

    /// A name for the suggested sender: the display name when this digest knows one, otherwise the address.
    var ignoreSuggestionName: String? {
        guard let suggestion = ignoreSuggestion else { return nil }
        let match = emails.values.first { MailFilter.address(from: $0.sender) == suggestion.sender }
        return match.map { ReviewPresentation.senderName($0.sender) } ?? suggestion.sender
    }

    /// "Ignore Sender": the only path that adds to the Ignored list.
    func acceptIgnoreSuggestion() {
        guard let suggestion = ignoreSuggestion, let store = settingsStore else { return }
        if !store.settings.ignoredSenders.contains(where: { MailFilter.address(from: $0) == suggestion.sender }) {
            store.settings.ignoredSenders.append(suggestion.sender)
        }
        ignoreSuggestion = nil
    }

    /// "Not Now": hides the notice until the app is relaunched.
    func snoozeIgnoreSuggestion() {
        if let suggestion = ignoreSuggestion { snoozedSenders.insert(suggestion.sender) }
        ignoreSuggestion = nil
    }

    /// "Don't Ask Again": remembers the sender so it is never suggested again.
    func declineIgnoreSuggestion() {
        guard let suggestion = ignoreSuggestion, let store = settingsStore else { return }
        if !store.settings.declinedIgnoreSuggestions.contains(suggestion.sender) {
            store.settings.declinedIgnoreSuggestions.append(suggestion.sender)
        }
        ignoreSuggestion = nil
    }
}
