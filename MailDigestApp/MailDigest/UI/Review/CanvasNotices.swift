import AppKit
import MailDigestCore
import SwiftUI

/// Everything between the header and the content: alert banners, the latest action problem and the
/// ignore-sender offer. The job progress lives in the sidebar pill, not here.
struct CanvasNotices: View {
    let run: DigestRunModel
    let access: MailAccessModel

    private var coordinator: ReviewCoordinator { run.coordinator }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(PanelAlert.current(run: run, access: access, reminders: run.reminders.status)) { alert in
                AlertBanner(alert: alert, canRetry: !run.isRunning, onRetry: retry,
                            onRequestReminders: { Task { await run.reminders.request() } })
            }
            if let message = coordinator.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            if let suggestion = coordinator.ignoreSuggestion {
                IgnoreSuggestionNotice(suggestion: suggestion,
                                       name: coordinator.ignoreSuggestionName ?? suggestion.sender,
                                       onIgnore: coordinator.acceptIgnoreSuggestion,
                                       onNotNow: coordinator.snoozeIgnoreSuggestion,
                                       onDecline: coordinator.declineIgnoreSuggestion)
            }
        }
    }

    private func retry() {
        Task {
            if run.failedJobID != nil { await run.retryFailedJob() } else { await run.runNow() }
        }
    }
}

/// An inline, non-modal offer to ignore a sender the user keeps dismissing. Nothing changes until "Ignore Sender".
struct IgnoreSuggestionNotice: View {
    let suggestion: IgnoreSuggestion
    let name: String
    let onIgnore: () -> Void
    let onNotNow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You've dismissed \(suggestion.dismissedCount) suggestions from \(name). Ignore this sender in future digests?")
                    .fixedSize(horizontal: false, vertical: true)
                if name != suggestion.sender {
                    Text(suggestion.sender).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Ignore Sender", action: onIgnore)
            Button("Not Now", action: onNotNow)
            Button("Don't Ask Again", action: onDecline)
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// A banner with the fix and, where it applies, a button for it.
struct AlertBanner: View {
    let alert: PanelAlert
    let canRetry: Bool
    let onRetry: () -> Void
    let onRequestReminders: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch alert {
            case .runProblem:
                Button("Retry", action: onRetry).disabled(!canRetry)
            case .mailAutomationDenied:
                Button("Open Automation Settings…") { open(MailAccessStatus.automationSettingsURL) }
            case .fullDiskAccessFallback:
                Button("Open Full Disk Access Settings…") { open(MailAccessStatus.fullDiskAccessSettingsURL) }
            case .remindersNeedAccess:
                Button("Allow Reminders Access…", action: onRequestReminders)
            case .remindersUnavailable:
                Button("Open Reminders Settings…") { open(PanelAlert.remindersSettingsURL) }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch alert {
        case .fullDiskAccessFallback: return "info.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch alert {
        case .fullDiskAccessFallback: return .blue
        default: return .orange
        }
    }

    private var message: String {
        switch alert {
        case .runProblem(let text): return text
        case .mailAutomationDenied:
            return "Mail Automation is turned off. Enable Mail access for Mail Digest in Automation settings."
        case .fullDiskAccessFallback:
            return "Using the Mail automation fallback. Full Disk Access enables fast local reads of your mail."
        case .remindersNeedAccess:
            return "Mail Digest needs access to Reminders to add the suggestions you approve. Add to Reminders is turned off until you allow it."
        case .remindersUnavailable:
            return "Reminders access isn't available, so Add to Reminders is turned off. Allow Mail Digest in Privacy & Security > Reminders."
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
