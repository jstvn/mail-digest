import AppKit
import MailDigestCore
import SwiftUI

/// Select All / Select None for one section, scoped to that section's records.
struct SelectionButtons: View {
    let coordinator: ReviewCoordinator
    let records: [SuggestionRecord]

    var body: some View {
        HStack(spacing: 10) {
            Button("Select All") { coordinator.selectAll(records) }
            Button("Select None") { coordinator.selectNone(records) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// A titled list of actionable suggestion rows. `count` is the section's full size, which may exceed
/// `records` when the Q16 page hides some; keyboard focus is shared across all sections of a canvas.
struct ActionableRecordsSection: View {
    let coordinator: ReviewCoordinator
    let title: String
    let count: Int
    let records: [SuggestionRecord]
    let focus: FocusState<UUID?>.Binding
    var emptyText: String = "Nothing to review."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "\(title) (\(count))") {
                SelectionButtons(coordinator: coordinator, records: records)
            }
            if records.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        SuggestionRow(
                            record: record,
                            isSelected: coordinator.isSelected(record),
                            isFocused: focus.wrappedValue == record.id,
                            onToggle: { coordinator.toggle(record) },
                            onEdit: { try await coordinator.edit($0, record: record) },
                            onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: record.suggestion.emailID)) })
                        .focusable()
                        .focusEffectDisabled()
                        .focused(focus, equals: record.id)
                        .id(record.id)
                        Divider()
                    }
                }
            }
        }
    }
}

/// A suggestion that was already added or dismissed: read-only, with its outcome.
struct SettledRecordRow: View {
    let record: SuggestionRecord
    /// The Logbook shows when the decision was made.
    var showsDecisionDate = false

    private var isApproved: Bool { record.suggestion.status == .approved }
    private var outcome: String { isApproved ? "Added" : "Dismissed" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isApproved ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(isApproved ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.suggestion.title).lineLimit(2)
                Text(source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(outcome).font(.callout).foregroundStyle(.secondary)
                if showsDecisionDate, let decided = record.suggestion.decidedAt {
                    Text(decided.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Button {
                NSWorkspace.shared.open(ReviewActions.messageURL(for: record.suggestion.emailID))
            } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Open this email in Mail")
                .accessibilityLabel("Open email in Mail")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
    }

    private var source: String {
        guard let email = record.email else { return "Unknown sender" }
        return "\(ReviewPresentation.senderName(email.sender)) · \(email.subject)"
    }
}

/// Read-only settled rows under a section header.
struct SettledRecordsSection: View {
    let title: String
    let records: [SuggestionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("\(title) (\(records.count))")
            VStack(spacing: 0) {
                ForEach(records) { record in
                    SettledRecordRow(record: record)
                        .id(record.id)
                    Divider()
                }
            }
        }
    }
}
