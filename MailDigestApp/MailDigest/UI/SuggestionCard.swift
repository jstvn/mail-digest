import AppKit
import MailDigestCore
import SwiftUI

extension EnvironmentValues {
    /// Set by the canvas when Return is pressed on a focused card: the card with this id starts editing its title.
    @Entry var cardEditRequest: Binding<UUID?> = .constant(nil)
}

/// One suggested reminder as a card: checkbox, sender avatar, editable title with pills, the sender and quote,
/// and the relative due date. Edits are committed through `onEdit`; if the model rejects one, the field
/// reverts and says why. Decided suggestions (added or dismissed) are read-only.
struct SuggestionCard: View {
    let record: SuggestionRecord
    let isSelected: Bool
    let isFocused: Bool
    /// The Q38 calendar, so dates agree with the rest of the window.
    let calendar: Calendar
    var now: Date = .now
    /// Whether Try Again can reach Reminders.
    var canRetry = true
    var onToggle: () -> Void = {}
    var onEdit: (SuggestionEdit) async throws -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onRetry: () -> Void = {}
    /// Called when title editing ends, so the canvas can put keyboard focus back on the card.
    var onEndTitleEdit: () -> Void = {}

    /// Local copy of the editable fields so controls respond instantly while the edit is saved.
    private struct Draft: Equatable {
        var title: String
        var hasDue: Bool
        var due: Date
        var hasTime: Bool
        var priority: Priority
        var category: Category

        init(_ s: Suggestion, category: Category, calendar: Calendar, now: Date) {
            title = s.title
            hasDue = s.due != nil
            due = s.due ?? calendar.startOfDay(for: now.addingTimeInterval(86_400))
            hasTime = s.dueHasTime
            priority = s.priority
            self.category = category
        }
    }

