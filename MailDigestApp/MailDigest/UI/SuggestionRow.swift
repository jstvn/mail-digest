import MailDigestCore
import SwiftUI

/// One suggested reminder: checkbox, editable title, metadata pills and the evidence quote.
/// Edits are committed through `onEdit`; if the model rejects one, the field reverts and says why.
struct SuggestionRow: View {
    let record: SuggestionRecord
    let isSelected: Bool
    let isFocused: Bool
    var onToggle: () -> Void = {}
    var onEdit: (SuggestionEdit) async throws -> Void = { _ in }
    var onOpen: () -> Void = {}

    /// Local copy of the editable fields so controls respond instantly while the edit is saved.
    private struct Draft: Equatable {
        var title: String
        var hasDue: Bool
        var due: Date
        var hasTime: Bool
        var priority: Priority
        var category: Category

        init(_ s: Suggestion, category: Category) {
            title = s.title
            hasDue = s.due != nil
            due = s.due ?? Calendar.current.startOfDay(for: Date.now.addingTimeInterval(86_400))
            hasTime = s.dueHasTime
            priority = s.priority
            self.category = category
        }
    }

    @State private var draft: Draft
    @State private var errorText: String?
    @State private var hovering = false
    @State private var showDatePopover = false
    @FocusState private var titleFocused: Bool
    @FocusState private var addDateFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The settings time zone, so dates read the same as in the rest of the window.
    var timeZone: TimeZone = RunnerSettings().timeZone

    init(record: SuggestionRecord, isSelected: Bool, isFocused: Bool,
         onToggle: @escaping () -> Void = {}, onEdit: @escaping (SuggestionEdit) async throws -> Void = { _ in },
         onOpen: @escaping () -> Void = {}, timeZone: TimeZone = RunnerSettings().timeZone) {
        self.timeZone = timeZone
        self.record = record
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onOpen = onOpen
        _draft = State(initialValue: Draft(record.suggestion, category: record.category))
    }

    private var suggestion: Suggestion { record.suggestion }
    private var category: Category { record.category }
    private var email: EmailContext? { record.email }

