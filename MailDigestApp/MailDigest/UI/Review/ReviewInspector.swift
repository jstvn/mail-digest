import AppKit
import MailDigestCore
import SwiftUI

/// The Review Queue's inspector: the selected suggestion as an editable reminder, the email it came from, and
/// Dismiss and Add to Reminders. Edits are saved as you make them (through `onEdit`); nothing reaches Reminders
/// until Add. The caller gives it `.id(record.id)`, so a different suggestion starts with fresh field state.
struct ReviewInspector: View {
    let record: SuggestionRecord
    /// The Q38 calendar, so dates agree with the rest of the window.
    let calendar: Calendar
    var now: Date = .now
    /// The user's Reminders lists. Empty without access, in which case only the default list is offered.
    var lists: [ReminderListOption] = []
    var defaultListName = DigestSettings.defaultListName
    /// The default list's own id, left out of the picker because "Default" already means it.
    var defaultListID: String?
    var canAdd = true
    var addHelp = "Add this suggestion to Reminders"
    /// Bumped when Return is pressed in the list: puts the cursor in the title.
    var titleFocusRequest = 0
    var onEdit: (SuggestionEdit) async throws -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onAdd: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// Reads how the email was routed and run; nil when not recorded.
    var loadRouting: () async -> RoutingProvenance? = { nil }

    /// Local copy of the editable fields so controls respond instantly while the edit is saved.
    private struct Draft: Equatable {
        var title: String
        var hasDue: Bool
        var due: Date
        var hasTime: Bool
        var priority: Priority
        var category: Category
        var listID: String?
        var notes: String

        init(_ s: Suggestion, category: Category, defaultNotes: String?, calendar: Calendar, now: Date) {
            title = s.title
            hasDue = s.due != nil
            due = s.due ?? calendar.startOfDay(for: now.addingTimeInterval(86_400))
            hasTime = s.dueHasTime
            priority = s.priority
            self.category = category
            listID = s.reminderListID
            // With no saved notes the field shows the default line as real, editable text.
            notes = s.notes ?? defaultNotes ?? ""
        }
    }

    private enum Field { case title, notes }

    @State private var draft: Draft
    @State private var errorText: String?
    @State private var routing: RoutingProvenance?
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var scheme

    init(record: SuggestionRecord, calendar: Calendar, now: Date = .now, lists: [ReminderListOption] = [],
         defaultListName: String = DigestSettings.defaultListName, defaultListID: String? = nil,
         canAdd: Bool = true, addHelp: String = "Add this suggestion to Reminders", titleFocusRequest: Int = 0,
         onEdit: @escaping (SuggestionEdit) async throws -> Void = { _ in }, onOpen: @escaping () -> Void = {},
         onAdd: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {},
         loadRouting: @escaping () async -> RoutingProvenance? = { nil }) {
        self.record = record
        self.calendar = calendar
        self.now = now
        self.lists = lists
        self.defaultListName = defaultListName
        self.defaultListID = defaultListID
        self.canAdd = canAdd
        self.addHelp = addHelp
        self.titleFocusRequest = titleFocusRequest
        self.onEdit = onEdit
        self.onOpen = onOpen
        self.onAdd = onAdd
        self.onDismiss = onDismiss
        self.loadRouting = loadRouting
        _draft = State(initialValue: Draft(record.suggestion, category: record.category, defaultNotes: ReviewActions.defaultNotes(email: record.email), calendar: calendar, now: now))
    }