    @State private var draft: Draft
    @State private var errorText: String?
    @State private var hovering = false
    @State private var showDatePopover = false
    /// The title is plain `Text` until editing starts: a `TextField` is greedy and would push the pills away.
    @State private var isEditingTitle = false
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cardEditRequest) private var editRequest

    init(record: SuggestionRecord, isSelected: Bool, isFocused: Bool, calendar: Calendar, now: Date = .now,
         canRetry: Bool = true, onToggle: @escaping () -> Void = {},
         onEdit: @escaping (SuggestionEdit) async throws -> Void = { _ in }, onOpen: @escaping () -> Void = {},
         onDismiss: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {},
         onEndTitleEdit: @escaping () -> Void = {}) {
        self.record = record
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.calendar = calendar
        self.now = now
        self.canRetry = canRetry
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self.onRetry = onRetry
        self.onEndTitleEdit = onEndTitleEdit
        _draft = State(initialValue: Draft(record.suggestion, category: record.category, calendar: calendar, now: now))
    }

    private var suggestion: Suggestion { record.suggestion }
    private var category: Category { record.category }
    private var senderName: String { record.email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender" }

    /// Pending and failed suggestions can be edited; approved and dismissed ones are read-only.
    private var isEditable: Bool { suggestion.status == .pending || suggestion.status == .failed }
    /// Hover or keyboard focus reveals the quiet affordances.
    private var isRevealed: Bool { hovering || isFocused }

    // MARK: Body

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingControl
            SenderAvatar(sender: record.email?.sender ?? "", size: .large)
            VStack(alignment: .leading, spacing: 3) {
                // No Spacer here: the pills follow the title, and a long title truncates before they are squeezed.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleView
                    pills
                }
                quoteLine
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                if suggestion.status == .failed { failureNote }
            }
            // Takes the free width so the due-date column stays at the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            dueColumn
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .cardSurface(isFocused: isFocused)
        .opacity(isEditable ? 1 : 0.7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onChange(of: suggestion) { _, new in
            draft = Draft(new, category: category, calendar: calendar, now: now)
        }
        .onChange(of: category) { _, new in draft.category = new }
        .onChange(of: editRequest.wrappedValue) { _, id in
            guard id == record.id else { return }
            editRequest.wrappedValue = nil
            if isEditable { beginTitleEdit() }
        }
        .contextMenu {
            if isEditable { contextMenuItems } else { Button("Open in Mail", action: onOpen) }
            SenderRuleMenuItems(sender: record.email?.sender)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SuggestionAccessibility.label(for: record, isSelected: isSelected, now: now, calendar: calendar))
        .accessibilityActions { accessibilityActions }
    }

    // MARK: Leading control

    @ViewBuilder private var leadingControl: some View {
        if isEditable {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(SuggestionCheckboxStyle())
                .labelsHidden()
                .help(isSelected ? "Deselect this suggestion" : "Select this suggestion")
        } else {
            let added = suggestion.status == .approved
            Image(systemName: added ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(added ? Color.green : Color.secondary)
                .frame(width: SuggestionCheckboxStyle.width, height: SuggestionCheckboxStyle.width)
                .help(added ? "Added to Reminders" : "Dismissed")
        }
    }

    // MARK: Title and pills

    @ViewBuilder private var titleView: some View {
        if isEditable, isEditingTitle {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($titleFocused)
                .onAppear { titleFocused = true }
                .onSubmit { commitTitle(); titleFocused = false; onEndTitleEdit() }
                .onExitCommand { draft.title = suggestion.title; titleFocused = false; onEndTitleEdit() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle(); isEditingTitle = false }
                }
                .accessibilityLabel("Reminder Title")
        } else {
            Text(isEditable ? draft.title : suggestion.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2) { if isEditable { beginTitleEdit() } }
        }
    }

    private func beginTitleEdit() {
        isEditingTitle = true
        titleFocused = true
    }

    @ViewBuilder private var pills: some View {
        HStack(spacing: 6) {
            if isEditable {
                // High is always on show, so it leads. Medium and Low appear only on hover, so they trail the
                // tag: their hidden slot then never leaves a gap between the title and the next pill.
                if draft.priority == .high { priorityMenu }
            } else if suggestion.priority == .high {
                PriorityBadge(level: .high)
            }
            if !suggestion.flags.isEmpty {
                ReviewPill().help(suggestion.flags.map(ReviewPresentation.flagDescription).joined(separator: "\n"))
            }
            if isEditable { categoryMenu } else { TagPill(text: "#\(category.rawValue)") }
            if isEditable, draft.priority != .high { priorityMenu }
        }
        .fixedSize()
        // On the row, not the menu: the menu moves when High changes, and its own onChange would go with it.
        .onChange(of: draft.priority) { _, new in
            if new != suggestion.priority { commit(SuggestionEdit(priority: new)) }
        }
    }

    private var level: PriorityBadge.Level {
        switch draft.priority { case .high: .high; case .medium: .medium; case .low: .low }
    }

    /// High always shows; Medium and Low show their marks only on hover or focus, so the card stays calm.
    private var priorityMenu: some View {
        Menu {
            Picker("Priority", selection: $draft.priority) {
                ForEach([Priority.high, .medium, .low], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PriorityBadge(level: level)
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(draft.priority == .high || isRevealed ? 1 : 0)
        .allowsHitTesting(draft.priority == .high || isRevealed)
        .help("Change the priority")
        .accessibilityLabel("Priority")
        .accessibilityValue(draft.priority.label)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $draft.category) {
                ForEach(Category.allCases, id: \.self) { Text("#\($0.rawValue)").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            TagPill(text: "#\(draft.category.rawValue)")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: draft.category) { _, new in
            if new != category { commit(SuggestionEdit(category: new)) }
        }
        .help("Category tag added to the reminder")
        .accessibilityLabel("Category")
        .accessibilityValue(draft.category.rawValue)
    }

    // MARK: Second line

    private var quoteLine: some View {
        HStack(spacing: 6) {
            (Text(senderName).foregroundStyle(.primary) + Text(" · ").foregroundStyle(.secondary)
                + Text("“\(suggestion.evidence)”").italic().foregroundStyle(.secondary))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .help("“\(suggestion.evidence)”")
            Spacer(minLength: 0)
            Button(action: onOpen) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open this email in Mail")
                .accessibilityLabel("Open Email in Mail")
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)
        }
    }

    private var failureNote: some View {
        HStack(spacing: 4) {
            Text("Couldn't add to Reminders.").foregroundStyle(.orange)
            Button("Try Again", action: onRetry)
                .buttonStyle(.link)
                .disabled(!canRetry)
                .help(canRetry ? "Add this suggestion to Reminders again" : "Reminders access isn't available")
        }
        .font(.caption)
    }

    // MARK: Due date

    private var dueColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isEditable {
                if draft.hasDue {
                    Button { showDatePopover = true } label: {
                        RelativeDueLabel(due: draft.due, hasTime: draft.hasTime, calendar: calendar, now: now)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Change the due date")
                } else {
                    RelativeDueLabel(due: nil, calendar: calendar, now: now)
                    Button("Add Date", action: addDate)
                        .buttonStyle(.link)
                        .help("Add a due date")
                }
            } else {
                RelativeDueLabel(due: suggestion.due, hasTime: suggestion.dueHasTime, calendar: calendar, now: now)
            }
        }
        .frame(width: 132, alignment: .trailing)
        .popover(isPresented: $showDatePopover, arrowEdge: .bottom) { datePopover }
    }

    /// Starts from the default day so the popover edits a real date.
    private func addDate() {
        draft.hasDue = true
        commit(SuggestionEdit(due: .some(draft.due)))
        showDatePopover = true
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Due Date", selection: $draft.due, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: draft.due) { _, new in
                    if new != suggestion.due { commit(SuggestionEdit(due: .some(new))) }
                }
            Toggle("Include Time", isOn: $draft.hasTime)
                .onChange(of: draft.hasTime) { _, on in
                    // Remove Date also clears the time flag; it must not re-commit the date it just removed.
                    if draft.hasDue, on != suggestion.dueHasTime { commit(SuggestionEdit(due: .some(draft.due), dueHasTime: on)) }
                }
            if draft.hasTime {
                DatePicker("Time", selection: $draft.due, displayedComponents: [.hourAndMinute])
            }
            HStack {
                Button("Remove Date", role: .destructive) {
                    draft.hasDue = false
                    draft.hasTime = false
                    showDatePopover = false
                    commit(SuggestionEdit(due: .some(nil)))
                }
                Spacer()
                Button("Done") { showDatePopover = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
    }

    // MARK: Menu and accessibility actions

    @ViewBuilder private var contextMenuItems: some View {
        Button(isSelected ? "Deselect" : "Select", action: onToggle)
        Button("Edit Title", action: beginTitleEdit)
        Button(draft.hasDue ? "Change Due Date…" : "Add Due Date…") { draft.hasDue ? (showDatePopover = true) : addDate() }
        Menu("Priority") {
            Picker("Priority", selection: $draft.priority) {
                ForEach([Priority.high, .medium, .low], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        }
        Menu("Category") {
            Picker("Category", selection: $draft.category) {
                ForEach(Category.allCases, id: \.self) { Text("#\($0.rawValue)").tag($0) }
            }
            .pickerStyle(.inline)
        }
        Divider()
        Button("Open in Mail", action: onOpen)
        if suggestion.status == .pending { Button("Dismiss", role: .destructive, action: onDismiss) }
    }

    @ViewBuilder private var accessibilityActions: some View {
        if isEditable {
            Button(isSelected ? "Deselect" : "Select", action: onToggle)
            if suggestion.status == .pending { Button("Dismiss", action: onDismiss) }
            Button("Edit Title", action: beginTitleEdit)
            Button(draft.hasDue ? "Change Due Date" : "Add Due Date") { draft.hasDue ? (showDatePopover = true) : addDate() }
            if suggestion.status == .failed, canRetry { Button("Try Again", action: onRetry) }
        }
        Button("Open in Mail", action: onOpen)
    }

    // MARK: Commit

    private func commitTitle() {
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != suggestion.title else { draft.title = suggestion.title; return }
        commit(SuggestionEdit(title: draft.title))
    }

    private func commit(_ edit: SuggestionEdit) {
        Task {
            do {
                try await onEdit(edit)
                errorText = nil
            } catch {
                // Revert so the field shows what is actually saved.
                draft = Draft(suggestion, category: category, calendar: calendar, now: now)
                errorText = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? ReviewError {
        case .invalidTitle: return "Titles need 3 to 80 characters and can't contain links."
        case .notEditable: return "This reminder can't be edited any more."
        default: return "The change couldn't be saved."
        }
    }
}

extension Priority {
    /// Menu text.
    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

#if DEBUG
/// Sample cards covering every state: selected with a date, unselected without one, needs review, write failed,
/// medium priority, and read-only (added and dismissed).
@MainActor enum SuggestionCardPreviewData {
    struct Sample: Identifiable {
        var id: UUID { record.id }
        var record: SuggestionRecord
        var isSelected: Bool
        var isFocused = false
    }

    static var samples: [Sample] {
        var records = SuggestionRecord.records(from: PreviewFixtures.digest, kind: .daily, emails: PreviewFixtures.emails)
        guard records.count >= 4 else { return [] }
        let now = PreviewFixtures.now
        records[0].suggestion.due = now.addingTimeInterval(11 * 86_400)
        records[0].suggestion.dueHasTime = true
        records[1].suggestion.due = nil
        records[1].suggestion.dueHasTime = false
        records[2].suggestion.flags = ["money-new-sender"]
        records[3].suggestion.status = .failed
        records[3].suggestion.flags = []
        var added = records[0]
        added.suggestion.id = UUID()
        added.suggestion.status = .approved
        var dismissed = records[1]
        dismissed.suggestion.id = UUID()
        dismissed.suggestion.status = .dismissed
        return [
            Sample(record: records[0], isSelected: true),
            Sample(record: records[1], isSelected: false, isFocused: true),
            Sample(record: records[2], isSelected: false),
            Sample(record: records[3], isSelected: true),
            Sample(record: added, isSelected: false),
            Sample(record: dismissed, isSelected: false),
        ]
    }
}

#Preview("Suggestion cards") {
    VStack(spacing: 12) {
        ForEach(SuggestionCardPreviewData.samples) { sample in
            SuggestionCard(record: sample.record, isSelected: sample.isSelected, isFocused: sample.isFocused,
                           calendar: PreviewSupport.calendar, now: PreviewFixtures.now)
        }
    }
    .padding(24).frame(width: 760)
}
#endif
