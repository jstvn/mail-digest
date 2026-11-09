import AppKit
import MailDigestCore
import SwiftUI

/// The review window (Q54): a sidebar of workflows, digests and jobs, and a canvas for the selected view.
/// Nothing reaches Reminders until the user clicks "Add to Reminders".
struct ReviewWindow: View {
    let run: DigestRunModel
    let access: MailAccessModel

    private var coordinator: ReviewCoordinator { run.coordinator }

    var body: some View {
        NavigationSplitView {
            SidebarView(run: run, access: access)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            canvas
                .id(coordinator.selection)
                // Named for the Window menu, Mission Control and VoiceOver; the canvas header shows it instead.
                .navigationTitle(windowTitle)
                .toolbar(removing: .title)
                .toolbar {
                    // Items sit at the leading edge unless a flexible item pushes them. The system pins the search
                    // field to the trailing edge itself, so Run Now is the last item before it.
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible)
                    } else {
                        ToolbarItem(placement: .automatic) { Spacer() }
                    }
                    ToolbarItem(placement: .primaryAction) { runButton }
                }
        }
        .frame(minWidth: 900, minHeight: 560)
        .environment(\.senderRules, SenderRuleActions(store: run.settings))
        // Pick up a permission change made in System Settings.
        .onAppear { run.reminders.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            run.reminders.refresh()
        }
    }

    // MARK: Run button

    private var runAction: ToolbarRunAction {
        ToolbarRunAction(progress: run.activeProgress, daily: run.dailyAction)
    }

    /// Run Now, or whatever the job state calls for (Pause, Resume, Retry), the same way the menu bar does.
    private var runButton: some View {
        let action = runAction
        return Button { perform(action) } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .labelStyle(ToolbarRunLabelStyle())
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(action.title)
        .disabled(!isEnabled(action))
        .help(action.help)
    }

    private func isEnabled(_ action: ToolbarRunAction) -> Bool {
        let mailUnavailable = access.status?.mode == .unavailable
        switch action.behavior {
        case .runNow: return run.canRunNow(mailUnavailable: mailUnavailable)
        case .pause: return true
        case .resumeJob: return !run.isRunning && !mailUnavailable
        case .resumeDaily, .retryDaily: return run.isDailyActionEnabled && !mailUnavailable
        case .unavailable: return false
        }
    }

    private func perform(_ action: ToolbarRunAction) {
        switch action.behavior {
        case .runNow: Task { await run.runNow() }
        case .pause: run.pause()
        case .resumeJob(let id): Task { await run.resumeJob(id) }
        case .resumeDaily(let id): Task { await run.resumeCurrentDaily(id) }
        case .retryDaily(let id): Task { await run.resumeDailyJob(id, expecting: .failed) }
        case .unavailable: break
        }
    }

    @ViewBuilder private var canvas: some View {
        switch coordinator.selection {
        case .today: DigestCanvasView(kind: .today, run: run, access: access)
        case .day(let day): DigestCanvasView(kind: .day(day), run: run, access: access)
        case .backlog(let id): DigestCanvasView(kind: .backlog(id), run: run, access: access)
        case .reviewQueue: ReviewQueueView(run: run, access: access)
        case .logbook: LogbookView(run: run, access: access)
        case .mailCleanup: MailCleanupView(run: run, access: access)
        case .activity: ActivityView(run: run, access: access)
        }
    }

    /// The selected view's name, for the title bar, the Window menu and Mission Control.
    private var windowTitle: String {
        switch coordinator.selection {
        case .today: return "Today"
        case .day(let day): return ReviewDateText.day(day, calendar: run.library.calendar)
        case .backlog(let id): return run.library.title(forBacklog: id)
        case .reviewQueue: return "Review Queue"
        case .logbook: return "Logbook"
        case .mailCleanup: return "Mail Cleanup"
        case .activity: return "Activity"
        }
    }
}

/// Icon and title of the toolbar run button. The system sizes the icon; small keeps it level with the text like
/// Mail's toolbar buttons, and the tighter spacing than the system's title-and-icon style keeps them one unit.
private struct ToolbarRunLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
