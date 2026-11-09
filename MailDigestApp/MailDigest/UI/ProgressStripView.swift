import MailDigestCore
import SwiftUI

/// Job name, progress bar, counts, the current email, and Pause / Resume / Stop.
/// Shared by the review panel and the menu bar window; actions are closures so previews need no runner.
struct ProgressStripView: View {
    let progress: JobProgress
    var pauseReason: String?
    /// The job's name for the paused line ("Backlog · 12 Nov · Paused at 12 of 40"); without it the older wording shows.
    var haltedTitle: String?
    var onPause: () -> Void = {}
    /// When set, Pause becomes a menu button with "Pause Now" (cancels the email in flight).
    var onPauseNow: (() -> Void)?
    var onResume: () -> Void = {}
    /// False where another control already resumes this job, such as the menu's primary Daily action (Q52).
    var showsResume = true
    var onStop: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ReviewPresentation.jobName(progress.kind))
                    .font(.headline)
                Spacer()
                buttons
            }
            bar
            Text(primaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if progress.state == .running, let now = ReviewPresentation.nowLine(progress) {
                Text(now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(now)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var bar: some View {
        if progress.state == .listing || progress.total == 0 {
            ProgressView().progressViewStyle(.linear)
                .accessibilityLabel("Looking for new mail")
        } else {
            ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                .accessibilityLabel("\(ReviewPresentation.jobName(progress.kind)) progress")
                .accessibilityValue(ReviewPresentation.counts(progress))
        }
    }

    private var primaryText: String {
        switch progress.state {
        case .listing: return "Looking for new mail…"
        case .paused:
            let reason = pauseReason ?? progress.pauseReason?.displayText
            if let haltedTitle, let line = MenuPanelPresentation.haltedLine(
                jobTitle: haltedTitle, state: .paused, done: progress.done, total: progress.total, reason: reason) {
                return line
            }
            return ReviewPresentation.pausedText(progress, reason: pauseReason ?? progress.pauseReason?.displayText)
        case .pausing: return "Pausing after this email · " + ReviewPresentation.counts(progress)
        case .stopping: return "Stopping…"
        default: return ReviewPresentation.counts(progress)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            switch progress.state {
            case .paused:
                if showsResume { Button("Resume", action: onResume) }
                Button("Stop", role: .destructive, action: onStop)
            case .running, .listing:
                if let onPauseNow {
                    Menu("Pause") {
                        Button("Pause Now", action: onPauseNow)
                    } primaryAction: {
                        onPause()
                    }
                    .help("Pause after this email. Choose Pause Now to cancel the email in progress.")
                } else {
                    Button("Pause", action: onPause)
                }
                Button("Stop", role: .destructive, action: onStop)
            case .pausing:
                Button("Stop", role: .destructive, action: onStop)
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }
}

#Preview("Running") {
    ProgressStripView(progress: PreviewFixtures.runningProgress)
        .padding().frame(width: 560)
}

#Preview("Paused") {
    ProgressStripView(progress: PreviewFixtures.pausedProgress, pauseReason: "battery power")
        .padding().frame(width: 560)
}
