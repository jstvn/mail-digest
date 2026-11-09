import SwiftUI

/// Wizard progress: numbered circles joined by short lines. Completed steps show a tick.
struct StepIndicator: View {
    let steps: [String]
    /// Zero-based index of the current step.
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                if i > 0 {
                    Rectangle()
                        .fill(i <= current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator))
                        .frame(width: 44, height: 2)
                }
                HStack(spacing: 6) {
                    circle(i)
                    Text(steps[i])
                        .font(.callout.weight(i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(i + 1) of \(steps.count), \(steps[i])")
                .accessibilityValue(i < current ? "Done" : (i == current ? "Current" : ""))
            }
        }
    }

    private func circle(_ i: Int) -> some View {
        ZStack {
            Circle().fill(i <= current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            if i < current {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(i + 1)").font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(i == current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: 20, height: 20)
    }
}

#Preview("Step indicator") {
    StepIndicator(steps: ["Mailboxes", "Date Range", "Ready to Start"], current: 1).padding()
}
