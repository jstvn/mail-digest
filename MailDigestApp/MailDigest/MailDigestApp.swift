import MailDigestCore
import SwiftUI

/// Menu bar agent entry point: the menu bar window, the review window, onboarding, Settings and Mail Access.
/// A morning scheduler starts the Daily run after launch.
@main
struct MailDigestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var access = MailAccessModel()
    @State private var run = DigestRunModel()
    @State private var scheduler: MorningScheduler?
    private let router = NotificationRouter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(run: run, access: access)
        } label: {
            menuBarLabel
                .task { await launch() }
                // A clicked notification opens the review panel.
                .onChange(of: router.openReviewRequests) { _, _ in
                    run.coordinator.select(.today)
                    openWindow(id: "review")
                    NSApp.activate()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Mail Digest", id: "review") {
            ReviewWindow(run: run, access: access)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { ReviewCommands(run: run) }

        Window("Mail Access", id: "mail-access") {
            MailAccessView(model: access, run: run)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentMinSize)

        Window("New Backlog Job", id: "new-backlog-job") {
            JobSetupView(run: run)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Mail Digest", id: "onboarding") {
            OnboardingView(run: run, access: access)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(run: run, access: access)
        }
    }

    /// The icon (with a progress ring or pause badge while a job is active), plus the number of suggestions
    /// to review (pending and failed) when there are any. The icon is a template image, so the status item keeps its native
    /// look and highlight.
    private var menuBarLabel: some View {
        // Pending plus failed across every digest: always the Review Queue's number.
        let count = run.library.archive.reviewQueueCount
        let icon = run.menuBarIcon
        var label = count > 0 ? "Mail Digest, \(count) \(count == 1 ? "suggestion" : "suggestions") to review" : "Mail Digest"
        if let extra = icon.accessibilityText { label += ", \(extra)" }
        return HStack(spacing: 2) {
            if let image = MenuBarIconRenderer.image(for: icon) {
                Image(nsImage: image).renderingMode(.template)
            } else {
                Image(systemName: "envelope.badge")
            }
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Opens the database, probes Mail once (never prompting for Automation), shows onboarding on first
    /// launch and starts the morning scheduler.
    private func launch() async {
        // The label's task can run again; only start once.
        guard scheduler == nil else { return }
        let morning = MorningScheduler(run: run)
        scheduler = morning
        // Waiting overnight jobs start only after onboarding and a Mail access check.
        run.autoStartGate = { [access] in
            UserDefaults.standard.bool(forKey: OnboardingView.completedKey) && access.status?.mode != nil
                && access.status?.mode != .unavailable
        }
        await run.loadLastRun()
        await access.refresh()
        if !UserDefaults.standard.bool(forKey: OnboardingView.completedKey) {
            openWindow(id: "onboarding")
            NSApp.activate()
        }
        run.evaluateResources(force: true)
        morning.start()
    }
}

/// Menu commands of the review window: ⌘1 to ⌘5 switch the sidebar view, ⌘⇧A clears the focused section's
/// selection (⌘A is the standard Select All, handled by the canvas when no text field is editing).
struct ReviewCommands: Commands {
    let run: DigestRunModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.canvasSelection) private var selection

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Today") { show(.today) }.keyboardShortcut("1", modifiers: .command)
            Button("Review Queue") { show(.reviewQueue) }.keyboardShortcut("2", modifiers: .command)
            Button("Logbook") { show(.logbook) }.keyboardShortcut("3", modifiers: .command)
            Button("Mail Cleanup") { show(.mailCleanup) }.keyboardShortcut("4", modifiers: .command)
            Button("Activity") { show(.activity) }.keyboardShortcut("5", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Select None") { selection?.selectNone() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(selection == nil)
        }
    }

    private func show(_ item: SidebarItem) {
        run.coordinator.select(item)
        openWindow(id: "review")
        NSApp.activate()
    }
}
