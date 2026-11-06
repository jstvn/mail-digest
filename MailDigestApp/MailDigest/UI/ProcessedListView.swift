import AppKit
import MailDigestCore
import SwiftUI

/// The Processed tab: fully handled emails the user can clear from the inbox in one click.
/// Nothing moves until a button is clicked; Keep only hides the rows.
struct ProcessedListView: View {
    let model: ProcessedMailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.failures.isEmpty { failureList }
            if let problem = model.undoProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.allEntries.isEmpty {
                ContentUnavailableView("Nothing to clear", systemImage: "tray.full",
                                       description: Text("Emails appear here once every suggestion from them is added or dismissed."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(model.groupedHandled, id: \.account) { group in
                    section(title: group.account, entries: group.entries)
                }
                if !model.processed.blocked.isEmpty {
                    Text("BLOCKED SENDERS (\(model.processed.blocked.count))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 4)
                    ForEach(model.groupedBlocked, id: \.account) { group in
                        section(title: group.account, entries: group.entries)
                    }
                }
            }
        }
    }

    private func section(title: String, entries: [ProcessedEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(entries.count))")
                .font(.body.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    ProcessedRow(entry: entry,
                                 isTicked: model.isTicked(entry.id),
                                 onTick: { model.setTicked($0, id: entry.id) },
                                 onOpen: { NSWorkspace.shared.open(ReviewActions.messageURL(for: entry.emailID)) })
                    Divider()
                }
            }
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Some emails weren't moved", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.medium))
                Spacer()
                if model.needsAutomationAccess {
                    Button("Open Automation Settings…") {
                        if let url = URL(string: MailAccessStatus.automationSettingsURL) { NSWorkspace.shared.open(url) }
                    }
                }
                Button("Dismiss", action: model.dismissFailures)
            }
            .controlSize(.small)
            ForEach(model.failures) { failure in
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.title).lineLimit(1).truncationMode(.tail)
                    Text(MailActionFailure.explanation(for: failure.reason))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// One processed email: checkbox, sender, subject, date, summary and outcome.
private struct ProcessedRow: View {
    let entry: ProcessedEntry
    let isTicked: Bool
    let onTick: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { isTicked }, set: { onTick($0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(entry.email.subject)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ReviewPresentation.senderName(entry.email.sender)).font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    if let received = entry.email.receivedAt {
                        Text(received.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.email.subject).lineLimit(1).truncationMode(.tail)
                if let summary = entry.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Text(entry.outcome.prefix(1).uppercased() + entry.outcome.dropFirst())
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button(action: onOpen) { Image(systemName: "arrow.up.forward.square") }
                .help("Open this email in Mail")
                .accessibilityLabel("Open email in Mail")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

/// The Processed tab's buttons, pinned below the list.
struct ProcessedActionBar: View {
    let model: ProcessedMailModel

    var body: some View {
        HStack {
            Button("Select All", action: model.selectAll)
            Button("Select None", action: model.selectNone)
            Button("Select All Newsletters", action: model.selectNewsletters)
                .disabled(!model.hasNewsletters)
            Text("\(model.tickedCount) of \(model.allEntries.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Keep") { Task { await model.keep() } }
                .disabled(!model.canAct)
                .help("Hide the selected emails from this list and leave them in Mail")
            Button("Move to Mail Digest Folder") { Task { await model.moveToDigestFolder() } }
                .disabled(!model.canAct)
                .help("Move the selected emails to a Mail Digest mailbox in their own account")
            Button("Move to Trash") { Task { await model.moveToTrash() } }
                .keyboardShortcut(.delete, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAct)
                .help("Move the selected emails to Trash. Nothing is deleted permanently.")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A non-modal floating capsule for the latest move, with Undo. It stays until a newer move replaces it or
/// Undo is used. Shown in an overlay (bottom-centred) so it never pushes content.
struct UndoToast: View {
    let model: ProcessedMailModel

    var body: some View {
        if let batch = model.lastBatch {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(batch.summary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button("Undo") { Task { await model.undo() } }
                    .disabled(model.isWorking)
                    .help("Move these emails back to where they were")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .frame(maxWidth: 560)
            .accessibilityElement(children: .contain)
        }
    }
}
