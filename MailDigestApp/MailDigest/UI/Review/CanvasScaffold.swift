import AppKit
import MailDigestCore
import SwiftUI

extension EnvironmentValues {
    /// Scrolls the canvas to a section id (the stat strip's tiles use it).
    @Entry var scrollToSection: (AnyHashable) -> Void = { _ in }
}

/// What the Edit menu's Select None (⌘⇧A) acts on: the focused canvas's current section.
struct CanvasSelectionActions {
    var selectNone: () -> Void
}

extension FocusedValues {
    @Entry var canvasSelection: CanvasSelectionActions?
}

/// The frame shared by every canvas: a centred, width-limited scroll view with the header and notices, the
/// floating triage bar, keyboard handling and scroll-to-reveal.
///
/// `records` are the actionable suggestions the canvas shows, in on-screen order. ↑/↓ move focus through
/// them, space ticks, ⌫ dismisses the focused card, Return edits its title, ⌘A and ⌘⇧A select and clear the
/// focused card's section, and the triage bar acts on exactly these records.
struct CanvasScaffold<Content: View>: View {
    let run: DigestRunModel
    let access: MailAccessModel
    let title: String
    let subtitle: String?
    let headline: String
    let records: [SuggestionRecord]
    /// Whether actionable suggestions are hidden from `records` (Show All not chosen, more pages unloaded, or
    /// a search filter).
    let isPartial: Bool
    /// The scroll id of whatever shows this email (a suggestion or info card); nil when nothing does.
    let revealTarget: (String) -> AnyHashable?
    /// Replaces the large title block (Today draws its own greeting).
    let header: AnyView?
    /// The records ⌘A and ⌘⇧A act on for the focused card: its own section, or all shown records.
    let sectionRecords: (UUID?) -> [SuggestionRecord]
    let content: (FocusState<UUID?>.Binding) -> Content

    @FocusState private var focusedID: UUID?
    @State private var editRequest: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(run: DigestRunModel, access: MailAccessModel, title: String, subtitle: String? = nil, headline: String = "",
         records: [SuggestionRecord] = [], isPartial: Bool = false, header: AnyView? = nil,
         sectionRecords: ((UUID?) -> [SuggestionRecord])? = nil,
         revealTarget: @escaping (String) -> AnyHashable? = { _ in nil },
         @ViewBuilder content: @escaping (FocusState<UUID?>.Binding) -> Content) {
        self.run = run
        self.access = access
        self.title = title
        self.subtitle = subtitle
        self.headline = headline
        self.records = records
        self.isPartial = isPartial
        self.header = header
        self.sectionRecords = sectionRecords ?? { _ in records }
        self.revealTarget = revealTarget
        self.content = content
    }

    private var coordinator: ReviewCoordinator { run.coordinator }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let header { header } else { CanvasHeader(title: title, subtitle: subtitle, headline: headline) }
                    CanvasNotices(run: run, access: access)
                    content($focusedID)
                }
                .onKeyPress(phases: .down) { handleKey($0, proxy: proxy) }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            // Room for the last card to scroll clear of the floating bar.
            .contentMargins(.bottom, records.isEmpty ? 0 : 90, for: .scrollContent)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                if !records.isEmpty {
                    triageBar
                        .padding(.bottom, 22)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(\.scrollToSection) { id in
                if reduceMotion { proxy.scrollTo(id, anchor: .top) } else { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
            .environment(\.cardEditRequest, $editRequest)
            // ⌘A reaches here only when no text field is editing, so a field keeps its own Select All.
            .onCommand(#selector(NSResponder.selectAll(_:))) {
                coordinator.selectAll(sectionRecords(focusedID))
            }
            .focusedSceneValue(\.canvasSelection, CanvasSelectionActions {
                coordinator.selectNone(sectionRecords(focusedID))
            })
            // A Recent row asked to show an email: scroll to its first suggestion or info card.
            .onChange(of: coordinator.revealedEmailID) { _, emailID in
                guard let emailID else { return }
                if let target = revealTarget(emailID) {
                    // After the layout settles, in case the target's group was just expanded.
                    Task { @MainActor in
                        if reduceMotion { proxy.scrollTo(target, anchor: .top) } else { withAnimation { proxy.scrollTo(target, anchor: .top) } }
                    }
                }
                coordinator.clearReveal()
            }
            .onChange(of: focusedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: records.isEmpty)
    }

    private var triageBar: some View {
        TriageBar(
            selectedCount: coordinator.selectedCount(in: records),
            shownOf: isPartial ? records.count : nil,
            canAdd: coordinator.canAddSelected(in: records),
            canDismiss: coordinator.unselectedCount(in: records) > 0 && !coordinator.isWorking,
            dismissHelp: isPartial ? "Dismiss the suggestions shown that aren't ticked. Hidden suggestions aren't affected."
                                   : "Dismiss the suggestions shown that aren't ticked",
            addHelp: coordinator.reminderWriter == nil ? "Add to Reminders is off until you allow access in Privacy & Security"
                : (isPartial ? "Add the ticked suggestions shown to Reminders. Hidden suggestions aren't affected."
                             : "Add the ticked suggestions to Reminders"),
            dismissUnselected: { Task { await coordinator.dismissUnselected(in: records) } },
            addSelected: { Task { await coordinator.addSelected(in: records) } }
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: Keyboard

    /// ↑/↓ move between cards, space ticks, ⌫ dismisses, Return edits the title. Ignored while a text field is
    /// being edited, and with any modifier (⌘↩ belongs to the triage bar).
    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !Self.isEditingText else { return .ignored }
        let ids = records.map(\.id)
        switch press.key {
        case .upArrow, .downArrow:
            guard !ids.isEmpty else { return .ignored }
            let step = press.key == .upArrow ? -1 : 1
            if let current = focusedID.flatMap(ids.firstIndex(of:)) {
                focus(ids[min(max(current + step, 0), ids.count - 1)], proxy: proxy)
            } else {
                focus(ids[0], proxy: proxy)
            }
            return .handled
        case .space:
            guard let id = focusedID, let record = records.first(where: { $0.id == id }) else { return .ignored }
            coordinator.toggle(record)
            return .handled
        case .return:
            guard let id = focusedID, ids.contains(id) else { return .ignored }
            editRequest = id
            return .handled
        case .delete, .deleteForward:
            guard let id = focusedID, let index = ids.firstIndex(of: id) else { return .ignored }
            let next = ids.indices.contains(index + 1) ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
            let record = records[index]
            Task { await coordinator.dismiss(record) }
            if let next { focus(next, proxy: proxy) } else { focusedID = nil }
            return .handled
        default:
            return .ignored
        }
    }

    /// Cards are lazy, so the target may not exist yet: scroll it into the realised range, then focus it.
    private func focus(_ id: UUID, proxy: ScrollViewProxy) {
        proxy.scrollTo(id)
        Task { @MainActor in focusedID = id }
    }

    private static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
