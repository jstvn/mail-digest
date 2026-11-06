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
                                  showsResume: run.menuCardShowsResume(for: progress),
                                  onStop: run.stop)
            } else if let summary = run.lastRunSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if let banner = run.banner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if run.showsBannerRetry {
                    Button("Retry") { Task { await run.retryFailedJob() } }
                        .disabled(run.isRunning)
                }
            }
            if let note = run.dailyNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(spacing: 0) {
                row("Open Review Panel", symbol: "tray.full") { show("review") }
                dailyRow
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

    /// Run Now, or what the current Daily job needs instead (Q52). Never starts a second Daily job.
    private var dailyRow: some View {
        let action = run.dailyAction
        // Opening Settings needs no Mail access; everything else reads Mail.
        let needsMail = action.behavior != .review
        return row(action.title, symbol: action.systemImage, accessibilityLabel: action.accessibilityLabel) {
            switch action.behavior {
            case .startNew: Task { await run.runNow() }
            case .resume(let id): Task { await run.resumeDailyJob(id, expecting: .paused) }
            case .retry(let id): Task { await run.resumeDailyJob(id, expecting: .failed) }
            case .review: showJobs()
            case .none: break
            }
        }
        .disabled(!run.isDailyActionEnabled || (needsMail && access.status?.mode == .unavailable))
    }

    private func row(_ title: String, symbol: String, shortcut: KeyEquivalent? = nil,
                     accessibilityLabel: String? = nil, action: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(accessibilityLabel ?? title)
        return Group {
            if let shortcut { button.keyboardShortcut(shortcut) } else { button }
        }
    }

    /// Settings > Jobs, where unresolved jobs are resumed explicitly.
    private func showJobs() {
        run.settingsTab = .jobs
        dismiss()
        openSettings()
        NSApp.activate()
    }

    private func show(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate()
    }
}
