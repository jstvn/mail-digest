import MailDigestCore
import SwiftUI

/// Menu bar agent entry point: the menu bar window, the review panel, Settings and Mail Access.
/// The scheduler, onboarding and the Reminders writer arrive in later tasks.
@main
struct MailDigestApp: App {
    @State private var access = MailAccessModel()
    @State private var run = DigestRunModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(run: run, access: access)
        } label: {
            menuBarLabel
                .task { await launch() }
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

    private func showMailAccess() {
        openWindow(id: "mail-access")
        NSApp.activate()
    }

    /// Probes once at launch and shows Mail Access on first run. Never prompts for Automation.
    private func launch() async {
        await run.loadLastRun()
        await access.refresh()
        let key = "didShowMailAccess"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            showMailAccess()
        }
    }
}
