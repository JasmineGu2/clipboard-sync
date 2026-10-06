import ClipCore
import ClipCrypto
import ClipWire
import Foundation

// F13: revoking a lost device from any other device. See docs/design.md §3 and docs/decisions.md.
//
// Each device has its own X25519 key pair and registers a record (public key + sealed name) on the relay. To revoke,
// a device makes a new vault key and, in one relay request, swaps the relay's token for the new key's token, wipes
// the log (new epoch), rewrites the device list without the revoked devices, and leaves each remaining device the
// new key sealed to its public key (`RekeyHandoff`). A remaining device's next request gets 401; it fetches its
// handoff, opens it, saves the new key, and the epoch change makes it re-push its whole history under the new key.
// The revoked device has neither the new token nor a handoff it can open.

/// One device in the vault, as this device sees it.
public struct VaultDevice: Equatable, Hashable, Sendable, Identifiable {
    /// The device ID as the relay stores it (an uppercase UUID string).
    public let id: String
    public let name: String
    public let publicKey: Data
    public let isThisDevice: Bool
    /// When the device says it joined (sealed in its record). nil for devices that predate it.
    public let joinedAt: Date?

    public init(id: String, name: String, publicKey: Data, isThisDevice: Bool, joinedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.isThisDevice = isThisDevice
        self.joinedAt = joinedAt
    }

    /// The short fingerprint of the device's public key, for checking the list by eye (`DeviceFingerprint`).
    public var fingerprint: String { DeviceFingerprint.of(publicKey: publicKey) }
}

extension SyncEngine {
    /// What an engine needs to take part in revocation. Engines without it (tests, the share extension's one-shot
    /// send) sync normally but never register, never revoke and never pick up a new key.
    public struct Membership: Sendable {
        public var deviceKey: DeviceKey
        /// Makes the transport for a bearer token, used when the vault key changes.
        public var makeTransport: @Sendable (String) -> any SyncTransport
        /// Persists a new vault key (Keychain, DPAPI). Called before the engine starts using the key.
        public var saveVaultKey: @Sendable (VaultKey) throws -> Void
        /// When this device joined the vault (its config's setup time), sealed into its record for the device list.
        public var joinedAt: Date?

        public init(
            deviceKey: DeviceKey,
            makeTransport: @escaping @Sendable (String) -> any SyncTransport,
            saveVaultKey: @escaping @Sendable (VaultKey) throws -> Void,
            joinedAt: Date? = nil
        ) {
            self.deviceKey = deviceKey
            self.makeTransport = makeTransport
            self.saveVaultKey = saveVaultKey
            self.joinedAt = joinedAt
        }
    }

    /// The vault key in use. Changes when a device is revoked (here or on another device).
    public var currentVaultKey: VaultKey { vaultKey }

    var deviceIDString: String { device.rawValue.uuidString }

    /// The vault's devices that this device can read, this device first, then by name. Records that don't open
    /// under the current vault key are left out (and are dropped by the next revoke).
    public func devices() async throws -> [VaultDevice] {
        try await registerIfNeeded()
        return opened(try await transport.listDevices())
    }

    /// Opens records under the current vault key, this device first, then by name.
    private func opened(_ records: [DeviceRecord]) -> [VaultDevice] {
        let key = vaultKey
        let mine = deviceIDString
        return records.compactMap { record -> VaultDevice? in
            guard let info = try? DeviceDirectory.open(record, vaultKey: key) else {
                log("ignoring a device record that doesn't open under this vault key: \(record.deviceID)")
                return nil
            }
            return VaultDevice(
                id: record.deviceID, name: info.name, publicKey: record.publicKey,
                isThisDevice: record.deviceID == mine, joinedAt: info.joinedAt)
        }
        .sorted { ($0.isThisDevice ? 0 : 1, $0.name.lowercased(), $0.id) < ($1.isThisDevice ? 0 : 1, $1.name.lowercased(), $1.id) }
    }

    /// Removes devices from the vault (F13). Afterwards they can't push, pull, or read anything synced from then on.
    /// Every other listed device gets the new vault key the next time it syncs. Returns the removed devices.
    ///
    /// Runs exclusively with `syncOnce`. Syncs first, so nothing this device holds is lost when the relay wipes
    /// its log, and syncs again after, re-pushing the whole history under the new key.
    @discardableResult
    public func revoke(_ ids: Set<String>) async throws -> [VaultDevice] {
        guard let membership else { throw SyncError.membershipUnavailable }
        guard !ids.contains(deviceIDString) else { throw SyncError.cannotRevokeThisDevice }
        guard !ids.isEmpty else { throw SyncError.unknownDevice }
        while let running = syncTask { _ = await running.result }
        let work = Task { try await self.performRevoke(ids, membership: membership) }
        syncTask = Task { _ = try await work.value }
        defer { syncTask = nil }
        return try await work.value
    }

    private func performRevoke(_ ids: Set<String>, membership: Membership) async throws -> [VaultDevice] {
        try await performSyncRecoveringKey()
        try await registerIfNeeded()
        // A device that registers between reading the list and the revoke would be dropped without a key, so the
        // relay checks the list is unchanged (409 otherwise) and this reads it again.
        for attempt in 1...3 {
            let records = try await transport.listDevices()
            do {
                return try await revoke(ids, records: records, membership: membership)
            } catch TransportError.conflict where attempt < 3 {
                log("the device list changed during the revoke; reading it again")
            }
        }
        throw TransportError.conflict  // not reached: the last attempt rethrows
    }

