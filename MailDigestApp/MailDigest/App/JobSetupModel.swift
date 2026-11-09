import Foundation
import MailDigestCore
import Observation

/// State of the New Processing Job window: mailbox choice, date scope, the preview and the user's
/// unticked emails. Nothing is queued until `start` succeeds.
@MainActor @Observable
final class JobSetupModel {
    enum Step: Int, CaseIterable { case mailboxes, dateRange, preview }
    enum Scope: Hashable { case last30, last90, everything, custom }

    var step: Step = .mailboxes
    private(set) var selected: Set<MailboxRef> = []
    var showAllMailboxes = false
    var scope: Scope = .last30
    var customFrom: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var customTo: Date = .now

    private(set) var preview: JobPreview?
    private(set) var isLoadingPreview = false
    private(set) var isStarting = false
    private(set) var error: String?
    /// Emails the user unticked; they become the plan's `excludedMessageIDs`.
    private(set) var excluded: Set<String> = []

    @ObservationIgnored private var didDefaultSelection = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?

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
        invalidatePreview()
    }

    func allInboxesState(_ mailboxes: [MailboxInfo]) -> Bool {
        let inboxes = Set(MailboxTree.inboxes(mailboxes))
        return !inboxes.isEmpty && inboxes.isSubset(of: selected)
    }

    func setAllInboxes(_ on: Bool, mailboxes: [MailboxInfo]) {
        let inboxes = Set(MailboxTree.inboxes(mailboxes))
        if on { selected.formUnion(inboxes) } else { selected.subtract(inboxes) }
        invalidatePreview()
    }

    /// Total of the ticked mailboxes' message counts (all dates), as Mail's sidebar shows them.
    func selectedMessageCount(_ mailboxes: [MailboxInfo]) -> Int {
        mailboxes.filter { selected.contains($0.ref) }.reduce(0) { $0 + $1.messageCount }
    }

    // MARK: Scope

    func scopeChanged() { invalidatePreview() }

    var scopeDescription: String {
        switch scope {
        case .last30: return "last 30 days"
        case .last90: return "last 90 days"
        case .everything: return "everything"
        case .custom:
            return "\(customFrom.formatted(date: .abbreviated, time: .omitted)) to \(customTo.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// The plan for a preview taken at `now`. `to` is fixed here and never re-read, so Start queues exactly
    /// what the preview listed; mail arriving later goes to the next Daily job.
    func makePlan(mailboxes: [MailboxInfo], now: Date, calendar: Calendar = .current) -> JobPlan {
        let refs = mailboxes.map(\.ref).filter { selected.contains($0) }
        let from: Date, to: Date
        switch scope {
        case .last30: (from, to) = (now.addingTimeInterval(-30 * 86_400), now)
        case .last90: (from, to) = (now.addingTimeInterval(-90 * 86_400), now)
        case .everything: (from, to) = (Date(timeIntervalSince1970: 0), now)
        case .custom:
            from = calendar.startOfDay(for: min(customFrom, customTo))
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo)))
                .map { $0.addingTimeInterval(-1) } ?? now
            to = min(endOfDay, now)
        }
        return JobPlan(kind: .backlog, mailboxes: refs, from: from, to: to, excludedMessageIDs: [])
    }

    // MARK: Preview

    /// Lists headers only; no bodies, no model calls.
    /// `message` stays visible after the reload, for example when Start found the preview outdated.
    func loadPreview(run: DigestRunModel, message: String? = nil) {
        previewTask?.cancel()
        error = message
        excluded = []
        preview = nil
        isLoadingPreview = true
        let plan = makePlan(mailboxes: run.mailboxes, now: .now)
        previewTask = Task {
            defer { isLoadingPreview = false }
            do {
                let result = try await run.previewJob(plan)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Self.message(for: error)
            }
        }
    }

    /// Returns the window to its first step with the default selection and no preview, so a reopened
    /// window never shows a stale one. Cancels an in-flight preview first.
    func reset() {
        previewTask?.cancel()
        previewTask = nil
        step = .mailboxes
        selected = []
        didDefaultSelection = false
        showAllMailboxes = false
        scope = .last30
        customFrom = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        customTo = .now
        preview = nil
        excluded = []
        error = nil
        isLoadingPreview = false
        isStarting = false
    }

    func invalidatePreview() {
        previewTask?.cancel()
        preview = nil
        excluded = []
        isLoadingPreview = false
    }

    func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    // MARK: Untick

    func isIncluded(_ id: String) -> Bool { !excluded.contains(id) }

    func setIncluded(_ id: String, _ on: Bool) {
        if on { excluded.remove(id) } else { excluded.insert(id) }
    }

    /// Unticks or reticks every previewed email from one sender address.
    func setSender(_ sender: String, included: Bool) {
        guard let preview else { return }
        let key = MailFilter.address(from: sender)
        for header in preview.toProcess where MailFilter.address(from: header.sender) == key {
            setIncluded(header.id, included)
        }
    }

    func senderCount(_ sender: String) -> Int {
        let key = MailFilter.address(from: sender)
        return preview?.toProcess.filter { MailFilter.address(from: $0.sender) == key }.count ?? 0
    }

    /// The preview as Start will queue it: the same plan plus the unticked ids, with counts and time to match.
    var confirmed: JobPreview? {
        guard var p = preview else { return nil }
        let perEmail = p.toProcess.isEmpty ? 20 : p.estimatedSeconds / Double(p.toProcess.count)
        p.toProcess.removeAll { excluded.contains($0.id) }
        p.plan.excludedMessageIDs = excluded
        // Start queues exactly these emails, not a fresh listing.
        p.plan.confirmedMessageIDs = Set(p.toProcess.map(\.id))
        p.estimatedSeconds = perEmail * Double(p.toProcess.count)
        return p
    }

    /// Text for the Start button, from the core builder.
    func startTitle(filter: MailFilter) -> String? {
        confirmed.map { JobPreviewBuilder(filter: filter).startTitle(for: $0) }
    }

    // MARK: Start

    /// Queues the confirmed plan. Returns true on success so the window can close.
    func start(run: DigestRunModel) async -> Bool {
        guard let plan = confirmed?.plan, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        if let failure = await run.startBacklog(plan) {
            if failure.previewOutdated {
                loadPreview(run: run, message: failure.message)
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
