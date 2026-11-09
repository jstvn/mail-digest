import SwiftUI

/// The floating capsule over a list of suggestions: a count, "Dismiss Unselected" and "Add to Reminders".
/// It is pure presentation; the caller supplies the actions and the enabled state.
struct TriageBar: View {
    let selectedCount: Int
    /// When set, the label reads "3 selected of 25 shown" (the view hides suggestions the actions skip).
    var shownOf: Int?
    /// Defaults to whether anything is selected; callers with extra rules (Reminders access, busy) override.
    var canAdd: Bool?
    var canDismiss = true
    var dismissHelp = "Dismiss the suggestions shown that aren't ticked"
    var addHelp = "Add the ticked suggestions to Reminders"
    let dismissUnselected: () -> Void
    let addSelected: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            Button("Dismiss Unselected", action: dismissUnselected)
                .buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.capsule)
                .disabled(!canDismiss)
                .help(dismissHelp)
            Button(action: addSelected) {
                HStack(spacing: 6) {
                    Text("Add to Reminders")
                    Text("⌘↩").foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!(canAdd ?? (selectedCount > 0)))
            .help(addHelp)
        }
        .padding(6)
        .modifier(GlassCapsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Triage")
    }

    private var label: String {
        if let shownOf { return "\(selectedCount) selected of \(shownOf) shown" }
        return "\(selectedCount) selected"
    }
}

/// A capsule background: Liquid Glass on macOS 26, a material with a hairline border on macOS 15 and when
/// Reduce Transparency is on (solid then).
struct GlassCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
        }
    }
}

#Preview("Triage bar") {
    VStack(spacing: 20) {
        TriageBar(selectedCount: 3, shownOf: 25, dismissUnselected: {}, addSelected: {})
        TriageBar(selectedCount: 0, dismissUnselected: {}, addSelected: {})
    }
    .padding(40)
}
