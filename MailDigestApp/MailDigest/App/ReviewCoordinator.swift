import Foundation
import MailDigestCore
import Observation
import OSLog

/// The cross-digest review state shared by every canvas (Q54): the sidebar selection, one `ReviewSession`
/// so ticks survive navigation, the canvas models (each loads only while shown) and the triage actions.
/// Approve, dismiss and edit go through the record-based `ReviewActions`, so each suggestion is written,
/// recorded and persisted against its own digest.
@MainActor @Observable
final class ReviewCoordinator {
    let library: ReviewLibrary
    let today: TodayCanvasModel
    let day: DayCanvasModel
    let backlog: BacklogCanvasModel
    let reviewQueue: PagedRecordsModel
    let logbook: PagedRecordsModel
    let activity: ActivityModel
    /// Shared with the latest-digest panel, so there is one notice and one Notes progress.
    @ObservationIgnored let notes: NotesSaver
    @ObservationIgnored let ignore: IgnoreSuggestionModel

    /// The sidebar selection; Today by default.
    private(set) var selection: SidebarItem = .today
    /// Session-wide checkbox state across digests.
    private(set) var session = ReviewSession()
    private(set) var isWorking = false
    /// Latest user-facing problem from an action; cleared by the next successful one.
    private(set) var message: String?
    /// Nil unless Reminders access is fully granted; "Add to Reminders" stays disabled until then.
    private(set) var reminderWriter: (any ReminderWriter)?
    /// The email a job popover asked to show; the canvas scrolls to it, then calls `clearReveal()`.
    private(set) var revealedEmailID: String?

    @ObservationIgnored private weak var review: ReviewViewModel?
    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private let clock = SystemClock()
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init(library: ReviewLibrary, review: ReviewViewModel) {
        self.library = library
        self.review = review
        self.today = TodayCanvasModel()
        self.day = DayCanvasModel()
        self.backlog = BacklogCanvasModel()
        self.reviewQueue = PagedRecordsModel(pageSize: 50)
        self.logbook = PagedRecordsModel(pageSize: 50)
        self.activity = ActivityModel()
        self.notes = review.notes
        self.ignore = review.ignore
        library.onDayChanged = { [weak self] in await self?.loadSelected() }
    }

    /// Previews: fixed models, no store.
    init(preview library: ReviewLibrary, review: ReviewViewModel, today: TodayCanvasModel = TodayCanvasModel(),
         day: DayCanvasModel = DayCanvasModel(), backlog: BacklogCanvasModel = BacklogCanvasModel(),
         reviewQueue: PagedRecordsModel = PagedRecordsModel(pageSize: 50),
         logbook: PagedRecordsModel = PagedRecordsModel(pageSize: 50),
         activity: ActivityModel = ActivityModel(),
         selection: SidebarItem = .today, writer: (any ReminderWriter)? = nil) {
        self.library = library
        self.review = review
        self.today = today
        self.day = day
        self.backlog = backlog
        self.reviewQueue = reviewQueue
        self.logbook = logbook
        self.activity = activity
        self.notes = review.notes
        self.ignore = review.ignore
        self.selection = selection
        self.reminderWriter = writer
    }

    /// A coordinator over an empty archive and no store, for previews that do not care about the library.
    static func empty(review: ReviewViewModel) -> ReviewCoordinator {
        let calendar = Calendar(identifier: .gregorian)
        let archive = DigestArchive(summaries: [], now: Date(), calendar: calendar)
        return ReviewCoordinator(preview: ReviewLibrary(preview: archive, calendar: calendar), review: review)
    }

    /// `RemindersAccessModel` sets the EventKit writer here when access is granted, and clears it otherwise.
    func setReminderWriter(_ writer: (any ReminderWriter)?) { reminderWriter = writer }

    // MARK: Loading

    /// Connects the store and loads the sidebar and the selected canvas.
    func attach(store: any DigestStore) async {
        self.store = store
        await library.attach(store: store)
        await loadSelected()
    }

    /// Changes the sidebar selection and loads that canvas. Only the selected canvas ever loads.
    func select(_ item: SidebarItem) {
        guard item != selection else { return }
        selection = item
        Task { await loadSelected() }
    }

    /// Loads the selected canvas (coalesced); a stale selection falls back to Today.
    func loadSelected() async {
        guard let store else { return }
        if !library.contains(selection) { selection = .today }
        let archive = library.archive
        let calendar = library.calendar
        switch selection {
        case .today:
            await today.load(digestIDs: archive.todayDigestIDs, startOfToday: archive.startOfToday, store: store, calendar: calendar)
        case .day(let d):
            await day.load(digestIDs: archive.digestIDs(for: d), store: store)
        case .backlog(let id):
            await backlog.load(jobID: id, store: store)
        case .reviewQueue:
            await reviewQueue.load(.reviewQueue, store: store, calendar: calendar)
        case .logbook:
            await logbook.load(.logbook, store: store, calendar: calendar)
        case .activity:
            await activity.load(store: store)
        case .mailCleanup:
            break // Mail Cleanup keeps its latest-digest model (Q55).
        }
    }

