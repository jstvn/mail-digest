import Foundation
import MailDigestCore

/// Locale-aware day and month names in the settings time zone, for the sidebar, canvas titles and group headers.
@MainActor
enum ReviewDateText {
    private static var cache: [String: DateFormatter] = [:]

    /// "Thu 5 Nov" (the order and wording follow the user's locale).
    static func day(_ day: DigestDay, calendar: Calendar) -> String {
        format(DateComponents(year: day.year, month: day.month, day: day.day), template: "EEEdMMM", calendar: calendar)
    }

    /// "November 2026".
    static func month(_ month: DigestMonth, calendar: Calendar) -> String {
        format(DateComponents(year: month.year, month: month.month, day: 1), template: "MMMMy", calendar: calendar)
    }

    private static func format(_ components: DateComponents, template: String, calendar: Calendar) -> String {
        guard let date = calendar.date(from: components) else { return "" }
        let key = "\(calendar.timeZone.identifier)|\(Locale.current.identifier)|\(template)"
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = .current
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            cache[key] = formatter
        }
        return formatter.string(from: date)
    }
}

extension SuggestionRecord {
    /// Pending or failed: the user can still act on it.
    var isActionable: Bool { suggestion.status == .pending || suggestion.status == .failed }
}
