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
            row("Open Review Panel", symbol: "tray.full") { show("review") }
            row("Run Now", symbol: "play") { Task { await run.runNow() } }
                .disabled(run.isRunning || access.status?.mode == .unavailable)
            row("New Backlog Job…", symbol: "tray.and.arrow.down") { show("job-setup") }
                .disabled(run.isRunning || access.status?.mode == .unavailable)
            row("Mail Access…", symbol: "lock.shield") { show("mail-access") }
            row("Settings…", symbol: "gearshape", shortcut: ",") {
                NSApp.activate()
                openSettings()
            }
            Divider()
            row("Quit Mail Digest", symbol: "power", shortcut: "q") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 340)
        // Match a native menu: the icon stays highlighted while this panel is open.
        .onAppear { StatusItemHighlight.set(true) }
        .onDisappear { StatusItemHighlight.set(false) }
    }

    private func row(_ title: String, symbol: String, shortcut: KeyEquivalent? = nil,
                     action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        return Group {
            if let shortcut { button.keyboardShortcut(shortcut) } else { button }
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}
