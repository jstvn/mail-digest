import Foundation
import MailDigestCore
import Observation
import OSLog

private let canvasLog = Logger(subsystem: "dev.pages.justinwang.maildigest", category: "review")

/// The digest that owns an info item, so pin and Save to Notes act on the right row.
struct InfoOwner: Equatable {
    var digestID: UUID
    var createdAt: Date
}

/// Shared loading helpers for the canvases.
@MainActor
enum CanvasLoading {
    /// Adds job items' sender, subject and mailbox to the lookup; the first item for an email wins.
    static func merge(_ items: [JobItem], into context: inout [String: EmailContext]) {
        for item in items where context[item.messageID] == nil {
            context[item.messageID] = EmailContext(item: item)
        }
    }

    /// The digests with these ids (missing ones skipped) and the email context of everything they mention.
    /// A job's items are read only when its digest mentions an email not already known (Q18).
    static func digests(ids: [UUID], store: any DigestStore, known: [String: EmailContext])
        async throws -> (digests: [Digest], emails: [String: EmailContext], providers: [String: ExecutionProvider]) {
        var context = known
        var providers: [String: ExecutionProvider] = [:]
        var out: [Digest] = []
        for id in ids {
            guard let digest = try await store.digest(id: id) else { continue }
            // One light query per digest: which emails Gemini processed (for the info card's cloud glyph).
            providers.merge(try await store.providers(job: id)) { a, _ in a }
            let mentioned = Set(digest.info.map(\.emailID) + digest.suggestions.map(\.emailID))
            if !mentioned.isSubset(of: context.keys) { merge(try await store.items(job: id), into: &context) }
            out.append(digest)
        }
        return (out, context, providers)
    }

    static func owners(of digests: [Digest]) -> [String: InfoOwner] {
        var out: [String: InfoOwner] = [:]
        for d in digests { for item in d.info { out[item.id] = InfoOwner(digestID: d.id, createdAt: d.createdAt) } }
        return out
    }
}

/// Local patches shared by every canvas holding records.
extension Array where Element == SuggestionRecord {
    /// Replaces the suggestion inside any record it matches; a changed category follows.
    mutating func patch(_ suggestions: [Suggestion]) {
        let byID = Dictionary(suggestions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in indices {
            guard let s = byID[self[i].id] else { continue }
            self[i].suggestion = s
            if let c = s.category { self[i].category = c }
        }
    }
}

// MARK: Daily digests of one day

/// The merged content of a set of Daily digests: one day (Q54) or Today's. Loads only when asked.
@MainActor @Observable
final class DayCanvasModel {
    /// Nil until loaded; an empty set of digests gives an empty `DayContent`.
    private(set) var content: DayContent?
    /// Sender, subject and mailbox per email id, from the digests' job items.
    private(set) var emails: [String: EmailContext] = [:]
    private(set) var infoOwners: [String: InfoOwner] = [:]
    /// Final executor per email id, for the "Summarised by Gemini" glyph.
    private(set) var providers: [String: ExecutionProvider] = [:]
    private(set) var loadFailed = false
    /// Q16: shows the 25 highest-confidence actionable suggestions first; this reveals the rest.
    var showAll = false

    @ObservationIgnored private var requested: [UUID]?
    @ObservationIgnored private let gate = ReloadGate()
    static let presentationLimit = 25

    init() {}

    /// Previews: fixed content.
    init(preview content: DayContent, emails: [String: EmailContext], owners: [String: InfoOwner] = [:]) {
        self.content = content
        self.emails = emails
        self.infoOwners = owners
    }

    var actionable: [SuggestionRecord] {
        content.map { ReviewCanvasLogic.split($0.records).actionable } ?? []
    }
    /// Approved, dismissed and other settled suggestions, still shown in a snapshot.
    var settled: [SuggestionRecord] {
        content.map { ReviewCanvasLogic.split($0.records).settled } ?? []
    }
    var page: RecordPage {
        ReviewCanvasLogic.page(actionable, limit: Self.presentationLimit, showAll: showAll)
    }

