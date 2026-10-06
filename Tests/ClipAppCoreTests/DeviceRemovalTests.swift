import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

/// F13 through the app model: the device list, Remove, and what the other devices see.
@MainActor
final class DeviceRemovalTests: XCTestCase {
    let server = "http://relay.test:8080"

    /// Each device gets a transport that carries its own token, like HTTPTransport.
    func makeApp(
        _ name: String, relay: InMemoryRelay, keyStore: InMemoryKeyStore = InMemoryKeyStore(), home: URL? = nil
    ) throws -> ClipApp {
        ClipApp.bootstrap(
            home: try home ?? makeHome(), keyStore: keyStore, deviceName: name, pasteboard: FakePasteboard(),
            makeTransport: { _, token in relay.client(token: token) }, autoSync: false)
    }

    func join(_ name: String, from host: ClipApp, relay: InMemoryRelay) async throws -> ClipApp {
        let app = try makeApp(name, relay: relay)
        let maybeCode = await host.startPairing()
        let code = try XCTUnwrap(maybeCode)
        await app.joinVault(server: server, code: code)
        XCTAssertEqual(app.state, .ready, "\(name) joined")
        return app
    }

    func testRemoveALostDevice() async throws {
        let relay = InMemoryRelay()
        let macKeys = InMemoryKeyStore()
        let mac = try makeApp("Mac", relay: relay, keyStore: macKeys)
        await mac.createVault(server: server)
        let phone = try await join("iPhone", from: mac, relay: relay)
        let lost = try await join("Old laptop", from: mac, relay: relay)
        defer { [mac, phone, lost].forEach { $0.stop() } }
        await relay.pin(tokenSHA256: try XCTUnwrap(macKeys.loadVaultKey()).authTokenSHA256)

        try await XCTUnwrap(lost.history).send("before")
        try await XCTUnwrap(phone.history).syncNow()

        await mac.loadDevices()
        XCTAssertEqual(mac.devices.map(\.name), ["Mac", "iPhone", "Old laptop"])
        XCTAssertEqual(mac.devices.first?.isThisDevice, true)
        let target = try XCTUnwrap(mac.devices.first { $0.name == "Old laptop" })

        let removed = await mac.removeDevice(target)
        XCTAssertTrue(removed)
        XCTAssertNil(mac.message)
        XCTAssertEqual(mac.devices.map(\.name), ["Mac", "iPhone"])

        // The phone follows on its next sync and keeps everything.
        let phoneHistory = try XCTUnwrap(phone.history)
        await phoneHistory.send("after")
        try await XCTUnwrap(mac.history).syncNow()
        XCTAssertEqual(Set(try XCTUnwrap(mac.history).recent.map(\.text)), ["before", "after"])
        // Pairing still works afterwards, with the new key.
        let tablet = try await join("iPad", from: mac, relay: relay)
        defer { tablet.stop() }
        try await XCTUnwrap(tablet.history).syncNow()
        XCTAssertEqual(Set(try XCTUnwrap(tablet.history).recent.map(\.text)), ["before", "after"])

        // The removed device stops and says why.
        let lostHistory = try XCTUnwrap(lost.history)
        await lostHistory.syncNow()
        XCTAssertEqual(lostHistory.syncStatus, .removed)
        XCTAssertEqual(lostHistory.syncStatus.text, Strings.statusRemoved)
        XCTAssertEqual(lostHistory.recent.map(\.text), ["before"])
    }

    func testDeviceListShowsFingerprintsAndJoinDates() async throws {
        let relay = InMemoryRelay()
        let macKeys = InMemoryKeyStore()
        let before = Date().addingTimeInterval(-1)
        let mac = try makeApp("Mac", relay: relay, keyStore: macKeys)
        await mac.createVault(server: server)
        let phone = try await join("iPhone", from: mac, relay: relay)
        defer { [mac, phone].forEach { $0.stop() } }

        await mac.loadDevices()
        XCTAssertEqual(mac.devices.count, 2)
        for device in mac.devices {
            let joined = try XCTUnwrap(device.joinedAt, device.name)
            XCTAssertGreaterThan(joined, before)
            XCTAssertLessThanOrEqual(joined, Date())
            XCTAssertEqual(device.fingerprint.count, 19)
        }
        let me = try XCTUnwrap(mac.devices.first)
        XCTAssertTrue(me.isThisDevice)
        XCTAssertEqual(me.fingerprint, try XCTUnwrap(macKeys.loadDeviceKey()).fingerprint)
        XCTAssertNotEqual(mac.devices[0].fingerprint, mac.devices[1].fingerprint)

        // A revoke re-seals the records it keeps; the join dates survive it.
        let tablet = try await join("iPad", from: mac, relay: relay)
        defer { tablet.stop() }
        await mac.loadDevices()
        let phoneJoined = mac.devices.first { $0.name == "iPhone" }?.joinedAt
        let removediPad = await mac.removeDevice(try XCTUnwrap(mac.devices.first { $0.name == "iPad" }))
        XCTAssertTrue(removediPad)
        XCTAssertEqual(mac.devices.first { $0.name == "iPhone" }?.joinedAt, phoneJoined)
    }

