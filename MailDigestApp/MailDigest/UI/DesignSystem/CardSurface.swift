import AppKit
import SwiftUI

extension View {
    /// The shared card look: a 14 pt rounded surface on the window background with a hairline border.
    /// `isFocused` swaps the hairline for a 2 pt accent ring (keyboard focus).
    func cardSurface(cornerRadius: CGFloat = 14, isFocused: Bool = false) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                }
            }
    }
}