    private var isEditable: Bool { suggestion.status == .pending || suggestion.status == .failed }
    /// Hover, row focus or keyboard focus on the Add Date pill reveals the quiet affordances.
    private var isRevealed: Bool { hovering || isFocused || addDateFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Line 1: checkbox, title (truncates), then the pills on the trailing edge.
            HStack(alignment: .center, spacing: 10) {
                Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                    .toggleStyle(SuggestionCheckboxStyle())
                    .labelsHidden()
                    .disabled(!isEditable)
                    .accessibilityLabel("Select \(suggestion.title)")
                titleField.layoutPriority(1)
                Spacer(minLength: 8)
                pills.fixedSize()
            }
            // Line 2 and the notes sit under the title, so they share its leading edge.
            VStack(alignment: .leading, spacing: 4) {
                EvidenceQuote(sender: email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender",
                              evidence: suggestion.evidence, emphasised: isRevealed, onOpen: onOpen)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                        .accessibilityLabel("Edit not saved. \(errorText)")
                }
                if suggestion.status == .failed {
                    Text("Couldn't be added to Reminders. Select it to try again.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.leading, SuggestionCheckboxStyle.width + 10)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            } else if hovering {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.02))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onChange(of: suggestion) { _, new in draft = Draft(new, category: category) }
        .onChange(of: category) { _, new in draft.category = new }
    }

    // MARK: Title and pills

    private var titleField: some View {
        TextField("Title", text: $draft.title)
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            .disabled(!isEditable)
            .accessibilityLabel("Reminder title")
    }

    @ViewBuilder private var pills: some View {
        if isEditable {
            HStack(spacing: 6) {
                datePill
                priorityMenu
                categoryMenu
                flagPill
            }
        } else {
            HStack(spacing: 6) {
                StaticSuggestionPills(suggestion: suggestion, category: category, timeZone: timeZone)
                flagPill
            }
        }
    }

    private var dateText: String {
        PillDateText.string(draft.due, hasTime: draft.hasTime, timeZone: timeZone)
    }

    /// The popover is anchored to a stable wrapper so it survives the pill switching from Add Date to the date.
    private var datePill: some View {
        HStack(spacing: 0) {
            if draft.hasDue {
                MetaPill(text: dateText, symbol: "calendar", help: "Change the due date",
                         accessibilityTitle: "Due date", accessibilityValue: dateText) {
                    showDatePopover = true
                }
            } else {
                MetaPill(text: "Add Date", symbol: "calendar.badge.plus", isGhost: true, help: "Add a due date",
                         accessibilityTitle: "Due date", accessibilityValue: "None. Add date") {
                    // Start from the default day so the popover edits a real date.
                    draft.hasDue = true
                    commit(SuggestionEdit(due: .some(draft.due)))
                    showDatePopover = true
                }
                .focused($addDateFocused)
                // Hidden visually but still focusable and exposed to VoiceOver. It keeps its slot so the other
                // pills stay flush right, and ignores clicks while invisible (a click would write a due date).
                .opacity(isRevealed || showDatePopover ? 1 : 0)
                .allowsHitTesting(isRevealed || showDatePopover)
            }
        }
        .popover(isPresented: $showDatePopover, arrowEdge: .bottom) { datePopover }
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Due date", selection: $draft.due, displayedComponents: [.date])
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
        .environment(\.timeZone, timeZone)
    }

    private var priorityMenu: some View {
        Menu {
            Picker("Priority", selection: $draft.priority) {
                ForEach([Priority.high, .medium, .low], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MetaPillLabel(text: draft.priority.label, tint: draft.priority.pillTint, isInteractive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: draft.priority) { _, new in
            if new != suggestion.priority { commit(SuggestionEdit(priority: new)) }
        }
        .help("Priority")
        .metaPillAccessibility(title: "Priority", value: draft.priority.label)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $draft.category) {
                ForEach(Category.allCases, id: \.self) { Text("#\($0.rawValue)").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MetaPillLabel(text: "#\(draft.category.rawValue)", tint: .accentColor, isInteractive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: draft.category) { _, new in
            if new != category { commit(SuggestionEdit(category: new)) }
        }
        .help("Category tag added to the reminder")
        .metaPillAccessibility(title: "Category", value: draft.category.rawValue)
    }

    @ViewBuilder private var flagPill: some View {
        if !suggestion.flags.isEmpty {
            let text = suggestion.flags.map(ReviewPresentation.flagDescription).joined(separator: "\n")
            MetaPillLabel(text: "Review", symbol: "exclamationmark.triangle.fill", tint: .orange)
                .help(text)
                .accessibilityLabel("Needs review")
                .accessibilityHint(text)
        }
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
                draft = Draft(suggestion, category: category)
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

/// Sample rows in every state: dated with time, no date, flagged, failed and not editable.
@MainActor private func previewRecords() -> [SuggestionRecord] {
    var records = SuggestionRecord.records(from: PreviewFixtures.digest, kind: .daily, emails: PreviewFixtures.emails)
    guard records.count >= 4 else { return records }
    records[0].suggestion.due = PreviewFixtures.now
    records[0].suggestion.dueHasTime = true
    records[1].suggestion.due = nil
    records[1].suggestion.dueHasTime = false
    records[2].suggestion.flags = ["money-new-sender"]
    records[3].suggestion.status = .failed
    var settled = records[0]
    settled.suggestion.id = UUID()
    settled.suggestion.status = .approved
    records.append(settled)
    return records
}

#Preview("Suggestion rows") {
    VStack(spacing: 0) {
        ForEach(previewRecords()) { r in
            SuggestionRow(record: r, isSelected: r.suggestion.preselected, isFocused: r.id == PreviewFixtures.ID.submitA2)
        }
    }
    .padding().frame(width: 700)
}
