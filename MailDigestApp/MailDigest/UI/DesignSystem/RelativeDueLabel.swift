import SwiftUI
import MailDigestCore

/// A due date as relative text over the exact date (DESIGN_SPEC 4.1), or just the relative line.
struct RelativeDueLabel: View {
    enum Layout { case twoLine, singleLine }

    let due: Date?
    var hasTime = false
    var layout: Layout = .twoLine
    /// The Q38 calendar, so the label agrees with the rest of the app's day arithmetic.
    let calendar: Calendar
    var now: Date = .now

    var body: some View {
        let relative = RelativeDue.make(due: due, hasTime: hasTime, now: now, calendar: calendar)
        switch layout {
        case .singleLine:
            Text(relative.top)
                .foregroundStyle(relative.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        case .twoLine:
            VStack(alignment: .trailing, spacing: 1) {
                Text(relative.top)
                    .fontWeight(.semibold)
                    .foregroundStyle(topStyle(relative))
                if let bottom = relative.bottom {
                    Text(bottom).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
            .accessibilityElement(children: .combine)
        }
    }

    private func topStyle(_ r: RelativeDue) -> AnyShapeStyle {
        if r.isOverdue { return AnyShapeStyle(.red) }
        return due == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
}

#Preview("Relative due") {
    let cal = Calendar(identifier: .gregorian)
    VStack(alignment: .trailing, spacing: 12) {
        RelativeDueLabel(due: .now.addingTimeInterval(11 * 86_400), hasTime: true, calendar: cal)
        RelativeDueLabel(due: .now.addingTimeInterval(-3 * 86_400), calendar: cal)
        RelativeDueLabel(due: nil, calendar: cal)
        RelativeDueLabel(due: .now.addingTimeInterval(86_400), layout: .singleLine, calendar: cal)
    }
    .padding()
}
