import AppKit
import MailDigestCore
import SwiftUI

/// Every pending and failed suggestion across Daily and Backlog digests, grouped by digest date and loaded in
/// pages: a list on the left and an inspector for the selected suggestion on the right.
///
/// The list checkboxes are for bulk actions; the inspector acts on the selected row. The filter menu and the
/// search field are local and in memory, and bulk actions touch only the rows they leave visible (Q16, Q58).
struct ReviewQueueView: View {
    let run: DigestRunModel
    let access: MailAccessModel

    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var filter = ReviewQueueFilter()
    /// Bumped by Return in the list so the inspector puts the cursor in the title.
    @State private var titleFocusRequest = 0

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var queue: PagedRecordsModel { coordinator.reviewQueue }
    private var calendar: Calendar { run.library.calendar }

    private struct DayGroup: Identifiable {
        var day: DigestDay
        var records: [SuggestionRecord]
        var id: DigestDay { day }
    }

    /// Loaded groups without records that were just settled and are about to leave the list.
    private var loadedGroups: [DayGroup] {
        queue.groups.compactMap { group in
            let records = group.records.filter(\.isActionable)
            return records.isEmpty ? nil : DayGroup(day: group.day, records: records)
        }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isFiltering: Bool { filter.isActive || isSearching }

    private func visible(_ groups: [DayGroup]) -> [DayGroup] {
        guard isFiltering else { return groups }
        return groups.compactMap { group in
            let records = filter.apply(to: group.records)
                .filter { ReviewSearch.matches(searchText, fields: ReviewSearch.fields(for: $0)) }
            return records.isEmpty ? nil : DayGroup(day: group.day, records: records)
        }
    }

    var body: some View {
        let loaded = loadedGroups
        let groups = visible(loaded)
        let loadedCount = loaded.reduce(0) { $0 + $1.records.count }
        let shown = groups.flatMap(\.records)
        let ids = shown.map(\.id)
        Group {
            if !queue.isLoaded {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if queue.loadFailed && loadedCount == 0 {
                ContentUnavailableView {
                    Label("Couldn't Load the Review Queue", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Try again in a moment.")
                } actions: {
                    Button("Try Again") { Task { await coordinator.loadSelected() } }
                }
            } else if loadedCount == 0 {
                VStack(spacing: 0) {
                    CanvasNotices(run: run, access: access).padding(.horizontal, 20).padding(.top, 12)
                    ContentUnavailableView("Nothing to Review", systemImage: "tray",
                                           description: Text("New suggestions show up here after each digest."))
                }
            } else {
                HSplitView {
                    listColumn(groups: groups, shown: shown, loadedCount: loadedCount, allGroupCount: loaded.count)
                        .frame(minWidth: 320, idealWidth: 384, maxWidth: 520)
                    inspector(shown: shown)
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(Color.pageBackground.ignoresSafeArea())
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Review Queue")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { move(-1, in: ids) } label: { Label("Previous Suggestion", systemImage: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(ids.isEmpty)
                    .help("Previous suggestion (⌘↑)")
                Button { move(1, in: ids) } label: { Label("Next Suggestion", systemImage: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(ids.isEmpty)
                    .help("Next suggestion (⌘↓)")
                if let position = ReviewQueueNavigation.positionText(of: selection, in: ids) {
                    Text(position)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Suggestion \(position)")
                }
            }
        }
        // A settled row leaves the list: the selection moves to the next one, or clears when none remain.
        .onChange(of: ids, initial: true) { old, new in
            if selection == nil {
                selection = new.first
            } else {
                selection = ReviewQueueNavigation.selection(afterChange: selection, old: old, new: new)
            }
        }
        // ⌘A reaches here only when no text field is editing, so a field keeps its own Select All.
        .onCommand(#selector(NSResponder.selectAll(_:))) { coordinator.selectAll(sectionRecords(groups, shown)) }
        .focusedSceneValue(\.canvasSelection, CanvasSelectionActions { coordinator.selectNone(sectionRecords(groups, shown)) })
    }

    /// The records ⌘A and ⌘⇧A act on: the section of the selected row, else everything shown.
    private func sectionRecords(_ groups: [DayGroup], _ shown: [SuggestionRecord]) -> [SuggestionRecord] {
        guard let selection, let group = groups.first(where: { $0.records.contains { $0.id == selection } }) else { return shown }
        return group.records
    }

    private func move(_ offset: Int, in ids: [UUID]) {
        guard !TextEditingState.isEditing else { return }
        selection = ReviewQueueNavigation.step(from: selection, by: offset, in: ids)
    }

    // MARK: List column

    private func listColumn(groups: [DayGroup], shown: [SuggestionRecord], loadedCount: Int, allGroupCount: Int) -> some View {
        VStack(spacing: 0) {
            listHeader(groupCount: allGroupCount)
            CanvasNotices(run: run, access: access).padding(.horizontal, 16)
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                row(record)
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                    if queue.hasMore {
                        pagingRow(loaded: loadedCount)
                            .selectionDisabled()
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if groups.isEmpty {
                        if isSearching { ContentUnavailableView.search(text: searchText) }
                        else {
                            ContentUnavailableView("No Matching Suggestions", systemImage: "line.3.horizontal.decrease",
                                                   description: Text("Change or clear the filter to see more."))
                        }
                    }
                }
                .onKeyPress(phases: .down) { handleKey($0, shown: shown) }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(shown: shown) }
            }
        }
    }

    private func listHeader(groupCount: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Queue")
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(groupCount: groupCount))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            filterMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// "10 unreviewed · 3 days".
    private func subtitle(groupCount: Int) -> String {
        let total = max(run.library.archive.reviewQueueCount, 0)
        var text = "\(total) unreviewed · \(groupCount) \(groupCount == 1 ? "day" : "days")"
        if filter.isActive { text += " · Filtered" }
        return text
    }

    private var filterMenu: some View {
        Menu {
            Menu("Priority") {
                Picker("Priority", selection: $filter.priority) {
                    Text("Any").tag(Priority?.none)
                    ForEach([Priority.high, .medium, .low], id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("Category") {
                Picker("Category", selection: $filter.category) {
                    Text("Any").tag(EmailCategory?.none)
                    ForEach(EmailCategory.allCases, id: \.self) { Text("#\($0.rawValue)").tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Toggle("Has Due Date", isOn: $filter.hasDueDate)
            Divider()
            Button("Clear Filters") { filter = ReviewQueueFilter() }
                .disabled(!filter.isActive)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(filter.isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter the list by priority, category or due date")
        .accessibilityLabel("Filter")
        .accessibilityValue(filter.isActive ? "On" : "Off")
    }

    private func row(_ record: SuggestionRecord) -> some View {
        ReviewQueueRow(
            record: record, isChecked: coordinator.isSelected(record), calendar: calendar,
            onToggle: { coordinator.toggle(record) },
            onDismiss: { Task { await coordinator.dismiss(record) } },
            onOpen: { open(record) })
    }

    /// "TODAY · 3" with a Select All (Select None once every pending row of the day is ticked).
    private func groupHeader(_ group: DayGroup) -> some View {
        let isToday = group.day == DigestDay(run.library.archive.startOfToday, calendar: calendar)
        let title = isToday ? "Today" : ReviewDateText.day(group.day, calendar: calendar)
        let allTicked = group.records.allSatisfy { coordinator.isSelected($0) || $0.suggestion.status != .pending }
            && group.records.contains { coordinator.isSelected($0) }
        return HStack {
            Text("\(title) · \(group.records.count)")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(allTicked ? "Select None" : "Select All") {
                if allTicked { coordinator.selectNone(group.records) } else { coordinator.selectAll(group.records) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(allTicked ? "Deselect every suggestion of this day shown" : "Select every suggestion of this day shown")
        }
    }

    private func pagingRow(loaded: Int) -> some View {
        HStack(spacing: 12) {
            Text(ReviewCanvasLogic.showingText(shown: loaded, total: max(run.library.archive.reviewQueueCount, loaded)))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Load More") { Task { await coordinator.loadMoreReviewQueue() } }
        }
    }

    /// The bulk bar: "6 of 10 selected" and Add 6 to Reminders, over the rows the filter and search leave shown.
    private func footer(shown: [SuggestionRecord]) -> some View {
        let selected = coordinator.selectedCount(in: shown)
        let isPartial = queue.hasMore || isFiltering
        let text = isPartial
            ? ReviewCanvasLogic.selectionText(selected: selected, shown: shown.count, isPartial: true)
            : "\(selected) of \(shown.count) selected"
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Text(text).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(selected > 0 ? "Add \(selected) to Reminders" : "Add to Reminders") {
                    Task { await coordinator.addSelected(in: shown) }
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.canAddSelected(in: shown))
                .help(coordinator.reminderWriter == nil ? "Add to Reminders is off until you allow access in Privacy & Security"
                      : (isPartial ? "Add the ticked suggestions shown to Reminders. Hidden suggestions aren't affected."
                                   : "Add the ticked suggestions to Reminders"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: Keyboard

    /// Space ticks, ⌫ dismisses and Return edits the title of the selected row; ⌘A selects the section. ↑ and ↓
    /// are the list's own. Ignored while a text field is being edited.
    private func handleKey(_ press: KeyPress, shown: [SuggestionRecord]) -> KeyPress.Result {
        guard !TextEditingState.isEditing else { return .ignored }
        let record = selection.flatMap { id in shown.first { $0.id == id } }
        if press.modifiers == .command, press.characters == "a" {
            coordinator.selectAll(sectionRecords(visible(loadedGroups), shown))
            return .handled
        }
        guard press.modifiers.isEmpty, let record else { return .ignored }
        switch press.key {
        case .space:
            coordinator.toggle(record)
            return .handled
        case .return:
            titleFocusRequest += 1
            return .handled
        case .delete, .deleteForward:
            Task { await coordinator.dismiss(record) }
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Inspector

    @ViewBuilder private func inspector(shown: [SuggestionRecord]) -> some View {
        if let record = selection.flatMap({ id in shown.first { $0.id == id } }) {
            ReviewInspector(
                record: record, calendar: calendar,
                lists: run.reminders.lists, defaultListName: coordinator.defaultListName,
                defaultListID: coordinator.defaultListID,
                canAdd: coordinator.reminderWriter != nil && !coordinator.isWorking,
                addHelp: coordinator.reminderWriter == nil ? "Add to Reminders is off until you allow access in Privacy & Security"
                    : "Add this suggestion to Reminders",
                titleFocusRequest: titleFocusRequest,
                onEdit: { try await coordinator.edit($0, record: record) },
                onOpen: { open(record) },
                onAdd: { Task { await add(record.id) } },
                onDismiss: { Task { await coordinator.dismiss(record) } },
                loadRouting: { await coordinator.routing(for: record) })
            .id(record.id)
        } else {
            ContentUnavailableView("No Suggestion Selected", systemImage: "tray",
                                   description: Text("Choose a suggestion to see its details."))
        }
    }

    /// Reads the queue again, because an edit saved just before Add has replaced the record the view captured.
    private func add(_ id: UUID) async {
        guard let record = queue.groups.flatMap(\.records).first(where: { $0.id == id }) else { return }
        await coordinator.add(record)
    }

    private func open(_ record: SuggestionRecord) {
        NSWorkspace.shared.open(ReviewActions.messageURL(for: record.suggestion.emailID))
    }
}

#if DEBUG
@MainActor private func queuePreview(reminders: RemindersAuthorization = .granted) -> some View {
    let review = PreviewSupport.review()
    let coordinator = PreviewSupport.coordinator(selection: .reviewQueue, review: review)
    let run = PreviewSupport.run(review: review, coordinator: coordinator, reminders: reminders)
    return ReviewQueueView(run: run, access: MailAccessModel(preview: PreviewSupport.fastLocal))
        .frame(width: 940, height: 640)
}

#Preview("Review Queue") { queuePreview() }

#Preview("Review Queue · empty") {
    let review = PreviewSupport.review()
    let coordinator = ReviewCoordinator(preview: PreviewSupport.library(), review: review,
                                        reviewQueue: PagedRecordsModel(preview: []))
    let run = PreviewSupport.run(review: review, coordinator: coordinator)
    return ReviewQueueView(run: run, access: MailAccessModel(preview: PreviewSupport.fastLocal))
        .frame(width: 940, height: 640)
}
#endif
