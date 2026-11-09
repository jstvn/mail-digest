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

    /// Group cards (several emails from one sender) that are open.
    @State private var expandedClusters: Set<String> = []
    @State private var skippedExpanded = false
    @State private var pinnedExpanded = true
    /// The local search filter; never persisted.
    @State private var searchText = ""

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var library: ReviewLibrary { run.library }

    /// What the body shows in place of the digest sections.
    private enum Phase {
        case loading
        case failed
        case neverRun
        case noDigestToday
        case noNewMail(lastRun: Date?)
        /// A Backlog job that has stored no digest yet, for example one waiting for the overnight window.
        case backlogPending
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

    private func provider(for emailID: String) -> ExecutionProvider? {
        switch kind {
        case .today: return todayModel.provider(for: emailID)
        case .day: return coordinator.day.providers[emailID]
        case .backlog: return coordinator.backlog.providers[emailID]
        }
    }

    /// Today's carry-over; empty elsewhere.
    private var carryOverAll: [SuggestionRecord] {
        kind == .today ? todayModel.carryOver.records.filter(\.isActionable) : []
    }

    // MARK: Search

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func matches(_ record: SuggestionRecord) -> Bool {
        ReviewSearch.matches(searchText, fields: ReviewSearch.fields(for: record))
    }

    private func matches(_ item: InfoItem) -> Bool {
        ReviewSearch.matches(searchText, fields: ReviewSearch.fields(for: item, email: email(for: item.emailID)))
    }

    /// Today's carry-over after the search filter.
    private var carryOver: [SuggestionRecord] { carryOverAll.filter(matches) }

    /// The suggestions of this canvas's own digests that are shown, after the Q16 page and the search filter.
    private var visibleRecords: [SuggestionRecord] { page.visible.filter(matches) }

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
    private var shownInfo: [InfoItem] { (content?.info ?? []).filter(matches) }
    private var shownPinned: [InfoItem] { pinned.map(\.item).filter(matches) }
    private var shownSkipped: [SkippedEmail] {
        (content?.skipped ?? []).filter { ReviewSearch.matches(searchText, fields: ReviewSearch.fields(for: $0)) }
    }

    /// The model behind "Show all" for Today and a Day.
    private var pagedModel: DayCanvasModel? {
        switch kind {
        case .today: return todayModel.digests
        case .day: return coordinator.day
        case .backlog: return nil
        }
    }

    /// Exactly the actionable records this canvas shows, in on-screen order.
    private var shownRecords: [SuggestionRecord] { carryOver + visibleRecords }

    /// Whether actionable suggestions of this view are hidden from the triage scope, by the Q16 page, unloaded
    /// carry-over pages or the search filter. The triage bar then says "N selected of M shown".
    private var isPartial: Bool {
        page.isPartial || (kind == .today && todayModel.hasMoreCarryOver)
            || (isSearching && carryOverAll.count + page.visible.count > shownRecords.count)
    }

    /// ⌘A and ⌘⇧A act on the focused card's section, or on everything shown when no card has focus.
    private func sectionRecords(_ focusedID: UUID?) -> [SuggestionRecord] {
        guard let id = focusedID else { return shownRecords }
        if carryOver.contains(where: { $0.id == id }) { return carryOver }
        if visibleRecords.contains(where: { $0.id == id }) { return visibleRecords }
        return shownRecords
    }

    // MARK: Phase and titles

    private var phase: Phase {
        guard let content else {
            if case .backlog(let id) = kind, !loadFailed, library.isDigestless(backlog: id) { return .backlogPending }
            return loadFailed ? .failed : .loading
        }
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
            let hasHistory = !library.archive.months.isEmpty || !library.archive.backlogs.isEmpty || !carryOverAll.isEmpty
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
        // All suggestions whatever their status, so the number holds still while the user triages.
        return ReviewPresentation.countsSubtitle(emailCount: content.emailCount, suggestionCount: content.records.count)
    }

    // MARK: Body

    var body: some View {
        CanvasScaffold(run: run, access: access, title: title, subtitle: subtitle,
                       headline: content?.headline ?? "", records: shownRecords, isPartial: isPartial,
                       header: kind == .today ? AnyView(todayHeader) : nil, sectionRecords: sectionRecords,
                       revealTarget: revealTarget) { focus in
            if kind == .today, case .digest = phase { todaySummary }
            if case .backlog = kind { batchBar }
            if !carryOverAll.isEmpty, !carryOver.isEmpty || !isSearching { carryOverSection(focus) }
            switch phase {
            case .loading:
                ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: carryOverAll.isEmpty ? 160 : 40)
            case .failed:
                emptyState("Couldn't Load This Digest", systemImage: "exclamationmark.triangle",
                           "Mail Digest couldn't read this digest from its database.",
                           action: EmptyAction(title: "Try Again") { Task { await coordinator.loadSelected() } })
            case .neverRun, .noDigestToday:
                emptyState("No Digest Yet", systemImage: "envelope.open", nextDigestLine,
                           action: EmptyAction(title: "Run Now", isDisabled: run.isRunning) { Task { await run.runNow() } })
            case .backlogPending:
                backlogPendingState
            case .noNewMail:
                emptyState("Inbox Zero for Today", systemImage: "tray", "No new mail since yesterday's digest.")
            case .digest:
                if isSearching, shownRecords.isEmpty, settled.filter(matches).isEmpty, shownInfo.isEmpty,
                   shownPinned.isEmpty, shownSkipped.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    suggestionsSection(focus)
                    infoSection
                    skippedSection
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search This Page")
    }

    /// What a Backlog job with no results yet says, by why it is idle.
    @ViewBuilder private var backlogPendingState: some View {
        let job: Job? = { if case .backlog(let id) = kind { return library.backlogJobs[id] } else { return nil } }()
        if let job, BacklogRowText.isScheduled(job) {
            let s = run.settings.settings
            let window = QuietHours(startMinute: s.quietHoursStartMinute, endMinute: s.quietHoursEndMinute)
            let hours = window.startMinute == window.endMinute
                ? "whenever your Mac is plugged in"
                : "between \(BacklogEstimate.clockText(minute: window.startMinute)) and \(BacklogEstimate.clockText(minute: window.endMinute)) while your Mac is plugged in"
            ContentUnavailableView("Scheduled", systemImage: "moon.zzz",
                                   description: Text("This job runs \(hours). Suggestions show up here as each batch finishes."))
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView("No Results Yet", systemImage: "tray",
                                   description: Text("Suggestions show up here as each email finishes."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: Today header

    private var todayHeader: some View {
        TodayHeader(now: .now, calendar: library.calendar, fullName: NSFullUserName(), headline: content?.headline ?? "")
    }

    /// The stat strip and the run line under it.
    @ViewBuilder private var todaySummary: some View {
        if let content {
            VStack(alignment: .leading, spacing: 10) {
                TodayStatStrip(emailsRead: content.emailCount, toReview: actionable.count, worthKnowing: content.info.count,
                               skipped: content.skipped.count, onShowSkipped: { skippedExpanded = true })
                TodayRunLine(info: todayModel.runInfo, calendar: library.calendar,
                             waitingCount: max(0, library.archive.carryOverCount - carryOverAll.count),
                             openReviewQueue: { coordinator.select(.reviewQueue) })
            }
        }
    }

    /// A button under an empty state's line.
    private struct EmptyAction {
        let title: String
        var isDisabled = false
        let perform: () -> Void
    }

    /// "Your first digest runs tomorrow at 6:30 am." with the configured time.
    private var nextDigestLine: String {
        let s = run.settings.settings
        let when = NextDigestText.when(now: .now, hour: s.runHour, minute: s.runMinute, timeZone: library.calendar.timeZone)
        return "Your \(library.archive.months.isEmpty && library.archive.backlogs.isEmpty ? "first" : "next") digest runs \(when)."
    }

    /// A full-size empty state, or one quiet line beneath the carry-over when that is on screen. The empty
    /// state describes only this canvas's own digests, so it never replaces the carry-over.
    @ViewBuilder
    private func emptyState(_ title: String, systemImage: String, _ detail: String, action: EmptyAction? = nil) -> some View {
        if carryOverAll.isEmpty {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(detail)
            } actions: {
                if let action {
                    Button(action.title, action: action.perform).disabled(action.isDisabled)
                }
            }
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
                                     count: carryOverAll.count, records: carryOver, focus: focus,
                                     countText: isSearching ? ReviewCanvasLogic.countText(shown: carryOver.count, total: carryOverAll.count) : nil,
                                     headingStyle: .heading)
            if todayModel.hasMoreCarryOver {
                HStack {
                    Text(ReviewCanvasLogic.showingText(
                        shown: carryOverAll.count, total: max(library.archive.carryOverCount, carryOverAll.count)))
                        .foregroundStyle(.secondary)
                    Button("More unreviewed suggestions are in the Review Queue") { coordinator.select(.reviewQueue) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func suggestionsSection(_ focus: FocusState<UUID?>.Binding) -> some View {
        let settledShown = settled.filter(matches)
        // Today with every suggestion decided: the empty state replaces the empty "To Review" list.
        let allDecided = kind == .today && !isSearching && actionable.isEmpty && carryOverAll.isEmpty && !settled.isEmpty
        return VStack(alignment: .leading, spacing: 26) {
            if allDecided {
                ContentUnavailableView {
                    Label("All Caught Up", systemImage: "checkmark.circle")
                } description: {
                    Text("Every suggestion today has been added or dismissed.")
                } actions: {
                    Button("Open Logbook") { coordinator.select(.logbook) }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .id(TodayStatStrip.reviewID)
            } else {
                ActionableRecordsSection(coordinator: coordinator, title: "To Review",
                                         count: actionable.count, records: visibleRecords, focus: focus,
                                         emptyText: isSearching ? "No matching suggestions."
                                             : (settled.isEmpty ? "No reminders suggested." : "Nothing left to review."),
                                         countText: isSearching ? ReviewCanvasLogic.countText(shown: visibleRecords.count, total: page.totalCount)
                                                                : page.countText,
                                         scopeAction: scopeAction, headingStyle: .heading)
                    .id(TodayStatStrip.reviewID)
            }
            if !settledShown.isEmpty {
                SettledRecordsSection(title: "Reviewed", records: settledShown, calendar: library.calendar)
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

    private var infoContext: InfoContext {
        InfoContext(
            email: { email(for: $0) }, provider: { provider(for: $0) },
            notesState: { coordinator.notes.states[$0.id] ?? .idle }, userNames: [NSFullUserName()],
            onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: $0.emailID)) },
            onTogglePin: { item in Task { await coordinator.setPinned(!item.pinned, item: item) } },
            onSaveToNotes: { item in Task { await coordinator.saveToNotes(item) } })
    }

    /// When an info item's digest was created, in the settings time zone: the "same digest day" of grouping.
    private func infoDay(_ item: InfoItem) -> DigestDay? {
        let created: Date?
        switch kind {
        case .today:
            created = todayModel.digests.infoOwners[item.id]?.createdAt
                ?? todayModel.carriedPins.first { $0.item.id == item.id }?.digestCreatedAt
        case .day: created = coordinator.day.infoOwners[item.id]?.createdAt
        case .backlog: created = coordinator.backlog.infoOwners[item.id]?.createdAt
        }
        return created.map { DigestDay($0, calendar: library.calendar) }
    }

    private func clusters(_ items: [InfoItem]) -> [InfoCluster] {
        var emails: [String: EmailContext] = [:]
        for item in items { emails[item.emailID] = email(for: item.emailID) }
        return InfoClustering.clusters(items, emails: emails, day: infoDay)
    }

    @ViewBuilder private var infoSection: some View {
        let items = shownInfo
        let pinnedItems = shownPinned
        if !items.isEmpty || !pinnedItems.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Worth Knowing", detail: nil) { EmptyView() }
                // Pinned items from earlier digests come first, as their own group, until they are unpinned.
                if !pinnedItems.isEmpty {
                    DisclosureGroup(isExpanded: $pinnedExpanded) {
                        clusterViews(pinnedItems).padding(.top, 8)
                    } label: {
                        Label("Pinned (\(pinnedItems.count))", systemImage: "pin.fill")
                            .font(.body.weight(.medium))
                    }
                }
                clusterViews(items)
            }
            .id(TodayStatStrip.infoID)
        }
    }

    /// Cards in a two-column grid; newsletters get slim full-width rows below.
    @ViewBuilder private func clusterViews(_ items: [InfoItem]) -> some View {
        let all = clusters(items)
        let cards = all.filter { $0.category != .newsletters }
        let slim = all.filter { $0.category == .newsletters }
        if !cards.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(cards) { clusterCard($0, layout: .card) }
            }
        }
        if !slim.isEmpty {
            LazyVStack(spacing: 8) {
                ForEach(slim) { clusterCard($0, layout: .slim) }
            }
        }
    }

    private func clusterCard(_ cluster: InfoCluster, layout: InfoClusterCard.Layout) -> some View {
        InfoClusterCard(cluster: cluster, layout: layout, context: infoContext,
                        isExpanded: Binding(
                            get: { expandedClusters.contains(cluster.id) },
                            set: { open in
                                if open { expandedClusters.insert(cluster.id) } else { expandedClusters.remove(cluster.id) }
                            }))
            .id(Self.clusterScrollID(cluster))
    }

    private static func clusterScrollID(_ cluster: InfoCluster) -> String { "cluster-\(cluster.id)" }

    // MARK: Skipped

    @ViewBuilder private var skippedSection: some View {
        let skipped = shownSkipped
        if !skipped.isEmpty {
            // Collapsed by default; a search that matches opens nothing on its own.
            DisclosureGroup(isExpanded: $skippedExpanded) {
                GroupedCard {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(skipped) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(ReviewPresentation.senderName(item.sender)) · \(item.subject)")
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text(item.reason).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                            if item.id != skipped.last?.id { Divider().padding(.leading, 12) }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Skipped").font(.system(size: 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(skipped.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .id(TodayStatStrip.skippedID)
        }
    }

    // MARK: Reveal

    /// The scroll id for an email a job popover asked to show; clears the search and opens a group card or
    /// pinned group that holds it.
    private func revealTarget(_ emailID: String) -> AnyHashable? {
        searchText = ""
        if let record = (carryOverAll + actionable + settled).first(where: { $0.suggestion.emailID == emailID }) {
            return record.id
        }
        if let item = content?.info.first(where: { $0.emailID == emailID }),
           let cluster = clusters(content?.info ?? []).first(where: { $0.items.contains { $0.id == item.id } }) {
            if cluster.isGroup { expandedClusters.insert(cluster.id) }
            return Self.clusterScrollID(cluster)
        }
        if let item = pinned.map(\.item).first(where: { $0.emailID == emailID }),
           let cluster = clusters(pinned.map(\.item)).first(where: { $0.items.contains { $0.id == item.id } }) {
            pinnedExpanded = true
            if cluster.isGroup { expandedClusters.insert(cluster.id) }
            return Self.clusterScrollID(cluster)
        }
        return nil
    }
}
