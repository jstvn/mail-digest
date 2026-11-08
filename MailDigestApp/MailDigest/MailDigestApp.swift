import MailDigestCore
import SwiftUI

/// Menu bar agent entry point: the menu bar window, the review window, onboarding, Settings and Mail Access.
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
                    run.coordinator.select(.today)
                    openWindow(id: "review")
                    NSApp.activate()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Mail Digest", id: "review") {
            ReviewWindow(run: run, access: access)
                .dockPresence()
        }
        .defaultSize(width: 980, height: 680)

        Window("Mail Access", id: "mail-access") {
            MailAccessView(model: access, run: run)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentMinSize)

        Window("New Processing Job", id: "job-setup") {
            JobSetupView(run: run)
        }
        .defaultSize(width: 680, height: 640)

        Window("Welcome to Mail Digest", id: "onboarding") {
            OnboardingView(run: run, access: access)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(run: run)
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
        await run.loadLastRun()
        await access.refresh()
        if !UserDefaults.standard.bool(forKey: OnboardingView.completedKey) {
            openWindow(id: "onboarding")
            NSApp.activate()
        }
        morning.start()
    }
}
