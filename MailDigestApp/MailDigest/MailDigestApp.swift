import MailDigestCore
import SwiftUI

/// Menu bar agent entry point: the menu bar window, the review panel, onboarding, Settings and Mail Access.
/// A morning scheduler starts the Daily run after launch.
@main
struct MailDigestApp: App {
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
                    openWindow(id: "review")
                    NSApp.activate()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Mail Digest", id: "review") {
            ReviewPanelView(run: run, access: access)
        }
        .defaultSize(width: 720, height: 640)

        Window("Mail Access", id: "mail-access") {
            MailAccessView(model: access, run: run)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Mail Digest", id: "onboarding") {
            OnboardingView(run: run, access: access)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(run: run)
        }
    }

    /// The icon, plus the number of pending suggestions when there are any.
    private var menuBarLabel: some View {
        let count = run.review.pendingCount
        return HStack(spacing: 2) {
            Image(systemName: "envelope.badge")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "Mail Digest, \(count) pending suggestions" : "Mail Digest")
    }

    /// Opens the database, probes Mail once (never prompting for Automation), shows onboarding on first
    /// launch and starts the morning scheduler.
    private func launch() async {
        // The label's task can run again; only start once.
        guard scheduler == nil else { return }
        let morning = MorningScheduler(run: run)
        scheduler = morning
        await run.loadLastRun()
        await access.refresh()
        if !UserDefaults.standard.bool(forKey: OnboardingView.completedKey) {
            openWindow(id: "onboarding")
            NSApp.activate()
        }
        morning.start()
    }
}
