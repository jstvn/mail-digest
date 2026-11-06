import AppKit
import SwiftUI

/// A menu-item look for rows in the window-style `MenuBarExtra`: a rounded selection
/// background with white text while the pointer is over an enabled row, as in a native menu.
/// Window-style menu bar panels get no native item highlight, so the row draws its own.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    // `ButtonStyle` can't hold state, so a view owns the hover flag.
    private struct MenuRow: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var isHighlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

        // A custom style doesn't dim disabled labels for us, so match a disabled menu item.
        private var foreground: Color {
            if isHighlighted { return Color(nsColor: .selectedMenuItemTextColor) }
            return isEnabled ? .primary : Color(nsColor: .disabledControlTextColor)
        }

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(foreground)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .selectedContentBackgroundColor))
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
