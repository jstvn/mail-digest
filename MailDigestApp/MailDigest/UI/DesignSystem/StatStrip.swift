import SwiftUI

/// A card of equal stat tiles (number over caption) separated by dividers.
struct StatStrip: View {
    struct Stat: Identifiable {
        let value: String
        let caption: String
        var id: String { caption }
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { Divider().padding(.vertical, 12) }
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(.system(size: 24, weight: .semibold))
                        .monospacedDigit()
                    Text(stat.caption).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

#Preview("Stat strip") {
    StatStrip(stats: [.init(value: "23", caption: "Emails"), .init(value: "3", caption: "To Review"),
                      .init(value: "5", caption: "Worth Knowing"), .init(value: "12", caption: "Skipped")])
        .padding()
        .frame(width: 600)
}
