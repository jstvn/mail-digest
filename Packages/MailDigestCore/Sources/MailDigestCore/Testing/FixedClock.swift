import Foundation

/// A clock whose time only changes when a test says so.
public final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    public init(_ date: Date) { self.date = date }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    public func set(_ newDate: Date) {
        lock.lock(); defer { lock.unlock() }
        date = newDate
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}
