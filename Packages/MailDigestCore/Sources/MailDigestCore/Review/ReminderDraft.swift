import Foundation

/// The EventKit-independent fields of one reminder. The app adapter copies them into an `EKReminder`,
/// so the date, alarm, priority and notes rules are testable without EventKit.
public struct ReminderDraft: Sendable, Equatable {
    public static let defaultTimeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current

    public var title: String
    /// Year, month and day, plus hour and minute only for a timed due date; nil when there is no due date.
    public var dueComponents: DateComponents?
    /// Absolute alarm time: 9:00 local on the due day for date-only, one hour before for timed, nil without a due date.
    public var alarmDate: Date?
    /// EventKit priority: 1 high, 5 medium, 9 low.
    public var priority: Int
    public var notes: String
    public var url: URL

    public init(_ suggestion: Suggestion, category: Category, email: EmailContext?,
                timeZone: TimeZone = ReminderDraft.defaultTimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        title = suggestion.title
        notes = ReviewActions.reminderNotes(for: suggestion, email: email, category: category)
        url = ReviewActions.messageURL(for: suggestion.emailID)
        switch suggestion.priority {
        case .high: priority = 1
        case .medium: priority = 5
        case .low: priority = 9
        }

        guard let due = suggestion.due else {
            dueComponents = nil
            alarmDate = nil
            return
        }
        if suggestion.dueHasTime {
            dueComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            alarmDate = due.addingTimeInterval(-3600)
        } else {
            let day = calendar.dateComponents([.year, .month, .day], from: due)
            dueComponents = day
            var nineAM = day
            nineAM.hour = 9
            alarmDate = calendar.date(from: nineAM)
        }
    }
}
