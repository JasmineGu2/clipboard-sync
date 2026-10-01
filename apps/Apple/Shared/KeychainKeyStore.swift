import ClipCrypto
import Foundation
import Security

/// Keeps the vault key in the Keychain (N9): a generic password, readable after first unlock,
/// never synced to iCloud and never restored to another device.
struct KeychainKeyStore: KeyStore {
    let service: String
    let account: String
    /// iOS: shared by the app and the share extension. nil means the app's default group.
    let accessGroup: String?

    init(service: String = "dev.jazz.clipsync.vault", account: String = "vault-key", accessGroup: String?) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    /// The store each target uses. `ClipSyncKeychainGroup` in Info.plist is
    /// `$(AppIdentifierPrefix)dev.jazz.clipsync.shared` on iOS (app and extension) and absent on macOS.
    static var appDefault: KeychainKeyStore {
        KeychainKeyStore(accessGroup: Bundle.main.object(forInfoDictionaryKey: "ClipSyncKeychainGroup") as? String)
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            // macOS: use the iOS-style keychain, so the accessibility class and access group apply.
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func loadVaultKey() throws -> VaultKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return try VaultKey(rawBytes: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func saveVaultKey(_ key: VaultKey) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: key.rawBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addQuery = baseQuery.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func deleteVaultKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
