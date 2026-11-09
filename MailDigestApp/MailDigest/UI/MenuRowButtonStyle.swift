import AppKit
import SwiftUI

/// A menu-item look for rows in the window-style `MenuBarExtra`: 24 pt tall, a rounded selection
/// background with white text while the pointer is over an enabled row, and an optional trailing
/// shortcut hint, as in a native menu. Window-style panels get no native item highlight, so the row draws its own.
struct MenuRowButtonStyle: ButtonStyle {
    /// The key combination shown at the trailing edge, such as "⌘N". Decorative: the real shortcut comes from
    /// `.keyboardShortcut` on the button.
    var hint: String?

    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration, hint: hint)
    }

    // `ButtonStyle` can't hold state, so a view owns the hover flag.
    private struct MenuRow: View {
        let configuration: Configuration
        let hint: String?
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

        // A custom style doesn't dim disabled labels for us, so match a disabled menu item.
        private var foreground: Color {
            if isHighlighted { return Color(nsColor: .selectedMenuItemTextColor) }
            return isEnabled ? .primary : Color(nsColor: .disabledControlTextColor)
        }

        private var hintColor: Color {
            if isHighlighted { return Color(nsColor: .selectedMenuItemTextColor).opacity(0.85) }
            return isEnabled ? Color.secondary : Color(nsColor: .disabledControlTextColor)
        }

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .foregroundStyle(hintColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 10)
            .foregroundStyle(foreground)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }
}
