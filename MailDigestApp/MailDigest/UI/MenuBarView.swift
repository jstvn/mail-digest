import AppKit
import MailDigestCore
import SwiftUI

/// The menu bar window: progress strip or last-run summary, banner and Retry, and the main commands.
/// Uses the window style of `MenuBarExtra` because the progress strip needs a real progress bar.
struct MenuBarView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Closes this panel, as a native menu closes once an item is chosen.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = run.activeProgress {
                ProgressStripView(progress: progress,
                                  onPause: run.pause,
                                  onPauseNow: run.pauseNow,
                                  onResume: { Task { await run.resume() } },
                                  onStop: run.stop)
            } else if let summary = run.lastRunSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if let banner = run.banner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if run.failedJobID != nil {
                    Button("Retry") { Task { await run.retryFailedJob() } }
                        .disabled(run.isRunning)
                }
            }
            Divider()
            VStack(spacing: 0) {
                row("Open Review Panel", symbol: "tray.full") { show("review") }
                row("Run Now", symbol: "play") { Task { await run.runNow() } }
                    .disabled(run.isRunning || access.status?.mode == .unavailable)
                row("New Backlog Job…", symbol: "tray.and.arrow.down") { show("job-setup") }
                    .disabled(run.isRunning || access.status?.mode == .unavailable)
                row("Mail Access…", symbol: "lock.shield") { show("mail-access") }
                row("Settings…", symbol: "gearshape", shortcut: ",") {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
            }
            // Pull the rows out so the highlight is wider than the text, like a native menu,
            // while the labels stay aligned with the content above.
            .padding(.horizontal, -8)
            Divider()
            row("Quit Mail Digest", symbol: "power", shortcut: "q") { NSApplication.shared.terminate(nil) }
                .padding(.horizontal, -8)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(_ title: String, symbol: String, shortcut: KeyEquivalent? = nil,
                     action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            // A fixed icon column, so every title starts at the same x whatever the symbol's own width.
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 24, alignment: .center)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .accessibilityLabel(title)
        return Group {
            if let shortcut { button.keyboardShortcut(shortcut) } else { button }
        }
    }

    private func show(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate()
    }
}
