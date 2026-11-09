import AppKit
import MailDigestCore
import SwiftUI

/// The frame shared by every canvas: a centred, width-limited scroll view with the header and notices, the
/// floating triage bar, keyboard handling and scroll-to-reveal.
///
/// `records` are the actionable suggestions the canvas shows, in on-screen order. ↑/↓ move focus through
/// them, space ticks, ⌫ dismisses the focused row, and the triage bar acts on exactly these records.
struct CanvasScaffold<Content: View>: View {
    let run: DigestRunModel
    let access: MailAccessModel
    let title: String
    let subtitle: String?
    let headline: String
    let records: [SuggestionRecord]
    /// Whether actionable suggestions are hidden from `records` (Show All not chosen, or more pages unloaded).
    let isPartial: Bool
    /// The scroll id of whatever shows this email (a suggestion or info card); nil when nothing does.
    let revealTarget: (String) -> AnyHashable?
    let content: (FocusState<UUID?>.Binding) -> Content

    @FocusState private var focusedID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(run: DigestRunModel, access: MailAccessModel, title: String, subtitle: String? = nil, headline: String = "",
         records: [SuggestionRecord] = [], isPartial: Bool = false, revealTarget: @escaping (String) -> AnyHashable? = { _ in nil },
         @ViewBuilder content: @escaping (FocusState<UUID?>.Binding) -> Content) {
        self.run = run
        self.access = access
        self.title = title
        self.subtitle = subtitle
        self.headline = headline
        self.records = records
        self.isPartial = isPartial
        self.revealTarget = revealTarget
        self.content = content
    }

    private var coordinator: ReviewCoordinator { run.coordinator }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CanvasHeader(title: title, subtitle: subtitle, headline: headline)
                    CanvasNotices(run: run, access: access)
                    content($focusedID)
                }
                .onKeyPress(phases: .down) { handleKey($0, proxy: proxy) }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            // The bar sits in a solid band under the scroll view, so rows never show behind the capsule.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !records.isEmpty {
                    TriageBar(
                        selectedCount: coordinator.selectedCount(in: records),
                        shownOf: isPartial ? records.count : nil,
                        canAdd: coordinator.canAddSelected(in: records),
                        canDismiss: coordinator.unselectedCount(in: records) > 0 && !coordinator.isWorking,
                        dismissHelp: isPartial ? "Dismiss the suggestions shown that aren't ticked. Hidden suggestions aren't affected."
                                               : "Dismiss the suggestions shown that aren't ticked",
                        addHelp: coordinator.reminderWriter == nil ? "Reminders access isn't available"
                            : (isPartial ? "Add the ticked suggestions shown to Reminders. Hidden suggestions aren't affected."
                                         : "Add the ticked suggestions to Reminders"),
                        dismissUnselected: { Task { await coordinator.dismissUnselected(in: records) } },
                        addSelected: { Task { await coordinator.addSelected(in: records) } }
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
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

    // MARK: Keyboard

    /// ↑/↓ move between rows, space ticks, ⌫ dismisses. Ignored while a text field is being edited.
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

    /// Rows are lazy, so the target may not exist yet: scroll it into the realised range, then focus it.
    private func focus(_ id: UUID, proxy: ScrollViewProxy) {
        proxy.scrollTo(id)
        Task { @MainActor in focusedID = id }
    }

    private static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
