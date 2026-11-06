import MailDigestCore
import SwiftUI

/// One suggested reminder: checkbox, editable title, priority, category, due date, and where it came from.
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
    @FocusState private var titleFocused: Bool

    init(record: SuggestionRecord, isSelected: Bool, isFocused: Bool,
         onToggle: @escaping () -> Void = {}, onEdit: @escaping (SuggestionEdit) async throws -> Void = { _ in },
         onOpen: @escaping () -> Void = {}) {
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!isEditable)
                .accessibilityLabel("Select \(suggestion.title)")
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                dueLine
                sourceLine
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                        .accessibilityLabel("Edit not saved. \(errorText)")
                }
                if suggestion.status == .failed {
                    Text("Couldn't be added to Reminders. Select it to try again.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isFocused ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: suggestion) { _, new in draft = Draft(new, category: category) }
        .onChange(of: category) { _, new in draft.category = new }
    }

    // MARK: Lines

    private var titleLine: some View {
        HStack(spacing: 8) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                .disabled(!isEditable)
                .accessibilityLabel("Reminder title")

            Picker("Priority", selection: $draft.priority) {
                ForEach([Priority.high, .medium, .low], id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isEditable)
            .onChange(of: draft.priority) { _, new in
                if new != suggestion.priority { commit(SuggestionEdit(priority: new)) }
            }
            .help("Priority")
            .accessibilityLabel("Priority")

            Picker("Category", selection: $draft.category) {
                ForEach(Category.allCases, id: \.self) { Text("#\($0.rawValue)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isEditable)
            .onChange(of: draft.category) { _, new in
                if new != category { commit(SuggestionEdit(category: new)) }
            }
            .help("Category tag added to the reminder")
            .accessibilityLabel("Category")

            if !suggestion.flags.isEmpty {
                let text = suggestion.flags.map(ReviewPresentation.flagDescription).joined(separator: "\n")
                Label("Review", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(text)
                    .accessibilityLabel("Needs review")
                    .accessibilityHint(text)
            }
        }
    }

    private var dueLine: some View {
        HStack(spacing: 8) {
            Toggle("Due", isOn: $draft.hasDue)
                .toggleStyle(.checkbox)
                .disabled(!isEditable)
                .onChange(of: draft.hasDue) { _, on in
                    if on != (suggestion.due != nil) {
                        commit(SuggestionEdit(due: .some(on ? draft.due : nil)))
                    }
                }
                .accessibilityLabel(draft.hasDue ? "Has a due date" : "No due date")
            if draft.hasDue {
                DatePicker("Due date", selection: $draft.due,
                           displayedComponents: draft.hasTime ? [.date, .hourAndMinute] : [.date])
                    .labelsHidden()
                    .disabled(!isEditable)
                    .onChange(of: draft.due) { _, new in
                        if new != suggestion.due { commit(SuggestionEdit(due: .some(new))) }
                    }
                Toggle("Time", isOn: $draft.hasTime)
                    .toggleStyle(.checkbox)
                    .disabled(!isEditable)
                    .onChange(of: draft.hasTime) { _, on in
                        if on != suggestion.dueHasTime { commit(SuggestionEdit(due: .some(draft.due), dueHasTime: on)) }
                    }
            } else {
                Text("No date").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            let sender = email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender"
            Text("From: \(sender) · “\(suggestion.evidence)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("“\(suggestion.evidence)”")
            Spacer(minLength: 4)
            Button(action: onOpen) { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Open this email in Mail")
                .accessibilityLabel("Open email in Mail")
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

#Preview("Suggestion rows") {
    let d = PreviewFixtures.digest
    let records = SuggestionRecord.records(from: d, kind: .daily, emails: PreviewFixtures.emails)
    return VStack(spacing: 0) {
        ForEach(records) { r in
            SuggestionRow(record: r, isSelected: r.suggestion.preselected, isFocused: r.id == PreviewFixtures.ID.submitA2)
            Divider()
        }
    }
    .padding().frame(width: 700)
}
