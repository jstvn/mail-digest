import SwiftUI

/// Priority marks. Only High uses colour, and every level is also spelt out for VoiceOver.
struct PriorityBadge: View {
    enum Level { case high, medium, low

        var marks: String {
            switch self { case .high: "!!!"; case .medium: "!!"; case .low: "!" }
        }
        var spoken: String {
            switch self { case .high: "High priority"; case .medium: "Medium priority"; case .low: "Low priority" }
        }
    }

    let level: Level
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if level == .high {
                Text("High")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color.red.tintedFill(scheme), in: Capsule())
            } else {
                Text(level.marks)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.spoken)
    }
}

/// A neutral capsule for a category tag such as "#events".
struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.quaternary, in: Capsule())
    }
}

/// The orange "Review" pill for a suggestion that needs a second look.
struct ReviewPill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label("Review", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.orange.tintedFill(scheme), in: Capsule())
            .accessibilityLabel("Needs review")
    }
}

#Preview("Pills") {
    HStack {
        PriorityBadge(level: .high)
        PriorityBadge(level: .medium)
        PriorityBadge(level: .low)
        TagPill(text: "#events")
        ReviewPill()
    }
    .padding()
}
