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
    func makeApp(_ name: String, relay: InMemoryRelay, keyStore: InMemoryKeyStore = InMemoryKeyStore()) throws -> ClipApp {
        ClipApp.bootstrap(
            home: try makeHome(), keyStore: keyStore, deviceName: name, pasteboard: FakePasteboard(),
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
