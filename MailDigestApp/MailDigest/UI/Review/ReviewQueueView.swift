import MailDigestCore
import SwiftUI

/// Every pending and failed suggestion across Daily and Backlog digests, grouped by digest date and loaded in pages.
struct ReviewQueueView: View {
    let run: DigestRunModel
    let access: MailAccessModel

    private var coordinator: ReviewCoordinator { run.coordinator }
    private var queue: PagedRecordsModel { coordinator.reviewQueue }

    /// Groups in on-screen order, without records that were just settled and are about to leave the list.
    private var groups: [DayGroup] {
        queue.groups.compactMap { group in
            let records = group.records.filter(\.isActionable)
            return records.isEmpty ? nil : DayGroup(day: group.day, records: records)
        }
    }

    private struct DayGroup: Identifiable {
        var day: DigestDay
        var records: [SuggestionRecord]
        var id: DigestDay { day }
    }

    var body: some View {
        let groups = groups
        let shown = groups.flatMap(\.records)
        CanvasScaffold(run: run, access: access, title: "Review Queue",
                       subtitle: "\(run.library.archive.reviewQueueCount) unreviewed", records: shown,
                       revealTarget: { _ in nil }) { focus in
            if !queue.isLoaded {
                ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 160)
            } else if queue.loadFailed && shown.isEmpty {
                ContentUnavailableView("Couldn't load the Review Queue", systemImage: "exclamationmark.triangle",
                                       description: Text("Try again in a moment."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if shown.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("No suggestions are waiting for review."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(groups) { group in
                    ActionableRecordsSection(
                        coordinator: coordinator,
                        title: ReviewDateText.day(group.day, calendar: run.library.calendar),
                        count: group.records.count, records: group.records, focus: focus)
                }
                if queue.hasMore {
                    Button("Load More") { Task { await coordinator.loadMoreReviewQueue() } }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
