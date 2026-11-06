import Foundation
import MailDigestCore
import Observation
import OSLog

/// Owns the latest digest for the parts of the app that still work on it: Mail Cleanup, auto-file and the
/// ignore-rule check on load. Reviewing, selecting and approving live in `ReviewCoordinator` (Q54). Store
/// work happens off the main actor; the pure decisions live in `ReviewActions` and `ReviewPresentation`.
@MainActor @Observable
final class ReviewViewModel {
    /// The latest digest, of any kind.
    private(set) var digest: Digest?
    /// Sender, subject and mailbox per email id, from the job's `job_item` rows.
    private(set) var emails: [String: EmailContext] = [:]
    private(set) var jobKind: JobKind = .daily
    /// Shared with the cross-digest coordinator: "Save to Notes" progress and the ignore-rule notice.
    @ObservationIgnored let notes: NotesSaver
    @ObservationIgnored let ignore: IgnoreSuggestionModel
    /// Set by `DigestRunModel`; the ignore-rule notice reads and writes the sender lists here.
    var settingsStore: SettingsStore? {
        get { ignore.settingsStore }
        set { ignore.settingsStore = newValue }
    }
    /// Called after a reload that changed what the store holds, so the cross-digest library and the shown
    /// canvas refresh at the same moments (job progress, run end, cleanup).
    @ObservationIgnored var onReloaded: (@MainActor () async -> Void)?
    /// Called after approve or dismiss changed what is pending; auto-file uses it to move newly processed mail.
    @ObservationIgnored var onSuggestionsSettled: (@MainActor () async -> Void)?

    @ObservationIgnored private var store: (any DigestStore)?
    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var needsReload = false
    /// The digest whose senders were last checked for ignore suggestions on load.
    @ObservationIgnored private var evaluatedDigestID: UUID?
    @ObservationIgnored var listName: @MainActor () -> String = { DigestSettings.defaultListName }
    static let listIDKey = "remindersListID"
    private static let log = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

    init() {
        notes = NotesSaver()
        ignore = IgnoreSuggestionModel()
    }

    /// Previews and tests: shows a fixed digest without a store.
    init(preview state: ReviewState?, emails: [String: EmailContext] = [:], jobKind: JobKind = .daily,
         ignoreSuggestion: IgnoreSuggestion? = nil) {
        self.ignore = IgnoreSuggestionModel(suggestion: ignoreSuggestion)
        self.notes = NotesSaver(preview: RecordingNotesWriter())
        self.digest = state?.digest
        self.emails = emails
        self.jobKind = jobKind
    }

    /// Mailbox and Mail row id per email id, from the owning job's items (Q18), for mail actions.
    func locations(for ids: [String]) -> [String: MailLocation] {
        var out: [String: MailLocation] = [:]
        for id in ids {
            if let email = emails[id] { out[id] = MailLocation(mailbox: email.mailbox, storeRowID: email.storeRowID) }
        }
        return out
    }

    // MARK: Loading

    /// Connects the store and loads the latest digest.
    func attach(store: any DigestStore) async {
        self.store = store
        await reload()
    }

    /// Loads the latest digest. Safe to call often (a running job calls it as results arrive): overlapping
    /// calls coalesce. `notifying: false` skips `onReloaded`, for callers that refresh the cross-digest views
    /// themselves.
    func reload(notifying: Bool = true) async {
        guard let store else { return }
        if isReloading { needsReload = true; return }
        isReloading = true
        repeat {
            needsReload = false
            do {
                let latest = try await store.latestDigest()
                var kind = jobKind
                var context = emails
                if let latest {
                    let ids = Set(latest.info.map(\.emailID) + latest.suggestions.map(\.emailID))
                    if let job = try await store.jobs().first(where: { $0.id == latest.id }) { kind = job.kind }
                    // A Backlog digest grows as results arrive, so its items are always re-read (Q18).
                    if kind == .backlog || !ids.isSubset(of: context.keys) {
                        Self.merge(try await store.items(job: latest.id), into: &context)
                    }
                }
                digest = latest
                emails = context
                jobKind = kind
                if let latest, evaluatedDigestID != latest.id {
                    evaluatedDigestID = latest.id
                    await ignore.evaluate(senders: Set(latest.suggestions.compactMap { context[$0.emailID]?.sender }), store: store)
                }
            } catch {
                Self.log.error("could not load digest: \(String(describing: error), privacy: .public)")
            }
        } while needsReload
        // Cleared before the hook so a reload requested from inside it is not lost.
        isReloading = false
        if notifying { await onReloaded?() }
    }

    /// Adds job items' sender/subject/mailbox to the lookup; the first item for an email wins.
    private static func merge(_ items: [JobItem], into context: inout [String: EmailContext]) {
        for item in items where context[item.messageID] == nil {
            context[item.messageID] = EmailContext(item: item)
        }
    }
}