    /// The store changed (a result landed, a run ended, history was cleaned): refresh the sidebar and only
    /// the canvas on screen. Called from `ReviewViewModel.onReloaded`, so it follows every existing reload.
    func storeDidChange() async {
        await library.refresh()
        await loadSelected()
    }

    func loadMoreReviewQueue() async { if let store { await reviewQueue.loadMore(store: store) } }
    func loadMoreLogbook() async { if let store { await logbook.loadMore(store: store) } }

    // MARK: Reveal

    /// Shows an email from the job progress popover: Today for a Daily job of today, that day for an older
    /// Daily job, the Backlog entry (and its batch) for a Backlog job. Then publishes the id to scroll to.
    func reveal(emailID: String, jobID: UUID, kind: JobKind) async {
        await library.refresh()
        let target: SidebarItem
        if kind == .backlog {
            target = .backlog(jobID)
        } else if let d = library.archive.day(ofDigest: jobID) {
            target = .day(d)
        } else {
            target = .today
        }
        selection = library.contains(target) ? target : .today
        await loadSelected()
        switch selection {
        case .backlog: backlog.reveal(emailID: emailID)
        case .today: revealInPage(today.digests, emailID: emailID)
        case .day: revealInPage(day, emailID: emailID)
        default: break
        }
        revealedEmailID = emailID
    }

    func clearReveal() { revealedEmailID = nil }

    /// A hidden (Q16) suggestion for this email would not be on screen to scroll to, so show all.
    private func revealInPage(_ model: DayCanvasModel, emailID: String) {
        let visible = Set(model.page.visible.map(\.id))
        if model.actionable.contains(where: { $0.suggestion.emailID == emailID && !visible.contains($0.id) }) {
            model.showAll = true
        }
    }

    // MARK: Selection

    func isSelected(_ record: SuggestionRecord) -> Bool { session.isSelected(record.suggestion) }
    func toggle(_ record: SuggestionRecord) { session.toggle(record.suggestion) }
    func selectAll(_ records: [SuggestionRecord]) { session.selectAll(records) }
    func selectNone(_ records: [SuggestionRecord]) { session.selectNone(records) }
    func selectedCount(in records: [SuggestionRecord]) -> Int { session.selectedCount(in: records) }
    func unselectedCount(in records: [SuggestionRecord]) -> Int { session.unselectedCount(in: records) }
    func canAddSelected(in records: [SuggestionRecord]) -> Bool {
        reminderWriter != nil && selectedCount(in: records) > 0 && !isWorking
    }

    // MARK: Editing

    /// Applies and persists an edit. Throws `ReviewError` for a bad edit, in which case nothing changes and
    /// the caller reverts its field.
    func edit(_ edit: SuggestionEdit, record: SuggestionRecord) async throws {
        guard let store else { throw ReviewError.unknownSuggestion }
        let updated = try await ReviewActions.edit(edit, record: record, store: store)
        patchAll([updated.suggestion])
        message = nil
    }

    // MARK: Approve and dismiss

    /// "Add to Reminders": writes the selected suggestions among `records`. Does nothing without a writer.
    func addSelected(in records: [SuggestionRecord]) async {
        guard let store, let writer = reminderWriter, !isWorking else { return }
        let toAdd = session.recordSplit(records).approve
        guard !toAdd.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome = await ReviewActions.approve(
            toAdd, writer: writer, store: store, listName: review?.listName() ?? DigestSettings.defaultListName,
            storedListID: UserDefaults.standard.string(forKey: ReviewViewModel.listIDKey), clock: clock)
        if let id = outcome.listID { UserDefaults.standard.set(id, forKey: ReviewViewModel.listIDKey) }
        session.apply(outcome.results)
        patchAll(outcome.results)
        let failed = outcome.results.filter { $0.status == .failed }.count
        message = failed == 0 ? nil : "\(failed) \(failed == 1 ? "reminder" : "reminders") couldn't be added. They stay selected so you can try again."
        await settled()
    }

    /// "Try Again" on a failed suggestion: keeps it selected and writes just that one.
    func retry(_ record: SuggestionRecord) async { await add(record) }

