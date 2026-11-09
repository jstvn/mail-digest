import SwiftUI

/// A 20 pt gradient square with a white SF Symbol, the sidebar icon style. These gradients are the app's only
/// decorative colour and stay the same in light and dark.
struct SidebarTile: View {
    let symbol: String
    let gradient: [Color]

    /// The five navigation gradients (DESIGN_SPEC 3.1).
    enum Style {
        case today, reviewQueue, logbook, mailCleanup, activity

        var symbol: String {
            switch self {
            case .today: "sun.max.fill"
            case .reviewQueue: "tray.fill"
            case .logbook: "checkmark"
            case .mailCleanup: "archivebox.fill"
            case .activity: "waveform.path.ecg"
            }
        }

        var gradient: [Color] {
            switch self {
            case .today: [Color(hex: 0xFFBE4D), Color(hex: 0xFF8A00)]
            case .reviewQueue: [Color(hex: 0x52A8FF), Color(hex: 0x0A6CF0)]
            case .logbook: [Color(hex: 0x4FD86A), Color(hex: 0x25AE48)]
            case .mailCleanup: [Color(hex: 0x8682FF), Color(hex: 0x5856D6)]
            case .activity: [Color(hex: 0xA9A9B2), Color(hex: 0x7A7A84)]
            }
        }
    }

    init(symbol: String, gradient: [Color]) {
        self.symbol = symbol
        self.gradient = gradient
    }

    init(_ style: Style) {
        self.init(symbol: style.symbol, gradient: style.gradient)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

#Preview("Sidebar tiles") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach([SidebarTile.Style.today, .reviewQueue, .logbook, .mailCleanup, .activity], id: \.symbol) { style in
            Label { Text(style.symbol) } icon: { SidebarTile(style) }
        }
    }
    .padding()
}
