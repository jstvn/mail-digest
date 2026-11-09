import Foundation
import MailDigestCore
import Observation

/// State of the New Backlog Job window: mailbox choice, date range, the counts behind it, the name and when
/// to run. Nothing is queued until `start` succeeds.
@MainActor @Observable
final class JobSetupModel {
    enum Step: Int, CaseIterable { case mailboxes, dateRange, preview }
    enum RunMode: Hashable { case overnight, now }

    /// The chart's data: nothing yet, a query in flight, bins, or no fast Mail store to ask.
    enum Volume: Equatable {
        case idle, loading, ready([VolumeBin]), unavailable
    }

    var step: Step = .mailboxes

    // Step 1
    private(set) var selected: Set<MailboxRef> = []
    var filterText = ""
    var showsNoise = false

    // Step 2
    var preset: BacklogRangePreset = .last30
    var customFrom: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var customTo: Date = .now
    var skipIgnoredSenders = true
    /// End of the newest earlier Backlog job's scope, for "Since Last Job".
    private(set) var lastJobEnd: Date?

    // Step 3
    var runMode: RunMode = .overnight
    /// What the user typed; blank means the default name.
    private(set) var nameDraft = ""
    private var nameEdited = false

    // Counts
    private(set) var preview: JobPreview?
    private(set) var isLoadingPreview = false
    private(set) var volume: Volume = .idle
    /// Q79: median seconds per email over the last 5 completed local jobs, else 360.
    private(set) var secondsPerEmail = BacklogEstimate.fallbackSecondsPerEmail
    private(set) var isStarting = false
    private(set) var error: String?

    @ObservationIgnored private var didDefaultSelection = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Mailboxes

    /// First time mailboxes are known, "All Inboxes" is ticked (the spec's default).
    func applyDefaultSelection(from mailboxes: [MailboxInfo]) {
        guard !didDefaultSelection, !mailboxes.isEmpty else { return }
        didDefaultSelection = true
        selected = Set(MailboxTree.inboxes(mailboxes))
    }

    func isSelected(_ ref: MailboxRef) -> Bool { selected.contains(ref) }

    func setSelected(_ ref: MailboxRef, _ on: Bool) {
        if on { selected.insert(ref) } else { selected.remove(ref) }
        invalidateCounts()
    }

    func allInboxesState(_ mailboxes: [MailboxInfo]) -> Bool {
        let inboxes = Set(MailboxTree.inboxes(mailboxes))
        return !inboxes.isEmpty && inboxes.isSubset(of: selected)
    }

    func setAllInboxes(_ on: Bool, mailboxes: [MailboxInfo]) {
        let inboxes = Set(MailboxTree.inboxes(mailboxes))
        if on { selected.formUnion(inboxes) } else { selected.subtract(inboxes) }
        invalidateCounts()
    }

    /// "Select Inboxes Only": exactly the inboxes.
    func selectInboxesOnly(_ mailboxes: [MailboxInfo]) {
        selected = Set(MailboxTree.inboxes(mailboxes))
        invalidateCounts()
    }

    /// The ticked mailboxes in list order.
    func selectedMailboxes(_ mailboxes: [MailboxInfo]) -> [MailboxInfo] {
        mailboxes.filter { selected.contains($0.ref) }
    }

    /// Total of the ticked mailboxes' message counts (all dates), as Mail's sidebar shows them. Cached counts,
    /// so it costs nothing.
    func selectedMessageCount(_ mailboxes: [MailboxInfo]) -> Int {
        selectedMailboxes(mailboxes).reduce(0) { $0 + $1.messageCount }
    }

    // MARK: Range and name

    var range: BacklogDateRange {
        BacklogDateRange.resolve(preset, now: .now, calendar: calendar, lastJobEnd: lastJobEnd,
                                 customFrom: customFrom, customTo: customTo)
    }

    var rangeText: String { BacklogJobNaming.rangeText(from: range.from, to: range.to, calendar: calendar) }

    var defaultName: String {
        let r = range
        return BacklogJobNaming.defaultName(from: r.from, to: r.to, calendar: calendar)
    }

    /// The text of the Name field: the default until the user types.
    var name: String {
        get { nameEdited ? nameDraft : defaultName }
        set {
            nameDraft = newValue
            nameEdited = true
        }
    }

    /// The name to store: nil for an untouched or blank field, so the job shows its date range.
    var resolvedName: String? { BacklogJobNaming.resolvedName(name, defaultName: defaultName) }

    /// Anything that changes what the counts mean.
    struct Inputs: Hashable {
        var selected: Set<MailboxRef>
        var preset: BacklogRangePreset
        var customFrom: Date
        var customTo: Date
        var lastJobEnd: Date?
    }

    var inputs: Inputs {
        Inputs(selected: selected, preset: preset, customFrom: customFrom, customTo: customTo, lastJobEnd: lastJobEnd)
    }

    // MARK: Counting

    /// Loads what the counts need once: the estimate and the end of the previous job.
    func loadHistory(run: DigestRunModel) async {
        async let seconds = run.backlogSecondsPerEmail()
        async let lastEnd = run.lastBacklogScopeEnd()
        secondsPerEmail = await seconds
        lastJobEnd = await lastEnd
    }

    /// Drops the counts (a stale number must never sit next to a new choice) and cancels work in flight.
    func invalidateCounts() {
        generation += 1
        previewTask?.cancel()
        volumeTask?.cancel()
        preview = nil
        volume = .idle
        isLoadingPreview = false
    }

