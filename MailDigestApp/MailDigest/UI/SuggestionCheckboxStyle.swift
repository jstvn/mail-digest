import SwiftUI

/// A round check mark toggle for suggestion cards: a filled accent circle when selected, an empty ring when not.
/// It is still a `Toggle` (keyboard, VoiceOver and `disabled` all work); only the look is custom.
struct SuggestionCheckboxStyle: ToggleStyle {
    /// Width of the control. The card lays the control out in a column of this width.
    static let width: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        CheckboxButton(configuration: configuration)
    }

    /// A view of its own so it can read the environment (enabled state, Reduce Motion).
    private struct CheckboxButton: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .scaleEffect(configuration.isOn ? 1 : 0.92)
                    .frame(width: SuggestionCheckboxStyle.width, height: SuggestionCheckboxStyle.width)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.35), value: configuration.isOn)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

#Preview("Suggestion checkbox") {
    VStack(alignment: .leading) {
        Toggle(isOn: .constant(true)) { EmptyView() }
        Toggle(isOn: .constant(false)) { EmptyView() }
        Toggle(isOn: .constant(true)) { EmptyView() }.disabled(true)
    }
    .toggleStyle(SuggestionCheckboxStyle())
    .labelsHidden()
    .padding()
}
