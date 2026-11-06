import AppKit
import MailDigestCore
import SwiftUI

/// Today, a past day or a Backlog job: suggestions, info and skipped mail of one digest set. Today adds the
/// carry-over of unreviewed Daily suggestions and pinned info from earlier digests; a Backlog adds the batch bar.
struct DigestCanvasView: View {
    enum Kind: Equatable {
        case today
        case day(DigestDay)
        case backlog(UUID)
    }

    let kind: Kind
    let run: DigestRunModel
    let access: MailAccessModel

    @State private var collapsedGroups: Set<Category> = [.newsletters]
    @State private var skippedExpanded = false
    @State private var pinnedExpanded = true

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var library: ReviewLibrary { run.library }

    /// What the body shows in place of the digest sections.
    private enum Phase {
        case loading
        case failed
        case neverRun
        case noDigestToday
        case noNewMail(lastRun: Date?)
        case digest
    }

    // MARK: Per-kind data

    private var todayModel: TodayCanvasModel { coordinator.today }

    private var content: DayContent? {
        switch kind {
        case .today: return todayModel.digests.content
        case .day: return coordinator.day.content
        case .backlog: return coordinator.backlog.content
        }
    }

    private var loadFailed: Bool {
        switch kind {
        case .today: return todayModel.digests.loadFailed
        case .day: return coordinator.day.loadFailed
        case .backlog: return coordinator.backlog.loadFailed
        }
    }

    private func email(for emailID: String) -> EmailContext? {
        switch kind {
        case .today: return todayModel.email(for: emailID)
        case .day: return coordinator.day.emails[emailID]
        case .backlog: return coordinator.backlog.emails[emailID]
        }
    }

    /// Today's carry-over; empty elsewhere.
    private var carryOver: [SuggestionRecord] {
        kind == .today ? todayModel.carryOver.records.filter(\.isActionable) : []
    }

    private var actionable: [SuggestionRecord] {
        switch kind {
        case .today: return todayModel.digests.actionable
        case .day: return coordinator.day.actionable
        case .backlog: return coordinator.backlog.actionable
        }
    }

    private var settled: [SuggestionRecord] {
        switch kind {
        case .today: return todayModel.digests.settled
        case .day: return coordinator.day.settled
        case .backlog: return coordinator.backlog.settled
        }
    }

    /// The Q16 page for Today and a Day; a Backlog has no digest-wide cap.
    private var page: RecordPage {
        switch kind {
        case .today: return todayModel.digests.page
        case .day: return coordinator.day.page
        case .backlog: return ReviewCanvasLogic.page(actionable, limit: nil, showAll: true)
        }
    }

    private var pinned: [PinnedInfo] { kind == .today ? todayModel.carriedPins : [] }

    /// The model behind "Show all" for Today and a Day.
    private var pagedModel: DayCanvasModel? {
        switch kind {
        case .today: return todayModel.digests
        case .day: return coordinator.day
        case .backlog: return nil
        }
    }

    /// Exactly the actionable records this canvas shows, in on-screen order.
    private var shownRecords: [SuggestionRecord] { carryOver + page.visible }

    /// Whether actionable suggestions of this view are hidden from the triage scope.
    private var isPartial: Bool {
        page.isPartial || (kind == .today && todayModel.hasMoreCarryOver)
    }

    // MARK: Phase and titles

    private var phase: Phase {
        guard let content else { return loadFailed ? .failed : .loading }
        switch kind {
        case .today:
            if !content.digestIDs.isEmpty {
                let isEmpty = content.emailCount == 0 && content.records.isEmpty && content.info.isEmpty && content.skipped.isEmpty
                return isEmpty ? .noNewMail(lastRun: run.lastRunAt) : .digest
            }
            // Q24: a run that found nothing leaves no digest, so only a run from today counts.
            if run.lastRunFoundNothing, run.activeProgress == nil,
               let last = run.lastRunAt, last >= library.archive.startOfToday {
                return .noNewMail(lastRun: last)
            }
            let hasHistory = !library.archive.months.isEmpty || !library.archive.backlogs.isEmpty || !carryOver.isEmpty
            return hasHistory ? .noDigestToday : .neverRun
        case .day, .backlog:
            return .digest
        }
    }

    private var title: String {
        switch kind {
        case .today:
            let today = DigestDay(library.archive.startOfToday, calendar: library.calendar)
            return "Today · \(ReviewDateText.day(today, calendar: library.calendar))"
        case .day(let day): return ReviewDateText.day(day, calendar: library.calendar)
        case .backlog(let id): return library.title(forBacklog: id)
        }
    }

    private var subtitle: String? {
        switch kind {
        case .backlog(let id):
            if let scope = library.scope(forBacklog: id) { return scope }
        default: break
        }
        guard let content, !content.digestIDs.isEmpty else { return nil }
        return "\(content.emailCount) \(content.emailCount == 1 ? "email" : "emails") processed"
    }

    // MARK: Body

