import Foundation

public protocol Notifier: Sendable {
    /// Shows a user notification; never fails the caller.
    func post(_ message: String) async
}
