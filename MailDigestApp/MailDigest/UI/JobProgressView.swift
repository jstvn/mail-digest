import MailDigestCore
import SwiftUI

/// The job status popover: the progress strip, the three most recent emails, Retry Failed and a link to the
/// Activity canvas, where the full log lives. Sender and subject only; email bodies never appear here.
struct JobProgressView: View {
    let run: DigestRunModel
    let progress: JobProgress
    /// Called when a Recent row is clicked, with that email's message id.
    var onReveal: (String) -> Void = { _ in }
    /// Called by "View All Activity".
    var onViewAll: () -> Void = {}

    private let feed = ActivityFeed()

    /// The job's items, only when they belong to the job shown.
    private var items: [JobItem] { run.activityJobID == progress.jobID ? run.activityItems : [] }
    private var messageIDs: [UUID: String] { Dictionary(items.map { ($0.id, $0.messageID) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressStripView(progress: progress, onPause: run.pause, onPauseNow: run.pauseNow,
                              onResume: { Task { await run.resume() } }, onStop: run.stop)
            recent
            if progress.failed > 0 {
                Button("Retry Failed") { Task { await run.retryFailedItems(of: progress.jobID) } }
                    .disabled(run.isRunning)
                    .help(run.isRunning ? "Available when no job is running" : "Requeue the failed emails and resume this job")
            }
            Button("View All Activity", action: onViewAll)
                .help("Open Activity in the review window")
        }
        .task(id: progress.jobID) { await run.refreshActivity(jobID: progress.jobID) }
    }

    // MARK: Recent

    @ViewBuilder private var recent: some View {
        let rows = feed.recent(items, limit: 3)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RECENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    Button {
                        if let id = messageIDs[row.id] { onReveal(id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(ReviewPresentation.senderName(row.sender)) · \(row.subject)")
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(row.outcome ?? row.state.rawValue)
                                .foregroundStyle(row.state == .failed ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this email's results")
                    .accessibilityHint("Shows this email's results")
                }
            }
        }
    }
}
