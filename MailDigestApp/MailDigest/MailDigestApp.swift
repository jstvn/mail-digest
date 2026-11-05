import SwiftUI

/// Menu bar agent entry point. The review panel, settings and onboarding arrive in later tasks.
@main
struct MailDigestApp: App {
    @State private var access = MailAccessModel()
    @State private var run = DigestRunModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Text("Mail Digest")
            if let status = access.status {
                Text(status.mode.title)
            }
            Button("Run Now") { Task { await run.runNow() } }
                .disabled(run.isRunning || access.status?.mode == .unavailable)
            if run.isRunning, let text = run.progressText {
                Text(text)
            } else if let summary = run.lastRunSummary {
                Text(summary)
            }
            if let banner = run.banner {
                Text(banner)
            }
            if run.failedJobID != nil {
                Button("Retry") { Task { await run.retryFailedJob() } }
                    .disabled(run.isRunning)
            }
            Divider()
            Button("Mail Access…") { showMailAccess() }
            Divider()
            Button("Quit Mail Digest") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label("Mail Digest", systemImage: "envelope.badge")
                .task { await launch() }
        }

        Window("Mail Access", id: "mail-access") {
            MailAccessView(model: access, run: run)
        }
        .windowResizability(.contentSize)
    }

    private func showMailAccess() {
        openWindow(id: "mail-access")
        NSApp.activate()
    }

    /// Probes once at launch and shows Mail Access on first run. Never prompts for Automation.
    private func launch() async {
        await access.refresh()
        let key = "didShowMailAccess"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            showMailAccess()
        }
    }
}
