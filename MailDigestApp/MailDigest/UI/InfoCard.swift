import AppKit
import MailDigestCore
import SwiftUI

/// One email's summary with its key facts, as a row of the Info list. The sender and subject, the time and
/// the actions (pin, save to Notes, open in Mail) sit on the first line. The actions take the place of the
/// status (pin, Notes state, cloud, time) on hover or keyboard focus.
struct InfoCard: View {
    let item: InfoItem
    let email: EmailContext?
    /// Only `.cloud` shows a glyph; local and unknown show nothing.
    var provider: ExecutionProvider?
    var notesState: NotesSaveState = .idle
    /// The reader's own name, so a key fact that only repeats it can be left out.
    var userNames: [String] = []
    var onOpen: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onSaveToNotes: () -> Void = {}

    private enum ActionFocus: Hashable { case pin, notes, open }

    @State private var hovering = false
    @FocusState private var actionFocus: ActionFocus?

    private var isRevealed: Bool { hovering || actionFocus != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if email != nil { topLine }
            Text(item.summary)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            let facts = ReviewPresentation.displayFacts(item.keyFacts, sender: email?.sender, userNames: userNames)
            if !facts.isEmpty {
                let line = facts.joined(separator: " · ")
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
            }
            if case .failed(let reason) = notesState {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // With no linked email there is no first line, so the status and actions sit in the row's corner.
        .overlay(alignment: .topTrailing) {
            if email == nil { trailing.padding(.top, 10).padding(.trailing, 12) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isRevealed)
        .accessibilityElement(children: .contain)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            if let email {
                Text(ReviewPresentation.senderName(email.sender))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(email.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    /// The status and the actions share one trailing slot: the time sits flush right when idle and the
    /// actions replace it on hover or focus. Hidden actions ignore clicks but stay focusable and visible to
    /// VoiceOver.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            status
                .opacity(isRevealed ? 0 : 1)
            actions
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            // The pin and Notes buttons already announce these states, so VoiceOver skips the glyphs.
            if item.pinned {
                Image(systemName: "pin.fill").accessibilityHidden(true)
            }
            switch notesState {
            case .idle:
                EmptyView()
            case .saving:
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            case .saved:
                Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
            }
            if provider == .cloud {
                Image(systemName: "cloud")
                    .help("Summarised by Gemini")
                    .accessibilityLabel("Summarised by Gemini")
            }
            if let received = email?.receivedAt {
                Text(ReviewPresentation.compactAge(of: received, now: .now))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onTogglePin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .focused($actionFocus, equals: .pin)
            .help(item.pinned ? "Unpin this item" : "Pin this item. It carries over to the next digest until unpinned.")
            .accessibilityLabel(item.pinned ? "Unpin" : "Pin")

            Button(action: onSaveToNotes) {
                switch notesState {
                case .idle:
                    Image(systemName: "note.text.badge.plus")
                case .saving:
                    ProgressView().controlSize(.small)
                case .saved:
                    Image(systemName: "checkmark").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "note.text.badge.plus").foregroundStyle(.red)
                }
            }
            .disabled(notesState == .saving)
            .focused($actionFocus, equals: .notes)
            .help("Save to Notes")
            .accessibilityLabel(accessibilityNotesLabel)

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.app")
            }
            .focused($actionFocus, equals: .open)
            .help("Open this email in Mail")
            .accessibilityLabel("Open email in Mail")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var accessibilityNotesLabel: String {
        switch notesState {
        case .idle, .failed: return "Save to Notes"
        case .saving: return "Saving to Notes"
        case .saved: return "Saved to Notes"
        }
    }
}

#Preview("Info card") {
    let items = PreviewFixtures.digest.info
    return GroupedCard {
        InfoCard(item: items[0], email: PreviewFixtures.emails["canvas@qut.example"], userNames: ["Justin Wang"])
        Divider()
        InfoCard(item: items[items.count > 1 ? 1 : 0], email: nil, provider: .cloud, notesState: .saved)
    }
    .padding().frame(width: 560)
}
