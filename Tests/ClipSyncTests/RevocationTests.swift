import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync

/// F13: revoking a lost device. The relay here is pinned to the vault's token, like a real deployment.
final class RevocationTests: XCTestCase {
    struct Device {
        let name: String
        let id: DeviceID
        let engine: SyncEngine
        let db: ClipDatabase
        let store: InMemoryKeyStore
        let deviceKey: DeviceKey

        var idString: String { id.rawValue.uuidString }

        func texts() throws -> Set<String> {
            Set(try db.items(limit: 10_000).compactMap { $0.content?.text })
        }
    }

    /// Fails the next `count` key saves, like a Keychain error or a crash right before the write.
    final class FlakySaves: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = 0
        func failNext(_ count: Int) { lock.withLock { remaining = count } }
        func check() throws {
            try lock.withLock {
                if remaining > 0 {
                    remaining -= 1
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
    }

    func makeDevice(
        _ name: String, relay: InMemoryRelay, key: VaultKey, db: ClipDatabase? = nil, id: DeviceID = DeviceID(),
        store: InMemoryKeyStore? = nil, saves: FlakySaves = FlakySaves()
    ) throws -> Device {
        let db = try db ?? ClipDatabase.inMemory()
        let store = store ?? InMemoryKeyStore(key: key, deviceKey: .generate())
        let deviceKey = try store.loadOrCreateDeviceKey()
        let membership = SyncEngine.Membership(
            deviceKey: deviceKey,
            makeTransport: { relay.client(token: $0) },
            saveVaultKey: { try saves.check(); try store.saveVaultKey($0) })
        let engine = try SyncEngine(
            db: db, vaultKey: try XCTUnwrap(store.loadVaultKey()), transport: relay.client(token: key.authToken),
            device: id, deviceName: name, log: { _ in }, membership: membership)
        return Device(name: name, id: id, engine: engine, db: db, store: store, deviceKey: deviceKey)
    }

    /// A pinned relay and three synced devices, each with one item.
    func makeVault() async throws -> (InMemoryRelay, VaultKey, Device, Device, Device) {
        let key = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: key.authTokenSHA256)
        let mac = try makeDevice("Mac", relay: relay, key: key)
        let pc = try makeDevice("PC", relay: relay, key: key)
        let lost = try makeDevice("Lost iPhone", relay: relay, key: key)
        for device in [mac, pc, lost] {
            try await device.engine.addText("from \(device.name)")
            try await device.engine.syncOnce()
        }
        for device in [mac, pc, lost] { try await device.engine.syncOnce() }
        return (relay, key, mac, pc, lost)
    }

    // MARK: The guarantee

    func testRevokedDeviceCanNoLongerSyncOrReadWhileTheOthersCarryOn() async throws {
        let (relay, oldKey, mac, pc, lost) = try await makeVault()
        let before: Set = ["from Mac", "from PC", "from Lost iPhone"]
        XCTAssertEqual(try lost.texts(), before)

        let removed = try await mac.engine.revoke([lost.idString])
        XCTAssertEqual(removed.map(\.name), ["Lost iPhone"])
        let newKey = await mac.engine.currentVaultKey
        XCTAssertNotEqual(newKey, oldKey)
        XCTAssertEqual(try mac.store.loadVaultKey(), newKey, "the new key is saved before it's used")

        // The PC picks up the new key on its next sync, and nothing synced before the revoke is lost.
        try await pc.engine.addText("PC after")
        try await pc.engine.syncOnce()
        let pcKey = await pc.engine.currentVaultKey
        XCTAssertEqual(pcKey, newKey)
        XCTAssertEqual(try pc.store.loadVaultKey(), newKey)
        try await mac.engine.addText("Mac after")
        try await mac.engine.syncOnce()
        try await pc.engine.syncOnce()
        let expected = before.union(["PC after", "Mac after"])
        XCTAssertEqual(try mac.texts(), expected)
        XCTAssertEqual(try pc.texts(), expected)

        // The lost device can't pull or push any more, and says so.
        try await lost.engine.addText("Lost after")
        do {
            try await lost.engine.syncOnce()
            XCTFail("a revoked device synced")
        } catch {
            XCTAssertEqual(error as? SyncError, .deviceRevoked)
        }
        let lostStatus = await lost.engine.status
        XCTAssertEqual(lostStatus, .revoked)
        XCTAssertEqual(try lost.texts(), before.union(["Lost after"]), "it learned nothing new")
        XCTAssertFalse(try mac.texts().contains("Lost after"))
        do {
            _ = try await relay.client(token: oldKey.authToken).pull(after: 0, limit: 100, wait: 0)
            XCTFail("the old token still pulls")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorized)
        }

        // Even with the relay's whole log in hand (a leaked backup), the old key opens nothing written since.
        let oldCipher = OpCipher(vaultKey: oldKey)
        let log = await relay.envelopes
        XCTAssertFalse(log.isEmpty)
        for envelope in log { XCTAssertThrowsError(try oldCipher.open(envelope)) }
        // And none of the handoffs open for it, with its own device key or under any device ID.
        for device in [mac, pc, lost] {
            for blob in try await relay.handoffs(deviceID: device.idString) {
                for id in [device.idString, lost.idString] {
                    XCTAssertThrowsError(
                        try RekeyHandoff.open(blob, deviceKey: lost.deviceKey, deviceID: id, currentKey: oldKey))
                }
            }
        }
        let lostHandoffs = try await relay.handoffs(deviceID: lost.idString)
        XCTAssertTrue(lostHandoffs.isEmpty)
    }

