import Foundation

/// The EventKit-independent fields of one reminder. The app adapter copies them into an `EKReminder`,
/// so the date, alarm, priority and notes rules are testable without EventKit.
public struct ReminderDraft: Sendable, Equatable {
    public static let defaultTimeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current

    public var title: String
    /// Year, month and day, plus hour and minute for a timed due date. Always set since Q101.
    public var dueComponents: DateComponents?
    /// Absolute alarm time: at the plan time when written there (Q101); otherwise 9:00 local on the due day for
    /// date-only, one hour before for timed.
    public var alarmDate: Date?
    /// EventKit priority: 1 high, 5 medium, 9 low.
    public var priority: Int
    public var notes: String
    public var url: URL

    /// - Parameters:
    ///   - policy: the Q101 date mode and plan time.
    ///   - now: the moment of writing (from the injected clock); it picks today's or tomorrow's plan time.
    public init(_ suggestion: Suggestion, category: Category, email: EmailContext?,
                policy: ReminderDatePolicy = ReminderDatePolicy(), now: Date,
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

        // The plan time on the day of writing, or the next day once it has passed.
        var todayParts = calendar.dateComponents([.year, .month, .day], from: now)
        todayParts.hour = policy.planHour
        todayParts.minute = policy.planMinute
        var target = calendar.date(from: todayParts) ?? now
        if now >= target { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }

        func timedComponents(_ date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
        func writeAsDeadline(_ due: Date) {
            if suggestion.dueHasTime {
                dueComponents = timedComponents(due)
                alarmDate = due.addingTimeInterval(-3600)
            } else {
                let day = calendar.dateComponents([.year, .month, .day], from: due)
                dueComponents = day
                var nineAM = day
                nineAM.hour = 9
                alarmDate = calendar.date(from: nineAM)
            }
        }
        func writeAtTarget() {
            dueComponents = timedComponents(target)
            alarmDate = target
        }

        guard let due = suggestion.due else {
            // No reminder is written without a date.
            writeAtTarget()
            return
        }
        guard policy.mode == .planToday else {
            writeAsDeadline(due)
            return
        }
        // A date-only deadline counts as the end of that day.
        let deadline: Date
        if suggestion.dueHasTime {
            deadline = due
        } else {
            let startOfDay = calendar.startOfDay(for: due)
            deadline = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? due
        }
        if deadline < target {
            writeAsDeadline(due)
            return
        }
        writeAtTarget()
        let sameDeadline = suggestion.dueHasTime ? due == target : calendar.isDate(due, inSameDayAs: target)
        if !sameDeadline { title += Self.deadlineSuffix(due, hasTime: suggestion.dueHasTime, timeZone: timeZone) }
    }

    /// ` (due Mon 1 Dec)` or ` (due Mon 1 Dec, 3:00 pm)`: English and fixed, in the given zone.
    static func deadlineSuffix(_ due: Date, hasTime: Bool, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        f.dateFormat = hasTime ? "EEE d MMM, h:mm a" : "EEE d MMM"
        return " (due \(f.string(from: due)))"
    }
}