    private var suggestion: Suggestion { record.suggestion }
    private var defaultNotes: String? { ReviewActions.defaultNotes(email: record.email) }
    private var senderName: String { record.email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender" }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    listRow
                    dueRow
                    priorityRow
                    categoryRow
                    notesRow
                }
                Section {
                    emailCard
                } header: {
                    HStack {
                        Text("From Email")
                        Spacer()
                        badges
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
        .task(id: record.id) { routing = await loadRouting() }
        .onChange(of: suggestion) { _, new in
            draft = Draft(new, category: record.category, defaultNotes: defaultNotes, calendar: calendar, now: now)
        }
        .onChange(of: record.category) { _, new in draft.category = new }
        .onChange(of: titleFocusRequest) { _, _ in focus = .title }
        // Moving to another suggestion while a field is still focused must not lose what was typed.
        .onDisappear { commitTitle(); commitNotes() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overline)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .focused($focus, equals: .title)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { commitTitle(); focus = nil }
                .onExitCommand { draft.title = suggestion.title; focus = nil }
                .onChange(of: focus) { old, new in if old == .title, new != .title { commitTitle() } }
                .accessibilityLabel("Reminder Title")
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// "SUGGESTED REMINDER · FROM TODAY'S DIGEST".
    private var overline: String {
        let source: String
        if record.kind == .backlog {
            source = "From a Backlog Job"
        } else if calendar.isDate(record.digestCreatedAt, inSameDayAs: now) {
            source = "From Today's Digest"
        } else {
            let day = DigestDay(record.digestCreatedAt, calendar: calendar)
            source = "From the \(ReviewDateText.day(day, calendar: calendar)) Digest"
        }
        return "Suggested Reminder · \(source)"
    }

    // MARK: Form rows

    /// The chosen list, or nil (the default) when it has since been deleted, so the picker never shows a blank.
    private var listSelection: Binding<String?> {
        Binding(
            get: { draft.listID.flatMap { id in lists.contains { $0.id == id } ? id : nil } },
            set: { draft.listID = $0 })
    }

    private var listRow: some View {
        Picker("List", selection: listSelection) {
            Text("\(defaultListName) (Default)").tag(String?.none)
            ForEach(lists.filter { $0.id != defaultListID }) { list in
                Text(list.title).tag(Optional(list.id))
            }
        }
        .onChange(of: draft.listID) { _, new in
            if new != suggestion.reminderListID { commit(SuggestionEdit(reminderListID: .some(new))) }
        }
        .help("The Reminders list this is added to")
    }

    private var dueRow: some View {
        LabeledContent("Due") {
            VStack(alignment: .trailing, spacing: 6) {
                if draft.hasDue {
                    HStack(spacing: 8) {
                        DatePicker("Due Date", selection: $draft.due, displayedComponents: .date)
                            .labelsHidden()
                        if draft.hasTime {
                            DatePicker("Due Time", selection: $draft.due, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Button { setTime(false) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove the time")
                                .accessibilityLabel("Remove Time")
                        } else {
                            Button("Add Time") { setTime(true) }.buttonStyle(.link)
                        }
                        Button { removeDate() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove the due date")
                            .accessibilityLabel("Remove Due Date")
                    }
                    Text(dueHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("No date").foregroundStyle(.secondary)
                        Button("Add Date") { addDate() }.buttonStyle(.link)
                    }
                }
            }
        }
        .onChange(of: draft.due) { _, new in
            if draft.hasDue, new != suggestion.due { commit(SuggestionEdit(due: .some(new))) }
        }
    }

    /// "In 11 days · found in email", flipping to "set by you" once the date has been edited.
    private var dueHint: String {
        let relative = RelativeDue.make(due: draft.due, hasTime: draft.hasTime, now: now, calendar: calendar).top
        return "\(relative) · \((suggestion.effectiveDueSource ?? .user).hintText)"
    }

    private var priorityRow: some View {
        // The model has Low, Medium and High only, so there is no None segment.
        Picker("Priority", selection: $draft.priority) {
            Text("Low").tag(Priority.low)
            Text("Medium").tag(Priority.medium)
            Text("High").tag(Priority.high)
        }
        .pickerStyle(.segmented)
        .tint(draft.priority == .high ? Color.red : Color.accentColor)
        .onChange(of: draft.priority) { _, new in
            if new != suggestion.priority { commit(SuggestionEdit(priority: new)) }
        }
    }

    private var categoryRow: some View {
        LabeledContent("Category") {
            // A suggestion has one category, which becomes the #hashtag on the reminder.
            Picker("Category", selection: $draft.category) {
                ForEach(Category.allCases, id: \.self) { Text("#\($0.rawValue)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Choose the category tag added to the reminder")
        }
        .onChange(of: draft.category) { _, new in
            if new != record.category { commit(SuggestionEdit(category: new)) }
        }
    }

    private var notesRow: some View {
        LabeledContent("Notes") {
            TextField("Notes", text: $draft.notes, prompt: Text("Add Notes"), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1...6)
                .multilineTextAlignment(.leading)
                .focused($focus, equals: .notes)
                .onChange(of: focus) { old, new in if old == .notes, new != .notes { commitNotes() } }
        }
    }

    // MARK: From Email

    private var badges: some View {
        HStack(spacing: 6) {
            if let routing {
                RoutingChip(badge: RoutingPresentation.privacyBadge(routing.assessment))
                if let execution = routing.execution { RoutingChip(badge: RoutingPresentation.executionBadge(execution)) }
            }
        }
        .textCase(nil)
    }

    private var emailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SenderAvatar(sender: record.email?.sender ?? "", size: .large)
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderName).font(.system(size: 13, weight: .semibold))
                    if let subject = record.email?.subject, !subject.isEmpty {
                        Text(subject).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let received = record.email?.receivedAt {
                    Text(Self.sentText(received, calendar: calendar))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text(excerpt)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
            Button(action: onOpen) { Label("Open in Mail", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open this email in Mail")
        }
        .padding(.vertical, 6)
    }

    /// Mail Digest keeps only the quote it extracted, never the email body (the privacy rules are unchanged), so
    /// the quote is the excerpt. `EvidenceHighlight` marks it inside whatever text it is given; with a body
    /// stored it would mark the span, and here it covers the whole excerpt.
    private var excerpt: AttributedString {
        Self.highlighted(excerpt: suggestion.evidence, quote: suggestion.evidence, scheme: scheme)
    }

    static func highlighted(excerpt: String, quote: String, scheme: ColorScheme) -> AttributedString {
        var text = AttributedString(excerpt)
        if let range = EvidenceHighlight.range(of: quote, in: excerpt),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].backgroundColor = Color.yellow.opacity(scheme == .dark ? 0.3 : 0.38)
            text[lower..<upper].foregroundColor = .primary
        }
        return text
    }

    /// "Sat 7 Nov, 4:12 pm".
    static func sentText(_ date: Date, calendar: Calendar) -> String {
        let locale = Locale(identifier: "en_AU")
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)).replacingOccurrences(of: ",", with: "")
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute()).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        return "\(day), \(time.lowercased())"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Text("Dismiss")
                    Image(systemName: "delete.left").accessibilityHidden(true)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(suggestion.status != .pending)
            .help(suggestion.status == .pending ? "Dismiss this suggestion (Delete)"
                  : "A suggestion that couldn't be added can be tried again or left for later")
            // ⌘↩ belongs to this button, which acts on the selected row. The list's footer button is the bulk add.
            Button(action: addToReminders) {
                HStack(spacing: 6) {
                    Text("Add to Reminders")
                    Text("⌘↩").foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAdd)
            .help(addHelp)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Editing

    private func addDate() {
        draft.hasDue = true
        commit(SuggestionEdit(due: .some(draft.due)))
    }

    private func removeDate() {
        draft.hasDue = false
        draft.hasTime = false
        commit(SuggestionEdit(due: .some(nil)))
    }

    private func setTime(_ on: Bool) {
        draft.hasTime = on
        commit(SuggestionEdit(due: .some(draft.due), dueHasTime: on))
    }

    private func commitTitle() {
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != suggestion.title else { draft.title = suggestion.title; return }
        commit(SuggestionEdit(title: draft.title))
    }

    private func commitNotes() {
        guard let notes = ReviewActions.notesToSave(field: draft.notes, defaultLine: defaultNotes, saved: suggestion.notes)
        else { return }
        commit(SuggestionEdit(notes: notes))
    }

    private func commit(_ edit: SuggestionEdit) {
        Task { _ = await save(edit) }
    }

    /// False when the edit is rejected; the fields then revert and say why.
    private func save(_ edit: SuggestionEdit) async -> Bool {
        do {
            try await onEdit(edit)
            errorText = nil
            return true
        } catch {
            // Revert so the fields show what is actually saved.
            draft = Draft(suggestion, category: record.category, defaultNotes: defaultNotes, calendar: calendar, now: now)
            errorText = Self.message(for: error)
            return false
        }
    }

    /// Saves text still being typed, then adds. Clicking Add or pressing ⌘↩ leaves the field focused, so the
    /// usual commit on losing focus hasn't run. Rejected text adds nothing.
    private func addToReminders() {
        var pending = SuggestionEdit()
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines) != suggestion.title { pending.title = draft.title }
        pending.notes = ReviewActions.notesToSave(field: draft.notes, defaultLine: defaultNotes, saved: suggestion.notes)
        Task {
            if pending != SuggestionEdit(), !(await save(pending)) { return }
            onAdd()
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

/// A small capsule for a privacy or execution fact about one email, such as "Private · Rule".
private struct RoutingChip: View {
    let badge: RoutingBadge

    private var symbol: String {
        switch badge.tone {
        case .private: "lock.fill"
        case .public: "checkmark.shield"
        case .uncertain: "questionmark.circle"
        case .local: "cpu"
        case .cloud: "cloud"
        case .fallback: "exclamationmark.triangle"
        case .neutral: "info.circle"
        }
    }

    var body: some View {
        Label(badge.text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.quaternary, in: Capsule())
    }
}

#if DEBUG
@MainActor private func inspectorPreview() -> some View {
    var record = SuggestionRecord.records(from: PreviewFixtures.digest, kind: .daily, emails: PreviewFixtures.emails)[0]
    record.suggestion.due = PreviewFixtures.now.addingTimeInterval(11 * 86_400)
    record.suggestion.dueHasTime = true
    record.suggestion.priority = .high
    let routing = RoutingProvenance(
        assessment: PrivacyAssessment(verdict: .private, method: .rule, assessedAt: PreviewFixtures.now),
        execution: ExecutionRecord(provider: .local, model: "qwen3:4b", cloudAttempted: false,
                                   startedAt: PreviewFixtures.now, finishedAt: PreviewFixtures.now))
    return ReviewInspector(
        record: record, calendar: PreviewSupport.calendar, now: PreviewFixtures.now,
        lists: [ReminderListOption(id: "a", title: "Uni"), ReminderListOption(id: "b", title: "Home")],
        loadRouting: { routing })
        .frame(width: 560, height: 700)
}

#Preview("Review inspector") { inspectorPreview() }
#endif