    func testDeviceListShowsNamesAndTheRelayOnlySeesCiphertext() async throws {
        let (relay, _, mac, pc, lost) = try await makeVault()
        let devices = try await pc.engine.devices()
        XCTAssertEqual(devices.map(\.name), ["PC", "Lost iPhone", "Mac"], "this device first, then by name")
        XCTAssertEqual(devices.map(\.isThisDevice), [true, false, false])
        XCTAssertEqual(Set(devices.map(\.id)), [mac.idString, pc.idString, lost.idString])
        for record in await relay.deviceRecords {
            XCTAssertFalse(String(decoding: record.sealed, as: UTF8.self).contains("Mac"))
        }

        _ = try await mac.engine.revoke([lost.idString])
        try await pc.engine.syncOnce()
        let after = try await pc.engine.devices()
        XCTAssertEqual(after.map(\.name), ["PC", "Mac"])
    }

    // MARK: Remaining devices

    /// A change made on a remaining device while it was offline survives the relay's wipe.
    func testUnsyncedChangesOnARemainingDeviceSurvive() async throws {
        let (_, _, mac, pc, lost) = try await makeVault()
        let item = try await pc.engine.addText("written offline")
        try await pc.engine.setPinned(item, true)
        _ = try await mac.engine.revoke([lost.idString])
        try await pc.engine.syncOnce()
        try await mac.engine.syncOnce()
        XCTAssertTrue(try mac.texts().contains("written offline"))
        XCTAssertEqual(try mac.db.item(item)?.pinned.value, true)
    }

    /// The run loop picks up the new key by itself, and a revoked device's run loop stops.
    func testRunningDevicesFollowTheRevokeOnTheirOwn() async throws {
        let (_, _, mac, pc, lost) = try await makeVault()
        let pcLoop = Task { await pc.engine.run() }
        let lostLoop = Task { await lost.engine.run() }
        defer {
            pcLoop.cancel()
            lostLoop.cancel()
        }
        try await Task.sleep(for: .milliseconds(100))  // both are long-polling with the old token

        _ = try await mac.engine.revoke([lost.idString])
        try await mac.engine.addText("after the revoke")
        try await mac.engine.syncOnce()

        try await waitUntil { (try? pc.texts().contains("after the revoke")) == true }
        let pcKey = await pc.engine.currentVaultKey
        let macKey = await mac.engine.currentVaultKey
        XCTAssertEqual(pcKey, macKey)
        // The lost device's loop ends on its own (cancel is only the deferred cleanup).
        let stopped = Task { await lostLoop.value; return true }
        try await waitUntil { await lost.engine.status == .revoked }
        let didStop = await stopped.value
        XCTAssertTrue(didStop)
        XCTAssertFalse(try lost.texts().contains("after the revoke"))
    }

    /// A device that was offline through two revokes follows the handoff chain to the newest key.
    func testADeviceOfflineThroughTwoRevokesCatchesUp() async throws {
        let (relay, key, mac, pc, lost) = try await makeVault()
        let other = try makeDevice("Old iPad", relay: relay, key: key)
        try await other.engine.syncOnce()

        _ = try await mac.engine.revoke([lost.idString])
        _ = try await mac.engine.revoke([other.idString])
        try await mac.engine.addText("after both")
        try await mac.engine.syncOnce()

        try await pc.engine.syncOnce()
        let pcKey = await pc.engine.currentVaultKey
        let macKey = await mac.engine.currentVaultKey
        XCTAssertEqual(pcKey, macKey)
        XCTAssertTrue(try pc.texts().contains("after both"))
        do {
            try await other.engine.syncOnce()
            XCTFail("the second revoked device synced")
        } catch {
            XCTAssertEqual(error as? SyncError, .deviceRevoked)
        }
    }

