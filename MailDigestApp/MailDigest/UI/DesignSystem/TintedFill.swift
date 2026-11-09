import SwiftUI

extension Color {
    /// A tinted fill that is a light pastel in light mode and a stronger 0.18 opacity in dark mode (DESIGN_SPEC 12).
    func tintedFill(_ scheme: ColorScheme, light: Double = 0.12) -> Color {
        opacity(scheme == .dark ? 0.18 : light)
    }

    /// Builds a colour from a 0xRRGGBB value. Only for the sidebar tile and avatar gradients.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
