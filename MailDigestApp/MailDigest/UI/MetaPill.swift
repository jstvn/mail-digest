import MailDigestCore
import SwiftUI

/// The look of a metadata pill: small caption text, an optional SF Symbol and a soft tinted capsule.
/// Used on its own for static pills and as the label of `MetaPill` buttons and menus.
struct MetaPillLabel: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    /// A dashed, muted outline instead of a filled capsule (the "Add Date" affordance).
    var isGhost = false
    /// Hover highlight is shown only for interactive pills.
    var isInteractive = false

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(isGhost ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            if isGhost {
                Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .opacity(hovering ? 1 : 0.8)
            } else {
                Capsule().fill(Color.primary.opacity(hovering && isInteractive ? 0.10 : 0.05))
            }
        }
        .contentShape(Capsule())
        .onHover { if isInteractive { hovering = $0 } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// A borderless pill button.
struct MetaPill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var isGhost = false
    let help: String
    let accessibilityTitle: String
    var accessibilityValue: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MetaPillLabel(text: text, symbol: symbol, tint: tint, isGhost: isGhost, isInteractive: true)
        }
        .buttonStyle(.plain)
        .help(help)
        .metaPillAccessibility(title: accessibilityTitle, value: accessibilityValue)
    }
}

extension View {
    /// "Priority, High": the title as label and the current value as value.
    func metaPillAccessibility(title: String, value: String) -> some View {
        accessibilityLabel(title).accessibilityValue(value)
    }
}

/// Date text shared by the pills: "Fri 6 Nov" or "Fri 6 Nov, 17:00", in the settings time zone.
enum PillDateText {
    static func string(_ date: Date, hasTime: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(hasTime ? "EEEdMMMjmm" : "EEEdMMM")
        return formatter.string(from: date)
    }
}

extension Priority {
    /// Text and icon tint: red for High, neutral secondary for Medium and Low.
    var pillTint: Color {
        switch self {
        case .high: return .red
        case .medium, .low: return .secondary
        }
    }
}

/// Read-only pills (date, priority, category) for settled and non-editable suggestions.
struct StaticSuggestionPills: View {
    let suggestion: Suggestion
    let category: Category
    var timeZone: TimeZone = RunnerSettings().timeZone

    var body: some View {
        HStack(spacing: 6) {
            if let due = suggestion.due {
                let text = PillDateText.string(due, hasTime: suggestion.dueHasTime, timeZone: timeZone)
                MetaPillLabel(text: text, symbol: "calendar")
                    .metaPillAccessibility(title: "Due date", value: text)
            }
            MetaPillLabel(text: suggestion.priority.label, tint: suggestion.priority.pillTint)
                .metaPillAccessibility(title: "Priority", value: suggestion.priority.label)
            MetaPillLabel(text: "#\(category.rawValue)", tint: .secondary)
                .metaPillAccessibility(title: "Category", value: category.rawValue)
        }
    }
}

/// The evidence quote: an accent bar, "From: sender" then the quote, and the open-in-Mail button on the right.
struct EvidenceQuote: View {
    let sender: String
    let evidence: String
    /// Full opacity for the open button (hover or focus); it stays reachable either way.
    var emphasised = false
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 2.5)
                .accessibilityHidden(true)
            (Text("From: \(sender)  ").font(.callout.weight(.medium)).foregroundStyle(.primary)
                + Text("“\(evidence)”").font(.callout).italic().foregroundStyle(.secondary))
                .lineLimit(2)
                .truncationMode(.tail)
                .help("“\(evidence)”")
                .accessibilityLabel("Evidence from \(sender): \(evidence)")
            Spacer(minLength: 4)
            Button(action: onOpen) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .opacity(emphasised ? 1 : 0.5)
                .help("Open this email in Mail")
                .accessibilityLabel("Open Email in Mail")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
}
