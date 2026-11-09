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
struct ScopeAction {
    var title: String
    var help: String
    var action: () -> Void
}

struct ActionableRecordsSection: View {
    let coordinator: ReviewCoordinator
    let title: String
    let count: Int
    let records: [SuggestionRecord]
    let focus: FocusState<UUID?>.Binding
    var emptyText: String = "Nothing to review."
    /// Replaces the plain count, e.g. "25 of 42" when the section is truncated.
    var countText: String?
    /// Header button that widens or narrows the section, e.g. Show All.
    var scopeAction: ScopeAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "\(title) · \(countText ?? String(count))") {
                HStack(spacing: 10) {
                    if let scopeAction {
                        Button(scopeAction.title, action: scopeAction.action)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help(scopeAction.help)
                    }
                    SelectionButtons(coordinator: coordinator, records: records)
                }
            }
            if records.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                GroupedCard {
                    LazyVStack(spacing: 0) {
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
                            // Dividers sit between rows only, inset past the checkbox.
                            if record.id != records.last?.id { Divider().padding(.leading, 36) }
                        }
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

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isApproved ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(isApproved ? Color.green : Color.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                titleText
                StaticSuggestionPills(suggestion: record.suggestion, category: record.category)
                EvidenceQuote(sender: email.map { ReviewPresentation.senderName($0.sender) } ?? "Unknown sender",
                              evidence: record.suggestion.evidence, emphasised: hovering) {
                    NSWorkspace.shared.open(ReviewActions.messageURL(for: record.suggestion.emailID))
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(outcome).font(.callout).foregroundStyle(.secondary)
                if showsDecisionDate, let decided = record.suggestion.decidedAt {
                    Text(decided.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background {
            if hovering { Rectangle().fill(.quaternary.opacity(0.5)) }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var email: EmailContext? { record.email }

    private var titleText: some View {
        Text(record.suggestion.title).font(.body.weight(.medium)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Read-only settled rows under a section header.
struct SettledRecordsSection: View {
    let title: String
    let records: [SuggestionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("\(title) · \(records.count)")
            GroupedCard {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        SettledRecordRow(record: record)
                            .id(record.id)
                        if record.id != records.last?.id { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }
}
