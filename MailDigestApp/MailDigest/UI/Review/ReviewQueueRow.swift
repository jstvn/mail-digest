import MailDigestCore
import SwiftUI

/// One Review Queue list row: a checkbox for bulk actions, the title, "Sender · In 11 days", and priority marks.
/// Selection styling comes from the enclosing `List`; the row only adapts its own colours to it.
struct ReviewQueueRow: View {
    let record: SuggestionRecord
    let isChecked: Bool
    let calendar: Calendar
    var now: Date = .now
    var onToggle: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpen: () -> Void = {}

    @Environment(\.backgroundProminence) private var prominence

    private var suggestion: Suggestion { record.suggestion }
    private var senderName: String { record.email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender" }

    private var level: PriorityBadge.Level {
        switch suggestion.priority { case .high: .high; case .medium: .medium; case .low: .low }
    }

    /// "Philip Fraser · In 11 days", with a note when the suggestion needs a look or couldn't be added.
    private var metaLine: String {
        var parts = [senderName, RelativeDue.make(due: suggestion.due, hasTime: suggestion.dueHasTime, now: now, calendar: calendar).top]
        if suggestion.status == .failed { parts.append("Couldn't add") } else if !suggestion.flags.isEmpty { parts.append("Needs review") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(checkStyle)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isChecked ? "Deselect this suggestion" : "Select this suggestion")
            .accessibilityHidden(true) // The row's own custom action toggles it.

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            PriorityBadge(level: level, style: .marks)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button(isChecked ? "Deselect" : "Select", action: onToggle)
            Button("Open in Mail", action: onOpen)
            if suggestion.status == .pending { Button("Dismiss", role: .destructive, action: onDismiss) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SuggestionAccessibility.label(for: record, isSelected: isChecked, now: now, calendar: calendar))
        .accessibilityAction(named: isChecked ? "Deselect" : "Select", onToggle)
        .accessibilityAction(named: "Dismiss") { if suggestion.status == .pending { onDismiss() } }
        .accessibilityAction(named: "Open in Mail", onOpen)
    }

    /// Accent when ticked, but white on a selected row where the accent fill would hide it.
    private var checkStyle: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.white.opacity(isChecked ? 1 : 0.8)) }
        return isChecked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }
}

#if DEBUG
#Preview("Queue rows") {
    let records = SuggestionRecord.records(from: PreviewFixtures.digest, kind: .daily, emails: PreviewFixtures.emails)
    List {
        ForEach(records.prefix(4)) { record in
            ReviewQueueRow(record: record, isChecked: record.suggestion.preselected, calendar: PreviewSupport.calendar,
                           now: PreviewFixtures.now)
        }
    }
    .frame(width: 384, height: 300)
}
#endif