    /// Loads these Daily digests. A different set clears the old content first so the wrong day never shows.
    func load(digestIDs: [UUID], store: any DigestStore) async {
        // A different set of digests (another day) clears the old content; a growing set (a new run today) does not.
        if let content, !content.digestIDs.isEmpty, Set(content.digestIDs).isDisjoint(with: digestIDs) {
            self.content = nil
            showAll = false
        }
        requested = digestIDs
        await gate.run {
            guard let ids = requested else { return }
            do {
                let loaded = try await CanvasLoading.digests(ids: ids, store: store, known: emails)
                guard requested == ids else { return }
                emails = loaded.emails
                providers = loaded.providers
                content = DayContent(digests: loaded.digests, kind: .daily, emails: loaded.emails)
                infoOwners = CanvasLoading.owners(of: loaded.digests)
                loadFailed = false
            } catch {
                canvasLog.error("could not load day: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
    }

    func patch(_ suggestions: [Suggestion]) { content?.records.patch(suggestions) }

    func setPinned(_ pinned: Bool, infoID: String) {
        if let i = content?.info.firstIndex(where: { $0.id == infoID }) { content?.info[i].pinned = pinned }
    }
}

// MARK: Paged record lists

/// A cross-digest list loaded in pages: Today's carry-over, the Review Queue and the Logbook.
@MainActor @Observable
final class PagedRecordsModel {
    enum Source: Equatable {
        /// Pending and failed Daily suggestions from digests created before this date.
        case carryOver(before: Date)
        /// Every pending and failed suggestion, Daily and Backlog.
        case reviewQueue
        /// Approved and dismissed suggestions, newest decision first (Q57).
        case logbook
    }

    private(set) var records: [SuggestionRecord] = []
    /// Review Queue only: the records grouped by the day of their digest.
    private(set) var groups: [RecordGroup] = []
    private(set) var hasMore = false
    private(set) var isLoaded = false
    private(set) var loadFailed = false

    let pageSize: Int
    @ObservationIgnored private var source: Source?
    /// How many records the view has asked for; reloads fetch this many so the list refills after actions.
    @ObservationIgnored private var target: Int
    @ObservationIgnored private var calendar = Calendar(identifier: .gregorian)
    @ObservationIgnored private let gate = ReloadGate()

    init(pageSize: Int) {
        self.pageSize = pageSize
        self.target = pageSize
    }

    /// Previews: fixed records.
    init(preview records: [SuggestionRecord], groups: [RecordGroup] = [], hasMore: Bool = false, pageSize: Int = 50) {
        self.pageSize = pageSize
        self.target = pageSize
        self.records = records
        self.groups = groups
        self.hasMore = hasMore
        self.isLoaded = true
    }

    /// Loads (or reloads) the first `target` records of `source`.
    func load(_ source: Source, store: any DigestStore, calendar: Calendar) async {
        if self.source != source { target = pageSize; records = []; groups = []; hasMore = false; isLoaded = false }
        self.source = source
        self.calendar = calendar
        await gate.run {
            guard let source = self.source else { return }
            let count = target
            do {
                let fetched = try await Self.fetch(source, store: store, limit: count + 1)
                guard self.source == source else { return }
                hasMore = fetched.count > count
                records = Array(fetched.prefix(count))
                groups = source == .reviewQueue ? ReviewCanvasLogic.groupByDay(records, calendar: calendar) : []
                loadFailed = false
            } catch {
                canvasLog.error("could not load records: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
            isLoaded = true
        }
    }

    /// Asks for one more page.
    func loadMore(store: any DigestStore) async {
        guard hasMore, let source else { return }
        target += pageSize
        await load(source, store: store, calendar: calendar)
    }

    private static func fetch(_ source: Source, store: any DigestStore, limit: Int) async throws -> [SuggestionRecord] {
        switch source {
        case .carryOver(let before):
            return try await store.actionableSuggestions(SuggestionQuery(kinds: [.daily], digestsCreatedBefore: before, limit: limit))
        case .reviewQueue:
            return try await store.actionableSuggestions(SuggestionQuery(limit: limit))
        case .logbook:
            return try await store.decidedSuggestions(limit: limit, offset: 0)
        }
    }

    func patch(_ suggestions: [Suggestion]) {
        records.patch(suggestions)
        for i in groups.indices { groups[i].records.patch(suggestions) }
    }
}

// MARK: Today

/// Today: Daily carry-over, today's merged digests and pins carried from earlier digests.
@MainActor @Observable
final class TodayCanvasModel {
    /// Q16 first page of carry-over; the rest is in the Review Queue.
    static let carryOverPageSize = 100

    /// Today's Daily digests only.
    let digests: DayCanvasModel
    /// Pending and failed Daily suggestions from digests created before today.
    let carryOver: PagedRecordsModel
    /// Pinned info from earlier digests, newest first; today's own pins stay in its categories.
    private(set) var carriedPins: [PinnedInfo] = []
    private(set) var pinEmails: [String: EmailContext] = [:]
    private(set) var pinProviders: [String: ExecutionProvider] = [:]
    /// Where today's emails were processed and when the runs finished, for the run line. Nil until loaded.
    private(set) var runInfo: RunInfo?

    @ObservationIgnored private let gate = ReloadGate()
    @ObservationIgnored private var requested: (ids: [UUID], start: Date)?

    init() {
        digests = DayCanvasModel()
        carryOver = PagedRecordsModel(pageSize: Self.carryOverPageSize)
    }

    /// Previews: fixed content.
    init(preview digests: DayCanvasModel, carryOver: PagedRecordsModel, carriedPins: [PinnedInfo] = [], runInfo: RunInfo? = nil) {
        self.digests = digests
        self.carryOver = carryOver
        self.carriedPins = carriedPins
        self.runInfo = runInfo
    }

    /// Whether more carry-over exists than the first page; the UI links to the Review Queue.
    var hasMoreCarryOver: Bool { carryOver.hasMore }

    func load(digestIDs: [UUID], startOfToday: Date, store: any DigestStore, calendar: Calendar) async {
        requested = (digestIDs, startOfToday)
        await gate.run {
            guard let request = requested else { return }
            // Independent loads; each coalesces on its own.
            await digests.load(digestIDs: request.ids, store: store)
            await carryOver.load(.carryOver(before: request.start), store: store, calendar: calendar)
            await loadPins(excluding: request.ids, store: store)
            await loadRunInfo(ids: request.ids, store: store)
        }
    }

    /// The jobs behind today's digests (a digest shares its job's id) and their items' executors.
    private func loadRunInfo(ids: [UUID], store: any DigestStore) async {
        guard !ids.isEmpty else { runInfo = nil; return }
        do {
            let jobs = try await store.jobs().filter { ids.contains($0.id) }
            var items: [JobItem] = []
            for id in ids { items += try await store.items(job: id) }
            runInfo = RunInfo.make(jobs: jobs, items: items)
        } catch {
            canvasLog.error("could not load run info: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadPins(excluding ids: [UUID], store: any DigestStore) async {
        do {
            let shownEmails = Set(digests.content?.info.map(\.emailID) ?? [])
            let carried = ReviewCanvasLogic.carriedPins(try await store.pinnedInfo(), excludingDigests: Set(ids),
                                                       shownEmailIDs: shownEmails)
            // Sender and subject for carried items come from their own job's items (Q18).
            var context = pinEmails
            for digestID in Set(carried.filter({ context[$0.item.emailID] == nil }).map(\.digestID)) {
                CanvasLoading.merge(try await store.items(job: digestID), into: &context)
            }
            pinEmails = context
            var providers: [String: ExecutionProvider] = [:]
            for digestID in Set(carried.map(\.digestID)) {
                providers.merge(try await store.providers(job: digestID)) { a, _ in a }
            }
            pinProviders = providers
            carriedPins = carried
        } catch {
            canvasLog.error("could not load pins: \(String(describing: error), privacy: .public)")
        }
    }

    /// Email context for an info item or record on this canvas.
    func email(for emailID: String) -> EmailContext? { digests.emails[emailID] ?? pinEmails[emailID] }

    func provider(for emailID: String) -> ExecutionProvider? { digests.providers[emailID] ?? pinProviders[emailID] }

    func patch(_ suggestions: [Suggestion]) {
        digests.patch(suggestions)
        carryOver.patch(suggestions)
    }

    func setPinned(_ pinned: Bool, infoID: String) {
        digests.setPinned(pinned, infoID: infoID)
        if let i = carriedPins.firstIndex(where: { $0.item.id == infoID }) {
            if pinned { carriedPins[i].item.pinned = true } else { carriedPins.remove(at: i) }
        }
    }
}

// MARK: Backlog

/// One Backlog job's digest in review batches of 50 source emails (Q47).
@MainActor @Observable
final class BacklogCanvasModel {
    private(set) var jobID: UUID?
    /// The shown batch merged into one content, as a Day canvas.
    private(set) var content: DayContent?
    private(set) var emails: [String: EmailContext] = [:]
    private(set) var infoOwners: [String: InfoOwner] = [:]
    private(set) var providers: [String: ExecutionProvider] = [:]
    private(set) var batching: BacklogBatching?
    /// The batch on screen, zero-based.
    private(set) var batchIndex = 0
    private(set) var loadFailed = false

    @ObservationIgnored private var digest: Digest?
    @ObservationIgnored private var requested: UUID?
    @ObservationIgnored private let gate = ReloadGate()

    init() {}

    /// Previews: fixed batch content.
    init(preview content: DayContent, emails: [String: EmailContext], batching: BacklogBatching? = nil, batchIndex: Int = 0) {
        self.content = content
        self.emails = emails
        self.batching = batching
        self.batchIndex = batchIndex
    }

    /// A Backlog has no digest-wide cap, so the shown batch lists every actionable suggestion.
    var actionable: [SuggestionRecord] {
        content.map { ReviewCanvasLogic.split($0.records).actionable } ?? []
    }
    var settled: [SuggestionRecord] {
        content.map { ReviewCanvasLogic.split($0.records).settled } ?? []
    }

    var batchTitle: String? { batching.map { $0.title(batch: batchIndex) } }
    var hasBatches: Bool { (batching?.batchCount ?? 0) > 1 }
    var canGoToPreviousBatch: Bool { batchIndex > 0 }
    var canGoToNextBatch: Bool { batching.map { batchIndex < $0.batchCount - 1 } ?? false }
    func nextBatch() { if canGoToNextBatch { batchIndex += 1; rebuild() } }
    func previousBatch() { if canGoToPreviousBatch { batchIndex -= 1; rebuild() } }

    /// Jumps to the batch holding this email. Returns false when no result for it is loaded.
    @discardableResult
    func reveal(emailID: String) -> Bool {
        guard let batching, let position = batching.emailIDs.firstIndex(of: emailID) else { return false }
        batchIndex = position / batching.size
        rebuild()
        return true
    }

    func load(jobID: UUID, store: any DigestStore) async {
        if requested != jobID {
            digest = nil; content = nil; batching = nil; batchIndex = 0; emails = [:]; providers = [:]
        }
        requested = jobID
        await gate.run {
            guard let id = requested else { return }
            do {
                guard let loaded = try await store.digest(id: id) else {
                    guard requested == id else { return }
                    digest = nil; content = nil; batching = nil
                    return
                }
                // Batches follow the job's own order; results appear as each email is persisted.
                let items = try await store.items(job: id)
                guard requested == id else { return }
                var context = emails
                CanvasLoading.merge(items, into: &context)
                emails = context
                providers = try await store.providers(job: id)
                guard requested == id else { return }
                let resultIDs = Set(loaded.info.map(\.emailID) + loaded.suggestions.map(\.emailID)).union(loaded.skipped.map(\.id))
                batching = BacklogBatching(jobOrder: items.sorted { $0.position < $1.position }.map(\.messageID),
                                           resultIDs: resultIDs)
                digest = loaded
                self.jobID = id
                infoOwners = CanvasLoading.owners(of: [loaded])
                rebuild()
                loadFailed = false
            } catch {
                canvasLog.error("could not load backlog: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
    }

    private func rebuild() {
        guard let digest, let batching else { content = nil; return }
        batchIndex = batching.clamped(batchIndex)
        content = DayContent(digests: [batching.digest(digest, batch: batchIndex)], kind: .backlog, emails: emails)
    }

    func patch(_ suggestions: [Suggestion]) {
        content?.records.patch(suggestions)
        // Keep the full digest in step, so changing batch doesn't show stale statuses until the next reload.
        guard var full = digest else { return }
        let byID = Dictionary(suggestions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in full.suggestions.indices { if let s = byID[full.suggestions[i].id] { full.suggestions[i] = s } }
        digest = full
    }

    func setPinned(_ pinned: Bool, infoID: String) {
        if let i = content?.info.firstIndex(where: { $0.id == infoID }) { content?.info[i].pinned = pinned }
        if let i = digest?.info.firstIndex(where: { $0.id == infoID }) { digest?.info[i].pinned = pinned }
    }
}
