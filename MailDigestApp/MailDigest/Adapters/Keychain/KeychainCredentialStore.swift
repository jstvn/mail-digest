import Foundation
import MailDigestCore
import Security

/// Stores the Gemini API key as a generic password in the login keychain. Device-local (no iCloud Keychain
/// sync, no shared access group) and available after the first unlock so scheduled runs can read it.
/// The key is never logged or placed in an error.
struct KeychainCredentialStore: CredentialStore {
    enum StoreError: Error, Equatable, LocalizedError {
        case emptyKey
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey: "The API key is empty."
            case .keychain(let status): "The Keychain returned error \(status)."
            }
        }
    }

    static let service = "dev.pages.justinwang.maildigest.gemini"
    static let account = "api-key"

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        return key.isEmpty ? nil : key
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyKey }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError.keychain(update) }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
