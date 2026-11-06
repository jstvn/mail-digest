import MailDigestCore
import SwiftUI

/// Settings > Jobs: every job with its mailboxes, scope, totals and processing time. A paused, stopped or
/// outage-stopped job can be resumed from here, including one left over from a previous session.
struct PastJobsView: View {
    let run: DigestRunModel
    private let timeZone = RunnerSettings().timeZone

    var body: some View {
        Group {
            if run.pastJobs.isEmpty {
                ContentUnavailableView("No jobs yet", systemImage: "tray",
                                       description: Text("Daily and Backlog jobs appear here."))
            } else {
                List(run.pastJobs) { row in
                    PastJobRowView(row: row, timeZone: timeZone, run: run)
                }
            }
        }
        .task { await run.refreshPastJobs() }
        .onChange(of: run.progress?.state) { _, _ in Task { await run.refreshPastJobs() } }
    }
}

private struct PastJobRowView: View {
    let row: PastJobRow
    let timeZone: TimeZone
    let run: DigestRunModel

    private var job: Job { row.job }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(JobSummaryText.title(job)).font(.headline).lineLimit(2)
                Text("\(JobSummaryText.state(job)) · \(JobSummaryText.scope(job, timeZone: timeZone))")
                    .font(.callout).foregroundStyle(.secondary)
                Text(JobSummaryText.totals(job)).font(.callout).foregroundStyle(.secondary)
                Text(duration).font(.caption).foregroundStyle(.secondary)
                if job.state == .failed, let error = job.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if JobSummaryText.canResume(job) {
                    Button("Resume") { Task { await run.resumeJob(job.id) } }
                        .disabled(run.isRunning)
                }
                if JobSummaryText.canRetryFailed(job) {
                    Button("Retry Failed") { Task { await run.retryFailedItems(of: job.id) } }
                        .disabled(run.isRunning)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var duration: String {
        let started = job.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard row.processingSeconds >= 60 else { return "Started \(started)" }
        return "Started \(started) · \(JobFormat.duration(row.processingSeconds)) of processing"
    }
}

#if DEBUG
#Preview("Past jobs") {
    PastJobsView(run: PreviewSupport.run())
        .frame(width: 520, height: 400)
}
#endif
