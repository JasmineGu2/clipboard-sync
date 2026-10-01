import Foundation

/// Where a device keeps its vault key at rest (N9). Keychain on Apple, DPAPI on Windows;
/// those live in the app layers. No plain-file store ships.
public protocol KeyStore: Sendable {
    func loadVaultKey() throws -> VaultKey?
    func saveVaultKey(_ key: VaultKey) throws
    func deleteVaultKey() throws
}

/// Keeps the key in memory only. For tests and the harness.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: VaultKey?

    public init(key: VaultKey? = nil) {
        self.key = key
    }

    public func loadVaultKey() throws -> VaultKey? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    public func saveVaultKey(_ key: VaultKey) throws {
        lock.lock()
        defer { lock.unlock() }
        self.key = key
    }

    public func deleteVaultKey() throws {
        lock.lock()
        defer { lock.unlock() }
        key = nil
    }
}
