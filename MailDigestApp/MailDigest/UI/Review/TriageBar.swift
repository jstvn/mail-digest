import SwiftUI
import MailDigestCore

/// The floating bar over a canvas with actionable suggestions: "N selected · Dismiss Unselected · Add to
/// Reminders". It acts on exactly `records`, the actionable suggestions the canvas shows.
struct TriageBar: View {
    let coordinator: ReviewCoordinator
    let records: [SuggestionRecord]
    /// True when the view hides actionable suggestions; the actions leave those untouched.
    var isPartial = false

    var body: some View {
        let selected = coordinator.selectedCount(in: records)
        HStack(spacing: 14) {
            Text(ReviewCanvasLogic.selectionText(selected: selected, shown: records.count, isPartial: isPartial))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Dismiss Unselected") { Task { await coordinator.dismissUnselected(in: records) } }
                .disabled(coordinator.unselectedCount(in: records) == 0 || coordinator.isWorking)
                .help(isPartial ? "Dismiss the suggestions shown that aren't ticked. Hidden suggestions aren't affected."
                                : "Dismiss the suggestions shown that aren't ticked")
            Button("Add to Reminders") { Task { await coordinator.addSelected(in: records) } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canAddSelected(in: records))
                .help(coordinator.reminderWriter == nil ? "Reminders access isn't available" : (isPartial ? "Add the ticked suggestions shown to Reminders. Hidden suggestions aren't affected." : "Add the ticked suggestions to Reminders"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Triage")
    }
}
