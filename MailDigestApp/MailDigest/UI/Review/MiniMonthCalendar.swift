import MailDigestCore
import SwiftUI

/// The sidebar's month calendar (replaces the Recent Digests list). Weeks start on Monday. A 4 pt dot marks
/// a day with a digest and a click opens it; today is the orange circle and opens Today. The chevrons reach
/// every month that still has a retained digest.
struct MiniMonthCalendar: View {
    let archive: DigestArchive
    let calendar: Calendar
    /// The day (or Today) currently selected in the sidebar, to draw its selection.
    let selection: SidebarItem?
    let onSelect: (SidebarItem) -> Void

    /// Nil follows today's month, so a new day or month rolls the calendar over on its own.
    @State private var shownMonth: DigestMonth?

    private var currentMonth: DigestMonth { DigestMonth(archive.todayDay) }
    private var month: DigestMonth {
        let range = archive.calendarMonthRange
        return min(max(shownMonth ?? currentMonth, range.lowerBound), range.upperBound)
    }

    private var symbolCalendar: Calendar {
        var c = calendar
        c.locale = .current
        return c
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(MonthGrid.weeks(for: month, calendar: calendar).enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week, id: \.day) { cell in dayButton(cell) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(ReviewDateText.month(month, calendar: calendar))
                .font(.callout.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(month <= archive.calendarMonthRange.lowerBound)
                .help("Previous Month")
                .accessibilityLabel("Previous Month")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(month >= archive.calendarMonthRange.upperBound)
                .help("Next Month")
                .accessibilityLabel("Next Month")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
    }

    private func step(_ offset: Int) {
        shownMonth = MonthGrid.month(month, adding: offset)
    }

    private var weekdayRow: some View {
        // Monday first: the symbol list starts on Sunday.
        let symbols = symbolCalendar.veryShortStandaloneWeekdaySymbols
        let ordered = symbols.count == 7 ? Array(symbols[1...]) + [symbols[0]] : ["M", "T", "W", "T", "F", "S", "S"]
        return Grid(horizontalSpacing: 0) {
            GridRow {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func dayButton(_ cell: MonthGridCell) -> some View {
        let isToday = cell.day == archive.todayDay
        let entry = archive.calendarEntry(for: cell.day)
        let target: SidebarItem = isToday ? .today : .day(cell.day)
        let isSelected = selection == target && (isToday || entry != nil)
        return Button {
            onSelect(target)
        } label: {
            VStack(spacing: 1) {
                Text("\(cell.day.day)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                     : cell.isInMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22)
                    .background {
                        if isToday {
                            Circle().fill(Color.orange)
                        } else if isSelected {
                            Circle().fill(Color.accentColor.opacity(0.22))
                        }
                    }
                Circle()
                    .fill(isToday ? AnyShapeStyle(Color.orange) : cell.isInMonth ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 4, height: 4)
                    .opacity(entry == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(DayButtonStyle())
        // Only today and days with a digest lead anywhere.
        .disabled(!isToday && entry == nil)
        .accessibilityLabel(MonthGrid.accessibilityLabel(for: cell.day, entry: entry, isToday: isToday,
                                                         calendar: calendar))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Plain look that does not dim when disabled: a day without a digest keeps its normal text colour.
private struct DayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

#Preview("Mini month calendar") {
    let library = PreviewSupport.library()
    MiniMonthCalendar(archive: library.archive, calendar: library.calendar,
        selection: .day(PreviewSupport.yesterday), onSelect: { _ in })
        .padding()
        .frame(width: 240)
}