    private func revoke(
        _ ids: Set<String>, records listed: [DeviceRecord], membership: Membership
    ) async throws -> [VaultDevice] {
        let all = opened(listed)
        guard all.contains(where: \.isThisDevice) else { throw SyncError.notRegistered }
        let removed = all.filter { ids.contains($0.id) }
        guard removed.count == ids.count else { throw SyncError.unknownDevice }
        let kept = all.filter { !ids.contains($0.id) }

        let oldKey = vaultKey
        let newKey = VaultKey.generate()
        let records = try kept.map {
            try DeviceDirectory.seal(
                deviceID: $0.id, publicKey: $0.publicKey, info: DeviceInfo(name: $0.name, joinedAt: $0.joinedAt), vaultKey: newKey)
        }
        // This device gets a handoff too: if it crashes before saving the new key, its next 401 recovers it.
        let handoffs = try kept.map {
            Handoff(
                deviceID: $0.id,
                blob: try RekeyHandoff.seal(newKey: newKey, toPublicKey: $0.publicKey, deviceID: $0.id, oldKey: oldKey))
        }
        _ = try await transport.revoke(RevokeRequest(
            newTokenSHA256: newKey.authTokenSHA256, devices: records, handoffs: handoffs,
            expectedDeviceIDs: listed.map(\.deviceID)))
        log("removed \(removed.map(\.name).joined(separator: ", ")) from the vault; switching to a new vault key")

        try adopt(newKey, membership: membership)
        registeredUnder = newKey.authTokenSHA256  // the revoke already wrote this device's record under the new key
        wake()  // a long-poll still waiting with the old token ends now
        do {
            try await performSync()  // new epoch: re-pushes everything under the new key
        } catch {
            log("revoked, but the first sync under the new key failed (it retries): \(error)")
        }
        return removed
    }

    /// `syncOnce`'s body: a sync that, on 401, looks for a new vault key left for this device and syncs again with it.
    func performSyncRecoveringKey() async throws {
        do {
            try await performSync()
        } catch TransportError.unauthorized where membership != nil {
            guard try await recoverFromUnauthorized() else {
                status = .revoked
                throw SyncError.deviceRevoked
            }
            try await performSync()
        }
    }

    /// After a 401: follows any handoffs for this device (oldest first, each opened with the key before it) to the
    /// newest vault key, saves it and switches to it. Returns false when there's no new key and the current one
    /// really is refused, meaning this device was revoked.
    func recoverFromUnauthorized() async throws -> Bool {
        guard let membership else { return false }
        let blobs: [Data]
        do {
            blobs = try await transport.handoffs(deviceID: deviceIDString)
        } catch TransportError.notFound {
            blobs = []  // a relay from before F13
        }
        var key = vaultKey
        for blob in blobs {
            if let next = try? RekeyHandoff.open(
                blob, deviceKey: membership.deviceKey, deviceID: deviceIDString, currentKey: key)
            {
                key = next
            }
        }
        if key != vaultKey {
            try adopt(key, membership: membership)
            log("another device removed a device from the vault; switched to the new vault key")
            return true
        }
        // No new key. The 401 may have raced this device's own key change, so ask again with the current token.
        do {
            _ = try await transport.listDevices()
            return true
        } catch TransportError.unauthorized {
            return false
        } catch TransportError.notFound {
            return false  // a relay from before F13 refused the token: nothing this device can do
        }
    }

    /// Saves `key`, then uses it for everything. The epoch change on the next response re-pushes the history.
    ///
    /// Blobs too: the relay wiped them with the log, so the epoch change's `markAllOutbound` queues every visible
    /// item's blob for upload, and the new transferer seals them under the new key. A device without a blob's file
    /// drops that job; if no remaining device has it, the item keeps its thumbnail and its download says it's
    /// not on the relay. An upload or download still running on the old transferer gets 401 and is retried.
    private func adopt(_ key: VaultKey, membership: Membership) throws {
        try membership.saveVaultKey(key)
        vaultKey = key
        cipher = OpCipher(vaultKey: key)
        transport = membership.makeTransport(key.authToken)
        transferer = Self.makeTransferer(cache: blobCache, transport: transport, vaultKey: key, meter: transferMeter)
        registeredUnder = nil
        wakeBlobs()
    }

    /// Puts this device's record on the relay once per vault key, so other devices can hand it a new key.
    /// A relay from before F13 (404) or a taken device ID (409) is logged and not retried.
    func registerIfNeeded() async throws {
        guard let membership else { return }
        let tokenHash = vaultKey.authTokenSHA256
        guard registeredUnder != tokenHash else { return }
        let record = try DeviceDirectory.seal(
            deviceID: deviceIDString, publicKey: membership.deviceKey.publicKey,
            info: DeviceInfo(name: deviceName, joinedAt: membership.joinedAt), vaultKey: vaultKey)
        do {
            try await transport.putDevice(record)
        } catch TransportError.notFound {
            log("the relay has no device list (it predates revocation); this device can't be handed a new key")
        } catch TransportError.conflict {
            log("the relay holds another key for this device ID; this device can't be handed a new key")
        } catch TransportError.rateLimited {
            log("the relay's device list is full; this device can't be handed a new key")
        }
        registeredUnder = tokenHash
    }
}
