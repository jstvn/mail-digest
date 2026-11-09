import AppKit
import MailDigestCore
import SwiftUI

/// The review window (Q54): a sidebar of workflows, digests and jobs, and a canvas for the selected view.
/// Nothing reaches Reminders until the user clicks "Add to Reminders".
struct ReviewWindow: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openSettings) private var openSettings

    private var coordinator: ReviewCoordinator { run.coordinator }

    var body: some View {
        NavigationSplitView {
            SidebarView(run: run, access: access)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            canvas
                .id(coordinator.selection)
                // Named for the Window menu, Mission Control and VoiceOver; the canvas header shows it instead.
                .navigationTitle(windowTitle)
                .toolbar(removing: .title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await run.runNow() } } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(!run.canStartDaily || access.status?.mode == .unavailable)
                .help(run.dailyLifecycle == .none ? "Read your new mail now" : "Resume or review the unfinished Daily job first.")

                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        // Pick up a permission change made in System Settings.
        .onAppear { run.reminders.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            run.reminders.refresh()
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
