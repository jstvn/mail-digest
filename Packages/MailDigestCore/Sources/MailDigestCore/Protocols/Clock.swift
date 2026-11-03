import Foundation

/// Injectable time source. Note: inside this module this shadows Swift's stdlib `Clock`, which is intended.
public protocol Clock: Sendable {
    /// The current date and time.
    func now() -> Date
}
