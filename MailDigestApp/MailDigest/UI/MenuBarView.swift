import AppKit
import MailDigestCore
import SwiftUI

/// The menu bar window: the active job (or the failure that needs attention), the last Daily digest, and
/// the main commands. Uses the window style of `MenuBarExtra` because the job card needs a real progress bar.
struct MenuBarView: View {
    let run: DigestRunModel
    let access: MailAccessModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Closes this panel, as a native menu closes once an item is chosen.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let attention = run.menuAttention
        VStack(alignment: .leading, spacing: 0) {
            if hasTopContent(attention) {
                top(attention: attention)
                Divider().padding(.horizontal, 10)
            }
            VStack(spacing: 0) {
                row("Open Review Panel", shortcut: "o") { show("review") }
                dailyRow
                row("New Backlog Job…", shortcut: "n") { show("job-setup") }
                    .disabled(run.isRunning || access.status?.mode == .unavailable)
                row("Mail Access…") { show("mail-access") }
                row("Settings…", shortcut: ",") {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
                Divider().padding(.horizontal, 10).padding(.vertical, 5)
                row("Quit Mail Digest", shortcut: "q") { NSApplication.shared.terminate(nil) }
            }
            .padding(.vertical, 5)
        }
        .padding(6)
        .frame(width: 340)
    }

    // MARK: Top section

    private func hasTopContent(_ attention: DigestRunModel.MenuAttention?) -> Bool {
        run.activeProgress != nil || attention != nil || run.menuSuggestionsRow(now: Date()) != nil
            || run.lastRunSummary != nil || run.dailyNote != nil
    }

    /// The job card, or the attention state, then the last-run row and any Daily note.
    @ViewBuilder private func top(attention: DigestRunModel.MenuAttention?) -> some View {
        if let progress = run.activeProgress {
            jobSection(progress)
        } else if let attention {
            attentionSection(attention)
        }
        if attention == nil {
            if let row = suggestionsRowView {
                row
            } else if let summary = run.lastRunSummary, run.activeProgress == nil {
                // No Daily digest to describe (for example only a Backlog digest exists): keep the plain line.
                Text(summary).font(.callout).foregroundStyle(.secondary).padding(10)
            }
        }
        if let note = run.dailyNote {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    // MARK: Job section

    private func jobSection(_ progress: JobProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.menuJobTitle(for: progress)).font(.headline)
                Spacer(minLength: 8)
                Text(run.menuModelLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(MenuPanelPresentation.statusLine(progress))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            bar(progress)
            HStack(spacing: 6) { jobButtons(progress) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func bar(_ progress: JobProgress) -> some View {
        if progress.state == .listing || progress.total == 0 {
            ProgressView().progressViewStyle(.linear)
                .accessibilityLabel("Looking for new mail")
        } else {
            ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                .accessibilityLabel("\(run.menuJobTitle(for: progress)) progress")
                .accessibilityValue(ReviewPresentation.counts(progress))
        }
    }

    @ViewBuilder private func jobButtons(_ progress: JobProgress) -> some View {
        switch progress.state {
        case .paused:
            if run.menuCardShowsResume(for: progress) {
                Button("Resume") { Task { await run.resume() } }
            }
            Button("Stop", action: run.stop)
        case .running, .listing:
            Button("Pause", action: run.pause)
            Button("Stop", action: run.stop)
        case .pausing:
            Button("Stop", action: run.stop)
        default:
            EmptyView()
        }
    }

    // MARK: Last Daily digest

    private var suggestionsRowView: AnyView? {
        // Re-evaluated every minute so "this morning" turns into "today" at noon without a new event.
        guard run.menuSuggestionsRow(now: Date()) != nil else { return nil }
        return AnyView(TimelineView(.everyMinute) { context in
            if let row = run.menuSuggestionsRow(now: context.date) {
                HStack(spacing: 10) {
                    SuggestionsTile()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.body.weight(.medium))
                        Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .accessibilityElement(children: .combine)
            }
        })
    }

    // MARK: Attention

    private func attentionSection(_ attention: DigestRunModel.MenuAttention) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = attention.title, let subtitle = attention.subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .padding(10)
                .accessibilityElement(children: .combine)
            }
            attentionCard(attention)
        }
    }

    private func attentionCard(_ attention: DigestRunModel.MenuAttention) -> some View {
        let card = attention.card
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: card.title).font(.headline)
                    Text(verbatim: card.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if card.offersStartOllama {
                        Button("Start Ollama") { OllamaLauncher.start() }
                    }
                    if attention.showsRetry {
                        Button("Retry") { Task { await run.retryAttention() } }
                            .disabled(!run.isAttentionRetryEnabled || access.status?.mode == .unavailable)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))
        // Read as one alert-like group, led by the problem.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs attention. \(card.title)")
    }

    // MARK: Rows

    /// The primary Daily action (Q52). Never starts a second Daily job.
    private var dailyRow: some View {
        let action = run.dailyAction
        // Opening Settings needs no Mail access; everything else reads Mail.
        let needsMail = action.behavior != .review
        let isRetry = run.dailyStartFailedAt != nil && action.behavior == .startNew || {
            if case .retry = action.behavior { return true } else { return false }
        }()
        return row(action.title, shortcut: isRetry ? "r" : nil, accessibilityLabel: action.accessibilityLabel) {
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

    /// One menu row. A shortcut registers the key and shows its hint at the trailing edge.
    @ViewBuilder private func row(_ title: String, shortcut: KeyEquivalent? = nil, accessibilityLabel: String? = nil,
                                  action: @escaping () -> Void) -> some View {
        let button = Button(action: action) { Text(title) }
            .buttonStyle(MenuRowButtonStyle(hint: shortcut.map { "\u{2318}" + String($0.character).uppercased() }))
            .accessibilityLabel(accessibilityLabel ?? title)
        if let shortcut { button.keyboardShortcut(shortcut) } else { button }
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

/// The orange sun tile of the last-run row.
private struct SuggestionsTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.745, blue: 0.302), Color(red: 1, green: 0.541, blue: 0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
