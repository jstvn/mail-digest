import AppKit
import SwiftUI

extension Color {
    /// The canvas behind the cards (asset catalog: #F7F7FA light, #1C1C1E dark).
    static let pageBackground = Color("PageBackground")
    /// The card surface above `pageBackground` (asset catalog: #FFFFFF light, #2C2C2E dark).
    static let cardBackground = Color("CardBackground")
}

extension View {
    /// The shared card look: a rounded `cardBackground` surface with a hairline border and, in light mode only,
    /// a faint shadow. `isFocused` swaps the hairline for a 2 pt accent ring (keyboard focus).
    func cardSurface(cornerRadius: CGFloat = 14, isFocused: Bool = false) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(Color.cardBackground)
                    .shadow(color: .black.opacity(colorScheme == .light ? 0.04 : 0), radius: 1, y: 1)
            }
            .overlay {
                if isFocused {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                } else {
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
    }
}
