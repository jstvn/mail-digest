import AppKit
import MailDigestCore
import SwiftUI

/// One email's summary with its key facts, as a row of the Info list. The sender and subject, the time and
/// the actions (pin, save to Notes, open in Mail) sit on the first line; the actions appear on hover or
/// keyboard focus, except a pin that is set and a Notes save in progress or finished.
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
    private var showsPin: Bool { isRevealed || item.pinned }
    private var showsNotes: Bool { isRevealed || notesState != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            topLine
            Text(item.summary)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            let facts = ReviewPresentation.displayFacts(item.keyFacts, sender: email?.sender, userNames: userNames)
            // Offsets as ids: the model can repeat a fact, and `\.self` would then collide.
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                Label {
                    Text(fact).font(.callout)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 4))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
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
            if provider == .cloud {
                Image(systemName: "cloud")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Summarised by Gemini")
                    .accessibilityLabel("Summarised by Gemini")
            }
            if let received = email?.receivedAt {
                Text(received.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            actions
        }
    }

    /// The buttons keep their space when hidden so nothing shifts; hidden ones ignore clicks but stay
    /// focusable and visible to VoiceOver.
    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onTogglePin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .focused($actionFocus, equals: .pin)
            .opacity(showsPin ? 1 : 0)
            .allowsHitTesting(showsPin)
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
            .opacity(showsNotes ? 1 : 0)
            .allowsHitTesting(showsNotes)
            .help("Save to Notes")
            .accessibilityLabel(accessibilityNotesLabel)

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .focused($actionFocus, equals: .open)
            .opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
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

/// The surface that holds a group of info rows: one rounded card with dividers between the rows.
struct InfoCardList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

#Preview("Info card") {
    let items = PreviewFixtures.digest.info
    return InfoCardList {
        InfoCard(item: items[0], email: PreviewFixtures.emails["canvas@qut.example"], userNames: ["Justin Wang"])
        Divider()
        InfoCard(item: items[items.count > 1 ? 1 : 0], email: nil, provider: .cloud, notesState: .saved)
    }
    .padding().frame(width: 560)
}
