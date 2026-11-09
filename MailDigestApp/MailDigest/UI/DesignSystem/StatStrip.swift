import SwiftUI

/// A card of equal stat tiles (number over caption) separated by dividers.
struct StatStrip: View {
    struct Stat: Identifiable {
        let value: String
        let caption: String
        /// Shows the number in the accent colour (the one that needs a decision).
        var isAccent = false
        /// When set, the tile is a button (for example, scroll to its section).
        var action: (() -> Void)?
        var id: String { caption }
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { Divider().padding(.vertical, 12) }
                tile(stat)
            }
        }
        .cardSurface()
    }

    @ViewBuilder private func tile(_ stat: Stat) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(stat.value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(stat.isAccent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            Text(stat.caption).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        if let action = stat.action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help("Go to \(stat.caption)")
                .accessibilityElement(children: .combine)
                .accessibilityHint("Scrolls to this section")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

#Preview("Stat strip") {
    StatStrip(stats: [.init(value: "23", caption: "Emails"), .init(value: "3", caption: "To Review"),
                      .init(value: "5", caption: "Worth Knowing"), .init(value: "12", caption: "Skipped")])
        .padding()
        .frame(width: 600)
}
