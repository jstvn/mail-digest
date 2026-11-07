import Foundation

/// `CredentialStore` fake that keeps the key in memory.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) { self.key = key }

    public func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return key }
    public func save(_ key: String) throws { lock.lock(); defer { lock.unlock() }; self.key = key }
    public func delete() throws { lock.lock(); defer { lock.unlock() }; key = nil }
}
