import MailDigestCore
import SwiftUI

/// One email's summary with its key facts, plus buttons to open it in Mail, pin it and save it to Notes.
struct InfoCard: View {
    let item: InfoItem
    let email: EmailContext?
    var notesState: NotesSaveState = .idle
    var onOpen: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onSaveToNotes: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.summary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(item.keyFacts, id: \.self) { fact in
                    Label {
                        Text(fact).font(.caption)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 4))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                }
                if let email {
                    Text("\(ReviewPresentation.senderName(email.sender)) · \(email.subject)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if case .failed(let reason) = notesState {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(action: onTogglePin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
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
                .help("Save to Notes")
                .accessibilityLabel(accessibilityNotesLabel)

                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open this email in Mail")
                .accessibilityLabel("Open email in Mail")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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
    let item = PreviewFixtures.digest.info[0]
    return InfoCard(item: item, email: PreviewFixtures.emails["canvas@qut.example"])
        .padding().frame(width: 560)
}
