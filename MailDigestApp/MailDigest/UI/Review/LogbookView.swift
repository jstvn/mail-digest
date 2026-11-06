import MailDigestCore
import SwiftUI

/// Approved and dismissed suggestions, newest decision first (Q57), with their outcome and decision time.
struct LogbookView: View {
    let run: DigestRunModel
    let access: MailAccessModel

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var logbook: PagedRecordsModel { coordinator.logbook }

    var body: some View {
        CanvasScaffold(run: run, access: access, title: "Logbook", subtitle: subtitle) { _ in
            if !logbook.isLoaded {
                ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 160)
            } else if logbook.records.isEmpty {
                ContentUnavailableView("Nothing decided yet", systemImage: "checkmark.circle",
                                       description: Text("Suggestions you add or dismiss appear here."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(logbook.records) { record in
                        SettledRecordRow(record: record, showsDecisionDate: true)
                        Divider()
                    }
                }
                if logbook.hasMore {
                    Button("Load More") { Task { await coordinator.loadMoreLogbook() } }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var subtitle: String? {
        guard logbook.isLoaded, !logbook.records.isEmpty else { return nil }
        let count = logbook.records.count
        return "\(count)\(logbook.hasMore ? "+" : "") \(count == 1 && !logbook.hasMore ? "decision" : "decisions")"
    }
}
