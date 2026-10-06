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

    /// F13: this device's own key pair, a second item next to the vault key with the same protection.
    static let deviceKeyAccount = "device-key"

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

    /// The access group still has an unexpanded team prefix: `$(AppIdentifierPrefix)` came out empty, which
    /// happens when the project was generated without a team (`CLIPSYNC_TEAM_ID`). Without this check the
    /// Keychain fails later with the opaque -34018 (errSecMissingEntitlement).
    struct MissingTeamPrefix: Error, CustomStringConvertible {
        let accessGroup: String
        var description: String {
            "Keychain access group \"\(accessGroup)\" has no team ID prefix. "
                + "Set CLIPSYNC_TEAM_ID, run xcodegen again, and rebuild (see apps/Apple/README.md)."
        }
    }

    private func checkAccessGroup() throws {
        guard let accessGroup else { return }
        // A real group starts with the 10-character team ID ("ABCDE12345.dev.jazz..."). An unset team leaves
        // ".dev.jazz...", "$(AppIdentifierPrefix)dev.jazz..." or no prefix at all.
        let prefix = accessGroup.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let hasTeamPrefix = prefix.count == 10 && prefix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        if !hasTeamPrefix || accessGroup.contains("$(") {
            throw MissingTeamPrefix(accessGroup: accessGroup)
        }
    }

    private var baseQuery: [String: Any] { query(account: account) }

    private func query(account: String) -> [String: Any] {
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
        try load(account: account).map { try VaultKey(rawBytes: $0) }
    }

    func saveVaultKey(_ key: VaultKey) throws {
        try save(key.rawBytes, account: account)
    }

    func loadDeviceKey() throws -> DeviceKey? {
        try load(account: Self.deviceKeyAccount).map { try DeviceKey(rawBytes: $0) }
    }

    func saveDeviceKey(_ key: DeviceKey) throws {
        try save(key.rawBytes, account: Self.deviceKeyAccount)
    }

    private func load(account: String) throws -> Data? {
        try checkAccessGroup()
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func save(_ data: Data, account: String) throws {
        try checkAccessGroup()
        let base = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addQuery = base.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func deleteVaultKey() throws {
        try checkAccessGroup()
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
