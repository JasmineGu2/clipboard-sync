import Foundation

/// Where a device keeps its vault key at rest (N9). Keychain on Apple, DPAPI on Windows;
/// those live in the app layers. No plain-file store ships.
public protocol KeyStore: Sendable {
    func loadVaultKey() throws -> VaultKey?
    func saveVaultKey(_ key: VaultKey) throws
    func deleteVaultKey() throws
    /// This device's own key pair (F13), made once and never shared. nil until the first save.
    func loadDeviceKey() throws -> DeviceKey?
    func saveDeviceKey(_ key: DeviceKey) throws
}

extension KeyStore {
    /// The stored device key, or a new one saved first.
    public func loadOrCreateDeviceKey() throws -> DeviceKey {
        if let existing = try loadDeviceKey() { return existing }
        let key = DeviceKey.generate()
        try saveDeviceKey(key)
        return key
    }
}

/// Keeps the key in memory only. For tests and the harness.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: VaultKey?
    private var deviceKey: DeviceKey?

    public init(key: VaultKey? = nil, deviceKey: DeviceKey? = nil) {
        self.key = key
        self.deviceKey = deviceKey
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

    public func loadDeviceKey() throws -> DeviceKey? {
        lock.lock()
        defer { lock.unlock() }
        return deviceKey
    }

    public func saveDeviceKey(_ key: DeviceKey) throws {
        lock.lock()
        defer { lock.unlock() }
        deviceKey = key
    }
}
