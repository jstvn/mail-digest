import SwiftUI

/// Priority marks. Only High uses colour, and every level is also spelt out for VoiceOver.
/// `.pill` (the default) shows High as a red "High" capsule, for cards. `.marks` shows "!!!", "!!" and "!" for
/// list rows, with High in red.
struct PriorityBadge: View {
    enum Style { case pill, marks }

    enum Level { case high, medium, low

        var marks: String {
            switch self { case .high: "!!!"; case .medium: "!!"; case .low: "!" }
        }
        var spoken: String {
            switch self { case .high: "High priority"; case .medium: "Medium priority"; case .low: "Low priority" }
        }
    }

    let level: Level
    var style: Style = .pill
    @Environment(\.colorScheme) private var scheme
    /// On a selected list row the accent fill makes red unreadable, so the marks follow the row's text colour.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if style == .marks {
                Text(level.marks)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(level == .high && prominence != .increased ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            } else if level == .high {
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
        PriorityBadge(level: .high, style: .marks)
        PriorityBadge(level: .medium, style: .marks)
        PriorityBadge(level: .low, style: .marks)
        TagPill(text: "#events")
        ReviewPill()
    }
    .padding()
}
