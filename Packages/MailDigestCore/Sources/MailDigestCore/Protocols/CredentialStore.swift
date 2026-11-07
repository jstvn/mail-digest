import Foundation

/// Storage for the single cloud API key. Implementations must never log, print or otherwise
/// expose the value (including in error messages).
public protocol CredentialStore: Sendable {
    /// The saved key, or nil when none exists.
    func read() throws -> String?
    func save(_ key: String) throws
    /// Removes the key; succeeds when none exists.
    func delete() throws
}
