import AppKit
import MailDigestCore
import SwiftUI

extension EmailCategory {
    /// The SF Symbol on a Worth Knowing card's overline.
    var symbolName: String {
        switch self {
        case .uni: return "graduationcap"
        case .work: return "briefcase"
        case .finance: return "creditcard"
        case .deliveries: return "shippingbox"
        case .events: return "calendar"
        case .newsletters: return "newspaper"
        case .personal: return "person"
        case .other: return "tray"
        }
    }
}

/// What a Worth Knowing card needs from its canvas: email lookups and the per-item actions.
struct InfoContext {
    var email: (String) -> EmailContext?
    var provider: (String) -> ExecutionProvider?
    var notesState: (InfoItem) -> NotesSaveState
    /// The reader's own name, so a key fact that only repeats it can be left out.
    var userNames: [String]
    var onOpen: (InfoItem) -> Void
    var onTogglePin: (InfoItem) -> Void
    var onSaveToNotes: (InfoItem) -> Void
}

/// A Worth Knowing card: one email's summary, or several from one sender on one day collapsed into one card that
/// expands to the individual items. Hover or keyboard focus shows Pin, Save to Notes and Open in Mail; the same
/// actions are in the context menu and the accessibility actions, so a mouse is never required.
struct InfoClusterCard: View {
    enum Layout { case card, slim }

    let cluster: InfoCluster
    var layout: Layout = .card
    let context: InfoContext
    @Binding var isExpanded: Bool

    @State private var hovering = false