    /// Starts the cheap volume query and the header listing for the current choice. Older ones are cancelled,
    /// and a result that arrives after a newer request is discarded. Both run off the main actor.
    func refreshCounts(run: DigestRunModel, message: String? = nil) {
        invalidateCounts()
        error = message
        guard !selected.isEmpty else { return }
        let mine = generation
        let refs = run.mailboxes.map(\.ref).filter { selected.contains($0) }
        let range = self.range
        let seconds = secondsPerEmail
        let calendar = self.calendar
        let plan = JobPlan(kind: .backlog, mailboxes: refs, from: range.from, to: range.to, excludedMessageIDs: [])

        volume = .loading
        volumeTask = Task {
            // A short pause so dragging through dates doesn't query on every step.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, mine == generation else { return }
            let window = VolumeHistogram.window(range: range, now: .now, calendar: calendar)
            let counts = await run.dailyVolume(in: refs, from: window.from, to: window.to)
            guard !Task.isCancelled, mine == generation else { return }
            if let counts {
                volume = .ready(VolumeHistogram.bins(counts, range: range, now: .now, calendar: calendar))
            } else {
                volume = .unavailable
            }
        }

        isLoadingPreview = true
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, mine == generation else { return }
            do {
                let result = try await run.previewJob(plan, secondsPerEmail: seconds)
                guard !Task.isCancelled, mine == generation else { return }
                preview = result
            } catch {
                guard !Task.isCancelled, mine == generation else { return }
                self.error = Self.message(for: error)
            }
            isLoadingPreview = false
        }
    }

    // MARK: Confirmed numbers

    /// The preview as Start will queue it (Q26): same plan, ignored senders left out when asked, the exact ids
    /// confirmed, and the time recomputed with the Q79 speed.
    func confirmed(filter: MailFilter) -> JobPreview? {
        guard let preview else { return nil }
        return JobPreviewBuilder(filter: filter).confirmed(preview, excluded: [], skipIgnoredSenders: skipIgnoredSenders,
                                                           secondsPerEmail: secondsPerEmail)
    }

    /// How many previewed emails come from an address on the Ignored list.
    func ignoredSenderCount(filter: MailFilter) -> Int {
        preview?.toProcess.filter { filter.matches($0.sender, in: .ignored) }.count ?? 0
    }

    func canStart(filter: MailFilter) -> Bool {
        !isStarting && !isLoadingPreview && (confirmed(filter: filter)?.toProcess.isEmpty == false)
    }

    // MARK: Navigation

    func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    /// Returns the window to its first step with the default choices, so a reopened window never shows old
    /// numbers. Cancels counting first.
    func reset() {
        invalidateCounts()
        step = .mailboxes
        selected = []
        didDefaultSelection = false
        filterText = ""
        showsNoise = false
        preset = .last30
        customFrom = calendar.date(byAdding: .day, value: -30, to: .now) ?? .now
        customTo = .now
        skipIgnoredSenders = true
        runMode = .overnight
        nameDraft = ""
        nameEdited = false
        error = nil
        isStarting = false
    }

    // MARK: Start

    /// Queues the confirmed plan with its name and run mode. Returns true on success so the window can close.
    func start(run: DigestRunModel) async -> Bool {
        guard var confirmed = confirmed(filter: run.settings.settings.mailFilter), !isStarting else { return false }
        confirmed.plan.name = resolvedName
        confirmed.plan.overnightOnly = runMode == .overnight
        isStarting = true
        defer { isStarting = false }
        if let failure = await run.startBacklog(confirmed.plan) {
            if failure.previewOutdated {
                refreshCounts(run: run, message: failure.message)
            } else {
                error = failure.message
            }
            return false
        }
        return true
    }

    private static func message(for error: Error) -> String {
        if case OsascriptError.automationDenied = error {
            return "Mail automation is off. Open Mail Access to allow it."
        }
        return "Could not read Mail. Open Mail Access to check permissions."
    }
}

#if DEBUG
extension JobSetupModel {
    /// Previews: a Custom 1 to 31 October range with fixed volume and preview numbers; nothing reads Mail.
    func installSampleCounts() {
        preset = .custom
        customFrom = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)) ?? .now
        customTo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31)) ?? .now
        let r = range
        let window = VolumeHistogram.window(range: r, now: .now, calendar: calendar)
        var counts: [DayCount] = []
        var day = window.from
        var i = 0
        while day < window.to {
            counts.append(DayCount(day: DigestDay(day, calendar: calendar), count: 6 + (i * 7) % 11))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? window.to
            i += 1
        }
        volume = .ready(VolumeHistogram.bins(counts, range: r, now: .now, calendar: calendar))

        let ref = MailboxRef(account: "iCloud", name: "INBOX")
        let headers = (0..<412).map { n in
            MessageHeader(id: "m\(n)", account: ref.account, mailbox: ref.name, sender: "Sender \(n % 9) <s\(n % 9)@example.com>",
                          subject: "Message \(n)", receivedAt: r.to.addingTimeInterval(-Double(n) * 3_600),
                          sourceReference: nil)
        }
        let plan = JobPlan(kind: .backlog, mailboxes: [ref], from: r.from, to: r.to, excludedMessageIDs: [])
        preview = JobPreviewBuilder().build(plan: plan, headers: [ref: headers],
                                            isProcessedOrQueued: Set(headers.prefix(38).map(\.id)),
                                            averageSecondsPerEmail: secondsPerEmail)
    }
}
#endif
