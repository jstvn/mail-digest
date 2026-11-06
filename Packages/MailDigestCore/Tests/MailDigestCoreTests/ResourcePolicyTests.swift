import Foundation
import Testing
@testable import MailDigestCore

private let brisbane = TimeZone(identifier: "Australia/Brisbane")!

/// A moment at `hour:minute` Brisbane time on 6 Nov 2026.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 6) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = brisbane
    return c.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite struct ResourcePolicyTests {
    private let policy = ResourcePolicy(timeZone: brisbane)
    private let noon = at(12)

    @Test func nothingBlocksOnPowerWithNominalConditions() {
        let c = ResourceConditions()
        #expect(policy.blockingReason(for: .backlog, conditions: c, now: noon) == nil)
        #expect(policy.blockingReason(for: .daily, conditions: c, now: noon) == nil)
        #expect(policy.blocked(conditions: c, now: noon).isEmpty)
    }

    @Test func batteryPausesBacklogOnlyAndCanBeTurnedOff() {
        let c = ResourceConditions(onBattery: true)
        #expect(policy.blockingReason(for: .backlog, conditions: c, now: noon) == .battery)
        #expect(policy.blockingReason(for: .daily, conditions: c, now: noon) == nil)
        var off = policy
        off.pauseBacklogOnBattery = false
        #expect(off.blockingReason(for: .backlog, conditions: c, now: noon) == nil)
    }

    @Test func lowPowerModePausesBothKinds() {
        let c = ResourceConditions(lowPowerMode: true)
        #expect(policy.blockingReason(for: .backlog, conditions: c, now: noon) == .lowPowerMode)
        #expect(policy.blockingReason(for: .daily, conditions: c, now: noon) == .lowPowerMode)
        // The toggle for battery never disables Low Power Mode.
        var off = policy
        off.pauseBacklogOnBattery = false
        #expect(off.blockingReason(for: .daily, conditions: c, now: noon) == .lowPowerMode)
    }

    @Test(arguments: [(ThermalLevel.nominal, false), (.fair, false), (.serious, true), (.critical, true)])
    func heatPausesBacklogFromSerious(level: ThermalLevel, blocked: Bool) {
        let c = ResourceConditions(thermal: level)
        #expect(policy.blockingReason(for: .backlog, conditions: c, now: noon) == (blocked ? .heat : nil))
        #expect(policy.blockingReason(for: .daily, conditions: c, now: noon) == nil)
    }

    @Test func precedenceIsLowPowerThenHeatThenBatteryThenQuietHours() {
        var p = policy
        p.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        var c = ResourceConditions(onBattery: true, lowPowerMode: true, thermal: .critical)
        #expect(p.blockingReason(for: .backlog, conditions: c, now: noon) == .lowPowerMode)
        c.lowPowerMode = false
        #expect(p.blockingReason(for: .backlog, conditions: c, now: noon) == .heat)
        c.thermal = .nominal
        #expect(p.blockingReason(for: .backlog, conditions: c, now: noon) == .battery)
        c.onBattery = false
        #expect(p.blockingReason(for: .backlog, conditions: c, now: noon) == .quietHours)
        #expect(p.blockingReason(for: .daily, conditions: c, now: noon) == nil)
        #expect(p.blockingReason(for: .backlog, conditions: c, now: at(23)) == nil)
    }

    @Test func blockedMapListsEachKindSeparately() {
        let m = policy.blocked(conditions: ResourceConditions(onBattery: true, lowPowerMode: false, thermal: .serious),
                               now: noon)
        #expect(m == [.backlog: .heat])
        let lpm = policy.blocked(conditions: ResourceConditions(lowPowerMode: true), now: noon)
        #expect(lpm == [.daily: .lowPowerMode, .backlog: .lowPowerMode])
    }
}

@Suite struct QuietHoursTests {
    @Test func sameDayWindow() {
        let q = QuietHours(startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(!q.allowsRunning(at: at(8, 59), in: brisbane))
        #expect(q.allowsRunning(at: at(9), in: brisbane))
        #expect(q.allowsRunning(at: at(16, 59), in: brisbane))
        #expect(!q.allowsRunning(at: at(17), in: brisbane))
    }

    @Test func windowCrossingMidnight() {
        let q = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(!q.allowsRunning(at: at(21, 59), in: brisbane))
        #expect(q.allowsRunning(at: at(22), in: brisbane))
        #expect(q.allowsRunning(at: at(23, 59), in: brisbane))
        #expect(q.allowsRunning(at: at(0), in: brisbane))
        #expect(q.allowsRunning(at: at(6, 59), in: brisbane))
        #expect(!q.allowsRunning(at: at(7), in: brisbane))
        #expect(!q.allowsRunning(at: at(15), in: brisbane))
    }

    @Test func equalStartAndEndMeansNoRestriction() {
        let q = QuietHours(startMinute: 600, endMinute: 600)
        #expect(q.allowsRunning(at: at(3), in: brisbane) && q.allowsRunning(at: at(15), in: brisbane))
        #expect(q.nextBoundary(after: at(3), in: brisbane) == nil)
    }

    @Test func evaluatedInTheGivenTimeZoneNotTheSystemOne() {
        let q = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        // 23:00 Brisbane is 13:00 UTC; the same instant is outside the window when read as UTC.
        let utc = TimeZone(identifier: "UTC")!
        #expect(q.allowsRunning(at: at(23), in: brisbane))
        #expect(!q.allowsRunning(at: at(23), in: utc))
    }

    @Test func nextBoundaryIsTheNearestStartOrEnd() {
        let q = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(q.nextBoundary(after: at(12), in: brisbane) == at(22))
        #expect(q.nextBoundary(after: at(23), in: brisbane) == at(7, day: 7))
        #expect(q.nextBoundary(after: at(3), in: brisbane) == at(7))
    }

    @Test func clampsOutOfRangeMinutes() {
        let q = QuietHours(startMinute: -5, endMinute: 5000)
        #expect(q.startMinute == 0 && q.endMinute == 1439)
    }
}
