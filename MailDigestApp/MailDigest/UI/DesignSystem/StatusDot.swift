import SwiftUI

/// An 8 pt dot with a word beside it. Colour alone never carries the status, so the text is required.
struct StatusDot: View {
    let text: String
    var color: Color = .green

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Status dots") {
    VStack(alignment: .leading) {
        StatusDot(text: "Running")
        StatusDot(text: "Off", color: .gray)
        StatusDot(text: "Needs Access", color: .orange)
    }
    .padding()
}