    /// The revoking device fails to save the new key after the relay already switched. Its own handoff gets it back.
    func testTheRevokingDeviceRecoversIfSavingTheNewKeyFails() async throws {
        let key = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: key.authTokenSHA256)
        let saves = FlakySaves()
        let mac = try makeDevice("Mac", relay: relay, key: key, saves: saves)
        let lost = try makeDevice("Lost", relay: relay, key: key)
        try await mac.engine.addText("keep me")
        try await mac.engine.syncOnce()
        try await lost.engine.syncOnce()

        saves.failNext(1)
        do {
            _ = try await mac.engine.revoke([lost.idString])
            XCTFail("revoke should report the failed save")
        } catch {}
        XCTAssertEqual(try mac.store.loadVaultKey(), key, "still the old key on disk")

        // Restart: a fresh engine on the same database and key store.
        let restarted = try makeDevice("Mac", relay: relay, key: key, db: mac.db, id: mac.id, store: mac.store)
        try await restarted.engine.syncOnce()
        XCTAssertNotEqual(try restarted.store.loadVaultKey(), key)
        XCTAssertTrue(try restarted.texts().contains("keep me"))
        let pulled = try await relay.client(token: try XCTUnwrap(restarted.store.loadVaultKey()).authToken)
            .pull(after: 0, limit: 100, wait: 0)
        XCTAssertFalse(pulled.envelopes.isEmpty, "the history was re-pushed under the new key")
    }

    /// A device that registers after the revoker read the list must not be dropped without a key: the relay
    /// refuses a revoke whose device list is stale, and the engine reads the list again.
    func testAStaleDeviceListIsRefused() async throws {
        let (relay, key, mac, pc, lost) = try await makeVault()
        let late = try makeDevice("Late iPad", relay: relay, key: key)
        try await late.engine.syncOnce()  // registered
        let stale = RevokeRequest(
            newTokenSHA256: VaultKey.generate().authTokenSHA256,
            devices: await relay.deviceRecords.filter { $0.deviceID != lost.idString },
            handoffs: [], expectedDeviceIDs: [mac.idString, pc.idString, lost.idString])
        do {
            _ = try await relay.client(token: key.authToken).revoke(stale)
            XCTFail("a stale list was accepted")
        } catch {
            XCTAssertEqual(error as? TransportError, .conflict)
        }
        // The engine reads the current list, so the late device is kept and follows the new key.
        _ = try await mac.engine.revoke([lost.idString])
        try await late.engine.syncOnce()
        let lateKey = await late.engine.currentVaultKey
        let macKey = await mac.engine.currentVaultKey
        XCTAssertEqual(lateKey, macKey)
    }

    // MARK: Refusals

    func testRefusesToRevokeItselfAnUnknownDeviceOrWithoutADeviceKey() async throws {
        let (relay, key, mac, _, _) = try await makeVault()
        for (ids, expected) in [(Set([mac.idString]), SyncError.cannotRevokeThisDevice), (Set(["nope"]), .unknownDevice),
                                (Set<String>(), .unknownDevice)] {
            do {
                _ = try await mac.engine.revoke(ids)
                XCTFail("revoked \(ids)")
            } catch {
                XCTAssertEqual(error as? SyncError, expected)
            }
        }
        let plain = try SyncEngine(
            db: try .inMemory(), vaultKey: key, transport: relay.client(token: key.authToken), device: DeviceID(),
            deviceName: "plain", log: { _ in })
        do {
            _ = try await plain.revoke(["x"])
            XCTFail("revoked without membership")
        } catch {
            XCTAssertEqual(error as? SyncError, .membershipUnavailable)
        }
        let unchanged = await mac.engine.currentVaultKey
        XCTAssertEqual(unchanged, key)
    }

    /// An engine without membership (the share extension) still gets a plain 401, not a revoke.
    func testEnginesWithoutMembershipJustSeeUnauthorized() async throws {
        let key = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: VaultKey.generate().authTokenSHA256)
        let plain = try SyncEngine(
            db: try .inMemory(), vaultKey: key, transport: relay.client(token: key.authToken), device: DeviceID(),
            deviceName: "plain", log: { _ in })
        try await plain.addText("x")
        do {
            try await plain.syncOnce()
            XCTFail("synced with the wrong token")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorized)
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }
}
