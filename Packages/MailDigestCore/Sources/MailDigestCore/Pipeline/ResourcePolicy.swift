import Foundation

/// Mirror of `ProcessInfo.ThermalState`, so the policy stays Foundation-only and testable on Linux.
public enum ThermalLevel: Int, Codable, Sendable, Equatable, Comparable {
    case nominal, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What the Mac is doing right now, as reported by the app's resource monitor.
public struct ResourceConditions: Sendable, Equatable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }
}

/// An allowed daily window ("only run 10pm to 7am"), as minutes after midnight in the app's time zone.
/// It may cross midnight (start later than end). Equal start and end means no restriction.
public struct QuietHours: Codable, Sendable, Equatable {
    /// When running becomes allowed.
    public var startMinute: Int
    /// When running stops being allowed.
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = min(max(startMinute, 0), 1439)
        self.endMinute = min(max(endMinute, 0), 1439)
    }

    /// True when jobs may run at `date`.
    public func allowsRunning(at date: Date, in timeZone: TimeZone) -> Bool {
        guard startMinute != endMinute else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute // crosses midnight
    }

    /// The next moment the answer can change, for scheduling a re-check.
    public func nextBoundary(after date: Date, in timeZone: TimeZone) -> Date? {
        guard startMinute != endMinute else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let candidates = [startMinute, endMinute].compactMap { minute in
            calendar.nextDate(after: date, matching: DateComponents(hour: minute / 60, minute: minute % 60),
                              matchingPolicy: .nextTime)
        }
        return candidates.min()
    }
}

/// The spec's power and resource rules as one pure decision. Backlog jobs honour every rule; the Daily
/// job only honours Low Power Mode, since it is small.
public struct ResourcePolicy: Sendable, Equatable {
    public var pauseBacklogOnBattery: Bool
    /// Nil means no quiet hours.
    public var quietHours: QuietHours?
    public var timeZone: TimeZone
    /// The Background Work window (its times are kept even while "Only run during this time window" is off).
    /// Jobs created as "Overnight While Plugged In" use it regardless of that toggle.
    public var overnightWindow: QuietHours

    public init(pauseBacklogOnBattery: Bool = true, quietHours: QuietHours? = nil,
                timeZone: TimeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current,
                overnightWindow: QuietHours? = nil) {
        self.pauseBacklogOnBattery = pauseBacklogOnBattery
        self.quietHours = quietHours
        self.timeZone = timeZone
        self.overnightWindow = overnightWindow ?? quietHours ?? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    }

    /// The extra block for a job created as overnight-only, on top of `blockingReason`: it never runs on
    /// battery (even when "Pause on Battery" is off) and only inside the overnight window. Low Power Mode and
    /// heat come from `blockingReason`, which the caller checks first.
    public func overnightBlockingReason(conditions: ResourceConditions, now: Date) -> PauseReason? {
        if conditions.onBattery { return .battery }
        if !overnightWindow.allowsRunning(at: now, in: timeZone) { return .quietHours }
        return nil
    }

    /// Why a job of this kind must not run now, or nil when it may. When several rules apply, the most
    /// fundamental wins: Low Power Mode, heat, battery, then quiet hours.
    public func blockingReason(for kind: JobKind, conditions: ResourceConditions, now: Date) -> PauseReason? {
        if conditions.lowPowerMode { return .lowPowerMode }
        guard kind == .backlog else { return nil }
        if conditions.thermal >= .serious { return .heat }
        if pauseBacklogOnBattery && conditions.onBattery { return .battery }
        if let quietHours, !quietHours.allowsRunning(at: now, in: timeZone) { return .quietHours }
        return nil
    }

    /// The block for each job kind that has one.
    public func blocked(conditions: ResourceConditions, now: Date) -> [JobKind: PauseReason] {
        var out: [JobKind: PauseReason] = [:]
        for kind in [JobKind.daily, .backlog] {
            if let reason = blockingReason(for: kind, conditions: conditions, now: now) { out[kind] = reason }
        }
        return out
    }
}
