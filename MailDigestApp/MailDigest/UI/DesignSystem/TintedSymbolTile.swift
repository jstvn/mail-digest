import SwiftUI

/// A 46 pt rounded square with a light tint and an outlined symbol, used in Mail Access headers.
struct TintedSymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.tintedFill(scheme, light: 0.08))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .overlay(Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(tint))
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
    }
}

#Preview("Tinted tiles") {
    HStack {
        TintedSymbolTile(symbol: "envelope")
        TintedSymbolTile(symbol: "lock", tint: .orange)
    }
    .padding()
}
