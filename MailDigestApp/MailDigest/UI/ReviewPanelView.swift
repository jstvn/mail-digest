import AppKit
import MailDigestCore
import SwiftUI

/// The review window: headline, suggested reminders, info summaries and skipped mail.
/// Nothing reaches Reminders until the user clicks "Add selected".
struct ReviewPanelView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private var review: ReviewViewModel { run.review }

    @FocusState private var focusedID: UUID?
    @State private var collapsedGroups: Set<Category> = [.newsletters]
    @State private var skippedExpanded = false
    @State private var pinnedExpanded = true

    /// What the body shows, derived so previews and tests can reason about each state.
    private var panelState: ReviewPanelState {
        if run.lastRunFoundNothing, run.activeProgress == nil { return .noNewMail(lastRun: run.lastRunAt) }
        guard review.isLoaded else { return .loading }
        guard let digest = review.digest else { return .neverRun }
        if digest.emailCount == 0 && digest.suggestions.isEmpty && digest.info.isEmpty && digest.skipped.isEmpty {
            return .noNewMail(lastRun: digest.createdAt)
        }
        return .digest
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(PanelAlert.current(run: run, access: access, reminders: run.reminders.status)) { alert in
                        AlertBanner(alert: alert, canRetry: !run.isRunning, onRetry: retry,
                                    onRequestReminders: { Task { await run.reminders.request() } })
                    }
                    if let progress = run.activeProgress {
                        ProgressStripView(progress: progress,
                                          onPause: run.pause,
                                          onResume: { Task { await run.resume() } },
                                          onStop: run.stop)
                    }
                    if let message = review.message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                    if let suggestion = review.ignoreSuggestion {
                        IgnoreSuggestionNotice(suggestion: suggestion, name: review.ignoreSuggestionName ?? suggestion.sender,
                                               onIgnore: review.acceptIgnoreSuggestion,
                                               onNotNow: review.snoozeIgnoreSuggestion,
                                               onDecline: review.declineIgnoreSuggestion)
                    }
                    content
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 640)
        .navigationTitle("Mail Digest")
        // Pick up a permission change made in System Settings.
        .onAppear { run.reminders.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            run.reminders.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle).font(.title2.weight(.semibold))
                if let headline = review.digest?.headline, !headline.isEmpty, panelState == .digest {
                    Text("“\(headline)”").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Run Now") { Task { await run.runNow() } }
                .disabled(run.isRunning || run.activeProgress != nil || access.status?.mode == .unavailable)
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Open Settings")
            .accessibilityLabel("Settings")
        }
        .padding(16)
    }

    private var headerTitle: String {
        guard let digest = review.digest, panelState == .digest else { return "Mail Digest" }
        return ReviewPresentation.headerTitle(digest, now: Date.now)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch panelState {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 160)
        case .neverRun:
            ContentUnavailableView("No digest yet", systemImage: "envelope.open",
                                   description: Text("Choose Run Now to read your new mail."))
                .frame(maxWidth: .infinity, minHeight: 200)
        case .noNewMail(let lastRun):
            ContentUnavailableView("Inbox zero for today", systemImage: "tray",
                                   description: Text(lastRun.map { "Last run \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                .frame(maxWidth: .infinity, minHeight: 200)
        case .digest:
            suggestionsSection
            infoSection
            skippedSection
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        let page = review.page
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUGGESTED REMINDERS (\(review.actionable.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Select All") { review.selectAll() }
                Button("Select None") { review.selectNone() }
            }
            .controlSize(.small)

            if review.actionable.isEmpty {
                Text("No reminders suggested.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(page.visible) { s in
                        SuggestionRow(
                            suggestion: s, category: review.category(for: s), email: review.emails[s.emailID],
                            isSelected: review.state?.selection.contains(s.id) == true,
                            isFocused: focusedID == s.id,
                            onToggle: { review.toggle(s.id) },
                            onEdit: { try await review.edit($0, id: s.id) },
                            onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: s.emailID)) })
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedID, equals: s.id)
                        Divider()
                    }
                }
                .onKeyPress(phases: .down) { handleKey($0, visible: page.visible) }
                if page.hiddenCount > 0 {
                    Button("Show all \(review.actionable.count) suggestions") { review.showAllSuggestions = true }
                        .buttonStyle(.link)
                } else if review.showAllSuggestions, review.jobKind == .daily, review.actionable.count > 25 {
                    Button("Show top 25 only") { review.showAllSuggestions = false }.buttonStyle(.link)
                }
                HStack {
                    Spacer()
                    Button("Dismiss Unselected") { Task { await review.dismissUnselected() } }
                        .disabled(review.unselectedCount == 0 || review.isWorking)
                    Button("Add Selected") { Task { await review.addSelected() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!review.canAddSelected)
                        .help(review.reminderWriter == nil ? "Reminders access isn't available" : "Add the ticked suggestions to Reminders")
                }
            }
        }
    }

    /// ↑/↓ move between rows, space ticks, ⌫ dismisses. Ignored while a text field is being edited.
    private func handleKey(_ press: KeyPress, visible: [Suggestion]) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !Self.isEditingText else { return .ignored }
        let ids = visible.map(\.id)
        switch press.key {
        case .upArrow, .downArrow:
            guard !ids.isEmpty else { return .ignored }
            let step = press.key == .upArrow ? -1 : 1
            if let current = focusedID.flatMap(ids.firstIndex(of:)) {
                focusedID = ids[min(max(current + step, 0), ids.count - 1)]
            } else {
                focusedID = ids.first
            }
            return .handled
        case .space:
            guard let id = focusedID else { return .ignored }
            review.toggle(id)
            return .handled
        case .delete, .deleteForward:
            guard let id = focusedID, let index = ids.firstIndex(of: id) else { return .ignored }
            let next = ids.indices.contains(index + 1) ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
            Task { await review.dismiss(id: id) }
            focusedID = next
            return .handled
        default:
            return .ignored
        }
    }

    private static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    // MARK: Info

    private var infoSection: some View {
        let groups = ReviewPresentation.infoGroups(review.digest?.info ?? [])
        let pinned = review.carriedPins.map(\.item)
        return VStack(alignment: .leading, spacing: 8) {
            if !groups.isEmpty || !pinned.isEmpty {
                Text("INFO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            // Pinned items from earlier digests come first, as their own group, until they are unpinned.
            if !pinned.isEmpty {
                DisclosureGroup(isExpanded: $pinnedExpanded) {
                    infoCards(pinned)
                } label: {
                    Label("Pinned (\(pinned.count))", systemImage: "pin.fill")
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

    private func infoCards(_ items: [InfoItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                InfoCard(item: item, email: review.emails[item.emailID],
                         notesState: review.notesStates[item.id] ?? .idle,
                         onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: item.emailID)) },
                         onTogglePin: { Task { await review.setPinned(!item.pinned, item: item) } },
                         onSaveToNotes: { Task { await review.saveToNotes(item) } })
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: Skipped

    @ViewBuilder private var skippedSection: some View {
        if let skipped = review.digest?.skipped, !skipped.isEmpty {
            DisclosureGroup(isExpanded: $skippedExpanded) {
                VStack(alignment: .leading, spacing: 6) {
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

    private func retry() {
        Task {
            if run.failedJobID != nil { await run.retryFailedJob() } else { await run.runNow() }
        }
    }
}

/// An inline, non-modal offer to ignore a sender the user keeps dismissing. Nothing changes until "Ignore Sender".
private struct IgnoreSuggestionNotice: View {
    let suggestion: IgnoreSuggestion
    let name: String
    let onIgnore: () -> Void
    let onNotNow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You've dismissed \(suggestion.dismissedCount) suggestions from \(name). Ignore this sender in future digests?")
                    .fixedSize(horizontal: false, vertical: true)
                if name != suggestion.sender {
                    Text(suggestion.sender).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Ignore Sender", action: onIgnore)
            Button("Not Now", action: onNotNow)
            Button("Don't Ask Again", action: onDecline)
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// A banner with the fix and, where it applies, a button for it.
private struct AlertBanner: View {
    let alert: PanelAlert
    let canRetry: Bool
    let onRetry: () -> Void
    let onRequestReminders: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch alert {
            case .runProblem:
                Button("Retry", action: onRetry).disabled(!canRetry)
            case .mailAutomationDenied:
                Button("Open Automation Settings…") { open(MailAccessStatus.automationSettingsURL) }
            case .fullDiskAccessFallback:
                Button("Open Full Disk Access Settings…") { open(MailAccessStatus.fullDiskAccessSettingsURL) }
            case .remindersNeedAccess:
                Button("Allow Reminders Access…", action: onRequestReminders)
            case .remindersUnavailable:
                Button("Open Reminders Settings…") { open(PanelAlert.remindersSettingsURL) }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch alert {
        case .fullDiskAccessFallback: return "info.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch alert {
        case .fullDiskAccessFallback: return .blue
        default: return .orange
        }
    }

    private var message: String {
        switch alert {
        case .runProblem(let text): return text
        case .mailAutomationDenied:
            return "Mail Automation is turned off. Enable Mail access for Mail Digest in Automation settings."
        case .fullDiskAccessFallback:
            return "Using the Mail automation fallback. Full Disk Access enables fast local reads of your mail."
        case .remindersNeedAccess:
            return "Mail Digest needs access to Reminders to add the suggestions you approve. Add Selected is turned off until you allow it."
        case .remindersUnavailable:
            return "Reminders access isn't available, so Add Selected is turned off. Allow Mail Digest in Privacy & Security > Reminders."
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
