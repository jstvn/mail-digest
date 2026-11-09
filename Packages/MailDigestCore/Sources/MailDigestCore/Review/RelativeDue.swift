import Foundation

/// The two-line relative due date used wherever a due date appears (DESIGN_SPEC 4.1): a relative top line
/// ("In 11 days") and an exact bottom line ("Fri 20 Nov · 5:30 pm").
public struct RelativeDue: Sendable, Equatable {
    /// "In 11 days", "Tomorrow", "3 days overdue", "No date". Single-line callers use only this.
    public let top: String
    /// The exact date, or nil when there is nothing to add ("No date", or "Today" without a time).
    public let bottom: String?
    public let isOverdue: Bool

    public init(top: String, bottom: String?, isOverdue: Bool) {
        self.top = top
        self.bottom = bottom
        self.isOverdue = isOverdue
    }

    /// Builds the label. `calendar` (and its time zone) drives both the day arithmetic and the formatting,
    /// so the two always agree.
    public static func make(due: Date?, hasTime: Bool, now: Date, calendar: Calendar,
                            locale: Locale = Locale(identifier: "en_AU")) -> RelativeDue {
        guard let due else { return RelativeDue(top: "No date", bottom: nil, isOverdue: false) }
        let startToday = calendar.startOfDay(for: now)
        let startDue = calendar.startOfDay(for: due)
        let days = calendar.dateComponents([.day], from: startToday, to: startDue).day ?? 0

        var dateStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(due, equalTo: now, toGranularity: .year) { dateStyle = dateStyle.year() }
        let timeStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute()
        // ICU may use a narrow no-break space before am/pm, and the weekday may carry a comma.
        func normalised(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let time = normalised(due.formatted(timeStyle)).lowercased()
        var bottom = normalised(due.formatted(dateStyle)).replacingOccurrences(of: ",", with: "")
        if hasTime { bottom += " · " + time }

        switch days {
        case ..<0:
            return RelativeDue(top: "\(-days) day\(days == -1 ? "" : "s") overdue", bottom: bottom, isOverdue: true)
        case 0:
            return RelativeDue(top: "Today", bottom: hasTime ? time : nil, isOverdue: false)
        case 1:
            return RelativeDue(top: "Tomorrow", bottom: bottom, isOverdue: false)
        case 2...13:
            return RelativeDue(top: "In \(days) days", bottom: bottom, isOverdue: false)
        default:
            let weeks = days / 7
            if weeks < 9 { return RelativeDue(top: "In \(weeks) weeks", bottom: bottom, isOverdue: false) }
            let months = max(2, calendar.dateComponents([.month], from: startToday, to: startDue).month ?? 2)
            return RelativeDue(top: "In \(months) months", bottom: bottom, isOverdue: false)
        }
    }
}