    private var lead: InfoItem { cluster.lead }
    private var email: EmailContext? { context.email(lead.emailID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch layout {
                case .card: cardBody
                case .slim: slimBody
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            if cluster.isGroup, isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cluster.items) { item in
                        InfoItemRow(item: item, context: context).id(item.id)
                        if item.id != cluster.items.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
        }
        .cardSurface(cornerRadius: layout == .card ? 14 : 10)
        .contextMenu { menuItems }
        .modifier(ClusterAccessibility(cluster: cluster, isExpanded: $isExpanded, context: context))
    }

    // MARK: Layouts

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(cluster.category.rawValue.uppercased(), systemImage: cluster.category.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            Text(lead.summary)
                .font(.system(size: 14.5, weight: .medium))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !footerText.isEmpty {
                Text(footerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footerText)
            }
            if !cluster.isGroup, case .failed(let reason) = context.notesState(lead) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var slimBody: some View {
        HStack(spacing: 8) {
            if let name = cluster.senderName {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
            }
            Text(lead.summary).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            if cluster.isGroup {
                Text(cluster.countText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// A single card shows its status and, on hover, its actions. A group shows the expand button instead; its
    /// items carry their own actions once expanded.
    @ViewBuilder private var trailing: some View {
        if cluster.isGroup {
            Button { isExpanded.toggle() } label: {
                Label(isExpanded ? "Hide Details" : "Show Details", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide the individual emails" : "Show the individual emails")
        } else {
            InfoTrailing(item: lead, context: context, isHovering: hovering)
        }
    }

    /// "Uber Eats · 3 receipts · $51.35 total", or "Ray White · $540 due Friday" for a single item.
    private var footerText: String {
        var parts: [String] = []
        if let name = cluster.senderName { parts.append(name) }
        if cluster.isGroup {
            parts.append(cluster.countText)
            if let total = cluster.total { parts.append("\(total.text) total") }
        } else {
            parts += ReviewPresentation.displayFacts(lead.keyFacts, sender: email?.sender, userNames: context.userNames)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var menuItems: some View {
        if cluster.isGroup {
            Button(isExpanded ? "Hide Details" : "Show Details") { isExpanded.toggle() }
            // A group is one sender on one day, so the lead's sender is every item's sender.
            SenderRuleMenuItems(sender: email?.sender)
        } else {
            InfoMenuItems(item: lead, context: context)
        }
    }
}

/// The card reads as one element. A single item gets Pin, Save to Notes and Open in Mail as custom actions; a
/// group gets Show or Hide Details, and its items are separate elements once expanded.
private struct ClusterAccessibility: ViewModifier {
    let cluster: InfoCluster
    @Binding var isExpanded: Bool
    let context: InfoContext

    func body(content: Content) -> some View {
        if cluster.isGroup {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityAction(named: isExpanded ? "Hide Details" : "Show Details") { isExpanded.toggle() }
        } else {
            let item = cluster.lead
            content
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { context.onTogglePin(item) }
                .accessibilityAction(named: "Save to Notes") { context.onSaveToNotes(item) }
                .accessibilityAction(named: "Open in Mail") { context.onOpen(item) }
        }
    }

    private var label: String {
        var text = "\(cluster.category.rawValue.capitalized). \(cluster.lead.summary)"
        if let name = cluster.senderName { text += " From \(name). \(cluster.countText)." }
        if let total = cluster.total { text += " \(total.text) in total." }
        return text
    }
}

/// One item inside an expanded group.
private struct InfoItemRow: View {
    let item: InfoItem
    let context: InfoContext
    @State private var hovering = false

    var body: some View {
        let facts = ReviewPresentation.displayFacts(item.keyFacts, sender: context.email(item.emailID)?.sender,
                                                    userNames: context.userNames)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.summary).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                InfoTrailing(item: item, context: context, isHovering: hovering)
            }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { InfoMenuItems(item: item, context: context) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { context.onTogglePin(item) }
        .accessibilityAction(named: "Save to Notes") { context.onSaveToNotes(item) }
        .accessibilityAction(named: "Open in Mail") { context.onOpen(item) }
    }
}

/// Pin, Save to Notes and Open in Mail as menu items.
private struct InfoMenuItems: View {
    let item: InfoItem
    let context: InfoContext

    var body: some View {
        Button(item.pinned ? "Unpin" : "Pin") { context.onTogglePin(item) }
        Button("Save to Notes") { context.onSaveToNotes(item) }
            .disabled(context.notesState(item) == .saving)
        Button("Open in Mail") { context.onOpen(item) }
        SenderRuleMenuItems(sender: context.email(item.emailID)?.sender)
    }
}

/// The status (pin, Notes state, cloud, age) and the actions share one trailing slot: the status sits flush
/// right when idle and the actions replace it on hover or keyboard focus. Hidden actions ignore clicks but
/// stay focusable.
private struct InfoTrailing: View {
    let item: InfoItem
    let context: InfoContext
    let isHovering: Bool

    private enum ActionFocus: Hashable { case pin, notes, open }
    @FocusState private var actionFocus: ActionFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRevealed: Bool { isHovering || actionFocus != nil }
    private var notesState: NotesSaveState { context.notesState(item) }

    var body: some View {
        ZStack(alignment: .trailing) {
            status.opacity(isRevealed ? 0 : 1)
            actions.opacity(isRevealed ? 1 : 0).allowsHitTesting(isRevealed)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isRevealed)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if item.pinned { Image(systemName: "pin.fill") }
            switch notesState {
            case .idle: EmptyView()
            case .saving: ProgressView().controlSize(.mini)
            case .saved: Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if context.provider(item.emailID) == .cloud {
                Image(systemName: "cloud").help("Summarised by Gemini")
            }
            if let received = context.email(item.emailID)?.receivedAt {
                Text(ReviewPresentation.compactAge(of: received, now: .now)).lineLimit(1).fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { context.onTogglePin(item) } label: { Image(systemName: item.pinned ? "pin.fill" : "pin") }
                .focused($actionFocus, equals: .pin)
                .help(item.pinned ? "Unpin this item" : "Pin this item. It carries over to the next digest until unpinned.")
                .accessibilityLabel(item.pinned ? "Unpin" : "Pin")

            Button { context.onSaveToNotes(item) } label: {
                switch notesState {
                case .idle: Image(systemName: "note.text.badge.plus")
                case .saving: ProgressView().controlSize(.small)
                case .saved: Image(systemName: "checkmark").foregroundStyle(.green)
                case .failed: Image(systemName: "note.text.badge.plus").foregroundStyle(.red)
                }
            }
            .disabled(notesState == .saving)
            .focused($actionFocus, equals: .notes)
            .help("Save to Notes")
            .accessibilityLabel(notesLabel)

            Button { context.onOpen(item) } label: { Image(systemName: "arrow.up.forward.app") }
                .focused($actionFocus, equals: .open)
                .help("Open this email in Mail")
                .accessibilityLabel("Open Email in Mail")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var notesLabel: String {
        switch notesState {
        case .idle, .failed: return "Save to Notes"
        case .saving: return "Saving to Notes"
        case .saved: return "Saved to Notes"
        }
    }
}

#if DEBUG
#Preview("Worth Knowing cards") {
    struct Demo: View {
        @State var expanded = true
        var body: some View {
            let box = MailboxRef(account: "iCloud", name: "Inbox")
            let coles = "Coles <orders@coles.example>"
            let items = [
                InfoItem(id: "o1", emailID: "o1", category: .personal, importance: 3, summary: "Your Coles order is on its way.",
                         keyFacts: ["Total $17.45"], pinned: false),
                InfoItem(id: "o2", emailID: "o2", category: .personal, importance: 2, summary: "Your second Coles order was delivered.",
                         keyFacts: ["Total $33.90"], pinned: true),
            ]
            let emails = [
                "o1": EmailContext(sender: coles, subject: "Order", mailbox: box, receivedAt: .now.addingTimeInterval(-86_400)),
                "o2": EmailContext(sender: coles, subject: "Order", mailbox: box, receivedAt: .now.addingTimeInterval(-90_000)),
                "x": EmailContext(sender: "QUT <canvas@qut.example>", subject: "A2", mailbox: box, receivedAt: .now.addingTimeInterval(-7_200)),
            ]
            let context = InfoContext(email: { emails[$0] }, provider: { _ in nil }, notesState: { _ in .idle },
                                      userNames: [], onOpen: { _ in }, onTogglePin: { _ in }, onSaveToNotes: { _ in })
            let group = InfoClustering.clusters(items, emails: emails) { _ in DigestDay(year: 2026, month: 11, day: 9) }[0]
            let single = InfoCluster(id: "x", items: [InfoItem(id: "x", emailID: "x", category: .uni, importance: 3,
                                     summary: "Assessment 2 for INN700 is open for submission.", keyFacts: ["Due Mon 9 Nov, 5pm"], pinned: false)],
                                     senderName: "QUT", total: nil, noun: "emails")
            VStack(spacing: 12) {
                InfoClusterCard(cluster: group, context: context, isExpanded: $expanded)
                InfoClusterCard(cluster: single, context: context, isExpanded: .constant(false))
                InfoClusterCard(cluster: single, layout: .slim, context: context, isExpanded: .constant(false))
            }
            .padding().frame(width: 420)
        }
    }
    return Demo()
}
#endif
