import MailDigestCore
import SwiftUI

/// The progress strip plus Recent, per-mailbox counts and the collapsed activity log with Retry failed.
/// Sender and subject only; email bodies never appear here.
struct JobProgressView: View {
    let run: DigestRunModel
    let progress: JobProgress
    /// Called when a Recent row is clicked, with that email's message id.
    var onReveal: (String) -> Void = { _ in }

    @State private var logExpanded = false
    @State private var logFilter: LogFilter = .all

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All", queued = "Queued", done = "Done", failed = "Failed", skipped = "Skipped"
        var id: String { rawValue }
        var state: JobItemState? {
            switch self {
            case .all: return nil
            case .queued: return .queued
            case .done: return .done
            case .failed: return .failed
            case .skipped: return .skipped
            }
        }
    }

    private let feed = ActivityFeed()

    /// The job's items, only when they belong to the job shown.
    private var items: [JobItem] { run.activityJobID == progress.jobID ? run.activityItems : [] }
    private var messageIDs: [UUID: String] { Dictionary(items.map { ($0.id, $0.messageID) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressStripView(progress: progress, onPause: run.pause, onPauseNow: run.pauseNow,
                              onResume: { Task { await run.resume() } }, onStop: run.stop)
            recent
            mailboxCounts
            activityLog
        }
        .task(id: progress.jobID) { await run.refreshActivity(jobID: progress.jobID) }
    }

    // MARK: Recent

    @ViewBuilder private var recent: some View {
        let rows = feed.recent(items, limit: 5)
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

    // MARK: Per mailbox

    @ViewBuilder private var mailboxCounts: some View {
        let counts = progress.countsByMailbox.sorted { ($0.key.account, $0.key.name) < ($1.key.account, $1.key.name) }
        if counts.count > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("MAILBOXES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(counts, id: \.key) { box, count in
                    HStack {
                        Text("\(box.account) · \(box.name)")
                        Spacer()
                        Text("\(JobFormat.number(count.done)) of \(JobFormat.number(count.total))").monospacedDigit()
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Activity log

    private var activityLog: some View {
        DisclosureGroup(isExpanded: $logExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Show", selection: $logFilter) {
                        ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    Spacer()
                    if progress.failed > 0 {
                        Button("Retry Failed") { Task { await run.retryFailedItems(of: progress.jobID) } }
                            .disabled(run.isRunning)
                            .help(run.isRunning ? "Available when no job is running" : "Requeue the failed emails and resume this job")
                    }
                }
                .controlSize(.small)
                let rows = feed.rows(items, filter: logFilter.state)
                if rows.isEmpty {
                    Text("Nothing to show.").foregroundStyle(.secondary).font(.callout)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(rows) { row in ActivityRowView(row: row) }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Activity log").font(.body.weight(.medium))
        }
    }
}

/// One row of the activity log: time, position, sender, subject, mailbox, outcome and seconds.
private struct ActivityRowView: View {
    let row: ActivityRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.finishedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                .frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
            Text("#\(row.position)").monospacedDigit().frame(width: 44, alignment: .leading)
            Text("\(ReviewPresentation.senderName(row.sender)) · \(row.subject)")
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(row.mailbox.account).foregroundStyle(.secondary).lineLimit(1)
            Text(row.outcome ?? row.state.rawValue)
                .foregroundStyle(row.state == .failed ? Color.red : Color.secondary).lineLimit(1)
            if let seconds = row.seconds, seconds > 0 {
                Text("\(Int(seconds.rounded())) s").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