    /// Adds exactly this suggestion to Reminders, whether or not its checkbox is ticked (the Review Queue
    /// inspector's Add acts on the selected row, not on the ticked ones).
    func add(_ record: SuggestionRecord) async {
        if !isSelected(record) { toggle(record) }
        await addSelected(in: [record])
    }

    /// The name of the default Reminders list from Settings, for the inspector's List picker.
    var defaultListName: String { review?.listName() ?? DigestSettings.defaultListName }

    /// The stored id of the default list, so the picker doesn't list it twice.
    var defaultListID: String? { UserDefaults.standard.string(forKey: ReviewViewModel.listIDKey) }

    /// How the email behind a record was routed and run, read from its job's items; nil when not recorded.
    /// Only the recorded routing is returned, never a guess.
    func routing(for record: SuggestionRecord) async -> RoutingProvenance? {
        guard let store else { return nil }
        let items = (try? await store.items(job: record.digestID)) ?? []
        return items.first { $0.messageID == record.suggestion.emailID }?.routing
    }

    /// "Dismiss Unselected": the pending, unselected suggestions among `records`.
    func dismissUnselected(in records: [SuggestionRecord]) async {
        await dismiss(session.recordSplit(records).dismiss)
    }

    /// ⌫ on a focused row.
    func dismiss(_ record: SuggestionRecord) async {
        guard record.suggestion.status == .pending else { return }
        await dismiss([record])
    }

    private func dismiss(_ records: [SuggestionRecord]) async {
        guard let store, !records.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await ReviewActions.dismiss(records, store: store, clock: clock)
            session.apply(outcome.results)
            patchAll(outcome.results)
            message = nil
            await ignore.evaluate(senders: Set(records.compactMap { $0.email?.sender }), store: store)
        } catch {
            Self.log.error("could not dismiss: \(String(describing: error), privacy: .public)")
            message = "Could not dismiss those suggestions."
        }
        await settled()
    }

    /// After any action: refresh the sidebar and the shown canvas, let the latest-digest model see the new
    /// statuses (Mail Cleanup, auto-file eligibility), then run the settled hook so auto-file runs (Q42, Q50).
    private func settled() async {
        await library.refresh()
        await loadSelected()
        await review?.reload(notifying: false)
        await review?.onSuggestionsSettled?()
    }

    private func patchAll(_ suggestions: [Suggestion]) {
        today.patch(suggestions)
        day.patch(suggestions)
        backlog.patch(suggestions)
        reviewQueue.patch(suggestions)
        logbook.patch(suggestions)
    }

    // MARK: Pinned info and Notes

    /// The digest and email context for an info item on the shown canvas.
    private func owner(of item: InfoItem) -> (owner: InfoOwner, email: EmailContext?)? {
        switch selection {
        case .today:
            if let o = today.digests.infoOwners[item.id] { return (o, today.email(for: item.emailID)) }
            if let pin = today.carriedPins.first(where: { $0.item.id == item.id }) {
                return (InfoOwner(digestID: pin.digestID, createdAt: pin.digestCreatedAt), today.email(for: item.emailID))
            }
        case .day:
            if let o = day.infoOwners[item.id] { return (o, day.emails[item.emailID]) }
        case .backlog:
            if let o = backlog.infoOwners[item.id] { return (o, backlog.emails[item.emailID]) }
        default:
            break
        }
        return nil
    }

    /// Pins or unpins one info item of any shown digest and saves it. Unpinning an item carried over from an
    /// older digest removes it from Today.
    func setPinned(_ pinned: Bool, item: InfoItem) async {
        guard let store, let found = owner(of: item) else { return }
        do {
            try await store.setPinned(pinned, infoID: item.id, digestID: found.owner.digestID)
        } catch {
            Self.log.error("could not save pin: \(String(describing: error), privacy: .public)")
            message = "Could not save the pin."
            return
        }
        today.setPinned(pinned, infoID: item.id)
        day.setPinned(pinned, infoID: item.id)
        backlog.setPinned(pinned, infoID: item.id)
        message = nil
        // Pins also feed the latest-digest panel's carried pins.
        await review?.reload(notifying: false)
    }

    /// "Save to Notes": runs only from a click.
    func saveToNotes(_ item: InfoItem) async {
        let found = owner(of: item)
        await notes.save(item, email: found?.email, date: found?.owner.createdAt ?? clock.now())
    }

    // MARK: Learned ignore rules

    var ignoreSuggestion: IgnoreSuggestion? { ignore.suggestion }
    var ignoreSuggestionName: String? { ignore.displayName }
    func acceptIgnoreSuggestion() { ignore.accept() }
    func snoozeIgnoreSuggestion() { ignore.snooze() }
    func declineIgnoreSuggestion() { ignore.decline() }
}