    var body: some View {
        CanvasScaffold(run: run, access: access, title: title, subtitle: subtitle,
                       headline: content?.headline ?? "", records: shownRecords, isPartial: isPartial,
                       revealTarget: revealTarget) { focus in
            if case .backlog = kind { batchBar }
            if !carryOver.isEmpty { carryOverSection(focus) }
            switch phase {
            case .loading:
                ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: carryOver.isEmpty ? 160 : 40)
            case .failed:
                emptyState("Couldn't load this digest", systemImage: "exclamationmark.triangle", "Try again in a moment.")
            case .neverRun:
                emptyState("No digest yet", systemImage: "envelope.open", "Choose Run Now to read your new mail.")
            case .noDigestToday:
                emptyState("No digest yet today", systemImage: "envelope.open", "Choose Run Now to read your new mail.")
            case .noNewMail(let lastRun):
                emptyState("Inbox zero for today", systemImage: "tray",
                           lastRun.map { "Last run \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            case .digest:
                suggestionsSection(focus)
                infoSection
                skippedSection
            }
        }
    }

    /// A full-size empty state, or one quiet line beneath the carry-over when that is on screen. The empty
    /// state describes only this canvas's own digests, so it never replaces the carry-over.
    @ViewBuilder
    private func emptyState(_ title: String, systemImage: String, _ detail: String) -> some View {
        if carryOver.isEmpty {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            Text(detail.isEmpty ? title : "\(title). \(detail)").foregroundStyle(.secondary)
        }
    }

    // MARK: Backlog batches

    /// Backlog digests are reviewed 50 source emails at a time.
    @ViewBuilder private var batchBar: some View {
        let backlog = coordinator.backlog
        if backlog.hasBatches, let title = backlog.batchTitle {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button { backlog.previousBatch() } label: { Label("Previous Batch", systemImage: "chevron.left") }
                    .disabled(!backlog.canGoToPreviousBatch)
                Button { backlog.nextBatch() } label: { Label("Next Batch", systemImage: "chevron.right") }
                    .labelStyle(.titleAndIcon)
                    .disabled(!backlog.canGoToNextBatch)
            }
            .controlSize(.small)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Suggestions

    private func carryOverSection(_ focus: FocusState<UUID?>.Binding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionableRecordsSection(coordinator: coordinator, title: "Unreviewed from Earlier",
                                     count: carryOver.count, records: carryOver, focus: focus)
            if todayModel.hasMoreCarryOver {
                HStack {
                    Text(ReviewCanvasLogic.showingText(
                        shown: carryOver.count, total: max(library.archive.carryOverCount, carryOver.count)))
                        .foregroundStyle(.secondary)
                    Button("More unreviewed suggestions are in the Review Queue") { coordinator.select(.reviewQueue) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func suggestionsSection(_ focus: FocusState<UUID?>.Binding) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ActionableRecordsSection(coordinator: coordinator, title: "Suggested Reminders",
                                     count: actionable.count, records: page.visible, focus: focus,
                                     emptyText: settled.isEmpty ? "No reminders suggested." : "Nothing left to review.",
                                     countText: page.countText, scopeAction: scopeAction)
            if !settled.isEmpty {
                SettledRecordsSection(title: "Reviewed", records: settled)
            }
        }
    }

    /// Show All when the Q16 page hides suggestions; Show Top 25 once everything is shown.
    private var scopeAction: ScopeAction? {
        guard let model = pagedModel else { return nil }
        if page.isPartial {
            return ScopeAction(title: "Show All",
                               help: "Show all \(page.totalCount) suggestions. Add and Dismiss then cover all of them.") {
                model.showAll = true
            }
        }
        if model.showAll, actionable.count > DayCanvasModel.presentationLimit {
            return ScopeAction(title: "Show Top \(DayCanvasModel.presentationLimit)",
                               help: "Show only the \(DayCanvasModel.presentationLimit) highest-confidence suggestions") {
                model.showAll = false
            }
        }
        return nil
    }

    // MARK: Info

    @ViewBuilder private var infoSection: some View {
        let groups = ReviewPresentation.infoGroups(content?.info ?? [])
        let pinnedItems = pinned.map(\.item)
        if !groups.isEmpty || !pinnedItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Info")
                // Pinned items from earlier digests come first, as their own group, until they are unpinned.
                if !pinnedItems.isEmpty {
                    DisclosureGroup(isExpanded: $pinnedExpanded) {
                        infoCards(pinnedItems)
                    } label: {
                        Label("Pinned (\(pinnedItems.count))", systemImage: "pin.fill")
                            .font(.body.weight(.medium))
                    }
                }
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedGroups.contains(group.category) },
                        set: { open in
                            if open { collapsedGroups.remove(group.category) } else { collapsedGroups.insert(group.category) }
                        })) {
                        infoCards(group.items)
                    } label: {
                        Text("\(group.category.rawValue.capitalized) (\(group.items.count))")
                            .font(.body.weight(.medium))
                    }
                }
            }
        }
    }

    private func infoCards(_ items: [InfoItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                InfoCard(item: item, email: email(for: item.emailID),
                         notesState: coordinator.notes.states[item.id] ?? .idle,
                         onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: item.emailID)) },
                         onTogglePin: { Task { await coordinator.setPinned(!item.pinned, item: item) } },
                         onSaveToNotes: { Task { await coordinator.saveToNotes(item) } })
                .id(item.id)
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: Skipped

    @ViewBuilder private var skippedSection: some View {
        if let skipped = content?.skipped, !skipped.isEmpty {
            DisclosureGroup(isExpanded: $skippedExpanded) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(skipped) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(ReviewPresentation.senderName(item.sender)) · \(item.subject)")
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(item.reason).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Skipped (\(skipped.count))").font(.body.weight(.medium))
            }
        }
    }

    // MARK: Reveal

    /// The scroll id for an email a job popover asked to show; opens a collapsed group that holds it.
    private func revealTarget(_ emailID: String) -> AnyHashable? {
        if let record = (carryOver + actionable + settled).first(where: { $0.suggestion.emailID == emailID }) {
            return record.id
        }
        if let item = content?.info.first(where: { $0.emailID == emailID }) {
            collapsedGroups.remove(item.category)
            return item.id
        }
        return nil
    }
}