    func testRemovedDeviceSetsUpAgainWithoutDeletingItsHistory() async throws {
        let relay = InMemoryRelay()
        let mac = try makeApp("Mac", relay: relay)
        await mac.createVault(server: server)
        let lostHome = try makeHome()
        let lostKeys = InMemoryKeyStore()
        let lost = try makeApp("Old laptop", relay: relay, keyStore: lostKeys, home: lostHome)
        let maybeCode = await mac.startPairing()
        await lost.joinVault(server: server, code: try XCTUnwrap(maybeCode))
        defer { [mac, lost].forEach { $0.stop() } }
        try await XCTUnwrap(lost.history).send("kept on the old laptop")
        await mac.loadDevices()
        let removedOldlaptop = await mac.removeDevice(try XCTUnwrap(mac.devices.first { $0.name == "Old laptop" }))
        XCTAssertTrue(removedOldlaptop)

        XCTAssertFalse(lost.isRemoved)
        try await XCTUnwrap(lost.history).syncNow()
        XCTAssertTrue(lost.isRemoved)
        let oldDeviceKey = try XCTUnwrap(lostKeys.loadDeviceKey())

        XCTAssertTrue(lost.setUpAgain())
        XCTAssertEqual(lost.state, .needsSetup)
        XCTAssertNil(lost.history)
        XCTAssertFalse(lost.isRemoved)
        XCTAssertNil(try lostKeys.loadVaultKey())
        XCTAssertNotEqual(try lostKeys.loadDeviceKey(), oldDeviceKey)
        XCTAssertEqual(lost.deviceName, "Old laptop", "the onboarding field keeps the name")

        // Moved aside, not deleted: the old database still opens and still has the history.
        let files = FileManager.default
        let archives = try files.contentsOfDirectory(atPath: lostHome.path).filter { $0.hasPrefix(ClipApp.removedFolderPrefix) }
        XCTAssertEqual(archives.count, 1)
        let archive = lostHome.appendingPathComponent(archives[0])
        XCTAssertTrue(files.fileExists(atPath: archive.appendingPathComponent(ClipApp.configFileName).path))
        XCTAssertFalse(files.fileExists(atPath: lostHome.appendingPathComponent(ClipApp.configFileName).path))
        let oldDB = try ClipDatabase(url: archive.appendingPathComponent(ClipApp.databaseFileName))
        XCTAssertEqual(try oldDB.items(limit: 10).compactMap { $0.content?.text }, ["kept on the old laptop"])

        // A relaunch stays in onboarding, and joining again works from a fresh, empty history.
        let relaunched = try makeApp("Old laptop", relay: relay, keyStore: lostKeys, home: lostHome)
        XCTAssertEqual(relaunched.state, .needsSetup)
        relaunched.stop()
        try await XCTUnwrap(mac.history).send("after the removal")
        let code = await mac.startPairing()
        await lost.joinVault(server: server, code: try XCTUnwrap(code))
        XCTAssertEqual(lost.state, .ready)
        let history = try XCTUnwrap(lost.history)
        await history.syncNow()
        XCTAssertEqual(Set(history.recent.map(\.text)), ["kept on the old laptop", "after the removal"])
        await mac.loadDevices()
        XCTAssertEqual(mac.devices.map(\.name).sorted(), ["Mac", "Old laptop"])
    }

    func testSetUpAgainOnlyFromReady() async throws {
        let app = try makeApp("Mac", relay: InMemoryRelay())
        XCTAssertEqual(app.state, .needsSetup)
        XCTAssertFalse(app.setUpAgain())
        XCTAssertEqual(app.state, .needsSetup)
    }

    func testCannotRemoveThisDevice() async throws {
        let relay = InMemoryRelay()
        let mac = try makeApp("Mac", relay: relay)
        defer { mac.stop() }
        await mac.createVault(server: server)
        await mac.loadDevices()
        let me = try XCTUnwrap(mac.devices.first)
        XCTAssertTrue(me.isThisDevice)
        let removed = await mac.removeDevice(me)
        XCTAssertFalse(removed)
        XCTAssertEqual(mac.message, .cannotRemoveThisDevice)
    }

    func testRevokeErrorsMapToCopy() {
        XCTAssertEqual(AppMessage(SyncError.deviceRevoked), .removedFromVault)
        XCTAssertEqual(AppMessage(SyncError.unknownDevice).text, Strings.errorUnknownDevice)
        XCTAssertEqual(AppMessage(SyncError.notRegistered).text, Strings.errorNotRegistered)
        XCTAssertEqual(AppMessage(SyncError.cannotRevokeThisDevice).text, Strings.errorCannotRemoveThisDevice)
    }
}
