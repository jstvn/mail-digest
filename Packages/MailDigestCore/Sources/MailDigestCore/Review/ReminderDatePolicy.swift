import Foundation

/// Which date a written reminder gets (Q101).
public enum ReminderDateMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Due at the plan time on the day it is written (or the next day once that time has passed), never later
    /// than the real deadline. The deadline stays in the title.
    case planToday
    /// Due on the email's own deadline; undated suggestions fall back to the plan time.
    case emailDeadline
}

/// The user's reminder date settings, passed to the writer with the time of writing.
public struct ReminderDatePolicy: Sendable, Equatable {
    public static let defaultPlanHour = 20
    public static let defaultPlanMinute = 0

    public var mode: ReminderDateMode
    public var planHour: Int
    public var planMinute: Int

    public init(mode: ReminderDateMode = .planToday, planHour: Int = ReminderDatePolicy.defaultPlanHour,
                planMinute: Int = ReminderDatePolicy.defaultPlanMinute) {
        self.mode = mode
        self.planHour = min(max(planHour, 0), 23)
        self.planMinute = min(max(planMinute, 0), 59)
    }
}
