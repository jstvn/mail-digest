import SwiftUI

/// Menu bar agent entry point. The review panel, settings and onboarding arrive in later tasks.
@main
struct MailDigestApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Mail Digest")
            Divider()
            Button("Quit Mail Digest") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label("Mail Digest", systemImage: "envelope.badge")
        }
    }
}
