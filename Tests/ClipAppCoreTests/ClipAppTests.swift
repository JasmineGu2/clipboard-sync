import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

@MainActor
final class ClipAppTests: XCTestCase {
    let server = "http://relay.test:8080"

    func makeApp(home: URL, keyStore: KeyStore, relay: any SyncTransport, name: String) -> (ClipApp, FakePasteboard) {
        let pasteboard = FakePasteboard()
        let app = ClipApp.bootstrap(
            home: home, keyStore: keyStore, deviceName: name, pasteboard: pasteboard,
            makeTransport: factory(relay), autoSync: false)
        return (app, pasteboard)
    }

    func testCreateVaultGoesReadyAndSurvivesRelaunch() async throws {
        let relay = InMemoryRelay()
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()

        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        XCTAssertEqual(app.state, .needsSetup)
        XCTAssertNil(app.history)

        await app.createVault(server: server)
        XCTAssertEqual(app.state, .ready)
        XCTAssertNil(app.message)
        XCTAssertNotNil(try keyStore.loadVaultKey())
        let config = try XCTUnwrap(try AppConfig.load(from: home.appendingPathComponent(ClipApp.configFileName)))
        XCTAssertEqual(config.serverURL.absoluteString, server)
        XCTAssertEqual(config.deviceName, "Mac")

        let history = try XCTUnwrap(app.history)
        await history.send("kept")
        app.stop()

        // Relaunch: straight to ready, same history.
        let (again, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        XCTAssertEqual(again.state, .ready)
        let againHistory = try XCTUnwrap(again.history)
        await againHistory.refresh()
        XCTAssertEqual(againHistory.recent.map(\.text), ["kept"])
        again.stop()
    }

    func testOnboardingSavesTheChosenDeviceName() async throws {
        let relay = InMemoryRelay()
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "iPhone")
        XCTAssertEqual(app.deviceName, "iPhone", "the platform default is the prefill")

        await app.createVault(server: server, deviceName: "  Jazz's iPhone ")
        XCTAssertEqual(app.state, .ready)
        XCTAssertEqual(app.deviceName, "Jazz's iPhone")
        let config = try XCTUnwrap(try AppConfig.load(from: home.appendingPathComponent(ClipApp.configFileName)))
        XCTAssertEqual(config.deviceName, "Jazz's iPhone")
        let history = try XCTUnwrap(app.history)
        await history.send("named")
        XCTAssertEqual(history.recent.first?.sourceDeviceName, "Jazz's iPhone")
        app.stop()

        // Relaunch: the saved name wins over the platform default.
        let (again, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "iPhone")
        XCTAssertEqual(again.deviceName, "Jazz's iPhone")
        again.stop()

        // Blank falls back to the default, on join too.
        let maybeCode = await again.startPairing()
        let code = try XCTUnwrap(maybeCode)
        let (other, _) = makeApp(home: try makeHome(), keyStore: InMemoryKeyStore(), relay: relay, name: "Mac")
        await other.joinVault(server: server, code: code, deviceName: "   ")
        XCTAssertEqual(other.state, .ready)
        XCTAssertEqual(other.deviceName, "Mac")
        other.stop()
    }

    func testCreateVaultWithBadURLOrDeadServerStaysInSetup() async throws {
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: try makeHome(), keyStore: keyStore, relay: OfflineTransport(), name: "Mac")

        await app.createVault(server: "   ")
        XCTAssertEqual(app.state, .needsSetup)
        XCTAssertEqual(app.message, .invalidServer)

        await app.createVault(server: server)
        XCTAssertEqual(app.state, .needsSetup)
        XCTAssertEqual(app.message, .serverUnreachable)
        XCTAssertNil(try keyStore.loadVaultKey(), "nothing is saved until the server answers")
    }

    func testJoinWithCodeFromAnotherDeviceSyncsHistory() async throws {
        let relay = InMemoryRelay()
        let macKeys = InMemoryKeyStore()
        let phoneKeys = InMemoryKeyStore()
        let (mac, macPasteboard) = makeApp(home: try makeHome(), keyStore: macKeys, relay: relay, name: "Mac")
        let (phone, _) = makeApp(home: try makeHome(), keyStore: phoneKeys, relay: relay, name: "iPhone")

        await mac.createVault(server: server)
        let macHistory = try XCTUnwrap(mac.history)
        await macHistory.send("from the mac")

        let maybeCode = await mac.startPairing()
        let code = try XCTUnwrap(maybeCode)
        XCTAssertEqual(code.count, 39, "32 characters in groups of 4")

        await phone.joinVault(server: server, code: code.lowercased())
        XCTAssertEqual(phone.state, .ready)
        XCTAssertNil(phone.message)
        XCTAssertEqual(try phoneKeys.loadVaultKey(), try macKeys.loadVaultKey())

        let phoneHistory = try XCTUnwrap(phone.history)
        await phoneHistory.refresh()
        XCTAssertEqual(phoneHistory.recent.map(\.text), ["from the mac"])
        XCTAssertEqual(phoneHistory.recent.first?.sourceDeviceName, "Mac")

        // And back.
        await phoneHistory.send("from the phone")
        await macHistory.syncNow()
        XCTAssertEqual(macHistory.recent.map(\.text), ["from the phone", "from the mac"])
        let item = try XCTUnwrap(macHistory.recent.first)
        macHistory.copy(item)
        XCTAssertEqual(macPasteboard.written, ["from the phone"])

        mac.stop()
        phone.stop()
    }

    func testJoinWithWrongOrUsedCodeShowsMessage() async throws {
        let relay = InMemoryRelay()
        let (mac, _) = makeApp(home: try makeHome(), keyStore: InMemoryKeyStore(), relay: relay, name: "Mac")
        let phoneKeys = InMemoryKeyStore()
        let (phone, _) = makeApp(home: try makeHome(), keyStore: phoneKeys, relay: relay, name: "iPhone")
        await mac.createVault(server: server)

        await phone.joinVault(server: server, code: "not a code")
        XCTAssertEqual(phone.state, .needsSetup)
        XCTAssertEqual(phone.message, .invalidCode)

        let maybeCode = await mac.startPairing()
        let code = try XCTUnwrap(maybeCode)
        let (other, _) = makeApp(home: try makeHome(), keyStore: InMemoryKeyStore(), relay: relay, name: "PC")
        await other.joinVault(server: server, code: code)
        XCTAssertEqual(other.state, .ready)

        await phone.joinVault(server: server, code: code)
        XCTAssertEqual(phone.state, .needsSetup)
        XCTAssertEqual(phone.message, .codeNotFound, "a code works once")
        XCTAssertNil(try phoneKeys.loadVaultKey())
        mac.stop()
        other.stop()
    }

    func testStartPairingBeforeSetupShowsMessage() async throws {
        let (app, _) = makeApp(home: try makeHome(), keyStore: InMemoryKeyStore(), relay: InMemoryRelay(), name: "Mac")
        let code = await app.startPairing()
        XCTAssertNil(code)
        XCTAssertEqual(app.message, .notSetUp)
    }

    func testCapturePausedPersists() async throws {
        let relay = InMemoryRelay()
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        await app.createVault(server: server)
        app.setCapturePaused(true)
        app.stop()

        let (again, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        XCTAssertTrue(again.capturePaused)
        again.stop()
    }

    /// F14. The age check itself is covered by SyncEngineTests; this covers the setting and its persistence.
    func testExpiryDaysPersistsAndKeepsRecentItems() async throws {
        let relay = InMemoryRelay()
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        await app.createVault(server: server)
        XCTAssertNil(app.expiryDays, "items are kept forever by default")
        let history = try XCTUnwrap(app.history)
        await history.send("today")

        await app.setExpiryDays(30)
        XCTAssertEqual(app.expiryDays, 30)
        XCTAssertNil(app.message)
        await history.refresh()
        XCTAssertEqual(history.recent.map(\.text), ["today"], "a new item isn't expired")
        app.stop()

        let (again, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "Mac")
        XCTAssertEqual(again.expiryDays, 30)
        await again.setExpiryDays(0)
        XCTAssertNil(again.expiryDays, "0 turns expiry off")
        again.stop()
    }

    func testOldConfigWithoutExpiryStillLoads() async throws {
        let json = #"{"serverURL":"http://relay.test:8080","deviceID":"00000000-0000-0000-0000-000000000001","deviceName":"PC"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.expiryDays)
        XCTAssertFalse(config.capturePaused)
    }

    func testAutoSyncRunLoopDeliversRemoteItems() async throws {
        let relay = InMemoryRelay()
        let macKeys = InMemoryKeyStore()
        let pasteboard = FakePasteboard()
        let mac = ClipApp.bootstrap(
            home: try makeHome(), keyStore: macKeys, deviceName: "Mac", pasteboard: pasteboard,
            makeTransport: factory(relay))
        await mac.createVault(server: server)
        let maybeCode = await mac.startPairing()
        let code = try XCTUnwrap(maybeCode)
        let (phone, _) = makeApp(home: try makeHome(), keyStore: InMemoryKeyStore(), relay: relay, name: "iPhone")
        await phone.joinVault(server: server, code: code)

        await phone.history?.send("pushed live")
        let macHistory = try XCTUnwrap(mac.history)
        for _ in 0..<150 where macHistory.recent.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(macHistory.recent.map(\.text), ["pushed live"])
        mac.stop()
        phone.stop()
    }

    // MARK: sendOnce (share extension, Shortcuts)

    func testSendOnceSendsAndSyncs() async throws {
        let relay = InMemoryRelay()
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: relay, name: "iPhone")
        await app.createVault(server: server)
        app.stop()

        let result = await ClipApp.sendOnce("shared text", home: home, keyStore: keyStore, makeTransport: factory(relay))
        XCTAssertEqual(result, .sent)
        let envelopes = await relay.envelopes
        XCTAssertEqual(envelopes.count, 1)
    }

    func testSendOnceTimesOutButKeepsTheItem() async throws {
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: InMemoryRelay(), name: "iPhone")
        await app.createVault(server: server)
        app.stop()

        let started = ContinuousClock.now
        let result = await ClipApp.sendOnce(
            "slow network", home: home, keyStore: keyStore, timeout: .milliseconds(200),
            makeTransport: factory(HangingTransport()))
        XCTAssertEqual(result, .savedOffline)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        let db = try ClipDatabase(url: home.appendingPathComponent(ClipApp.databaseFileName))
        XCTAssertEqual(try db.items().map { $0.content?.text }, ["slow network"])
        XCTAssertEqual(try db.pendingOutbound().count, 1, "queued for the app to push later")
    }

    func testSendOnceBeforeSetupFails() async throws {
        let result = await ClipApp.sendOnce(
            "x", home: try makeHome(), keyStore: InMemoryKeyStore(), makeTransport: factory(InMemoryRelay()))
        XCTAssertEqual(result, .failed(.notSetUp))
        XCTAssertEqual(result.text, Strings.errorNotSetUp)
    }

    func testSendOnceEmptyTextFails() async throws {
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let (app, _) = makeApp(home: home, keyStore: keyStore, relay: InMemoryRelay(), name: "iPhone")
        await app.createVault(server: server)
        app.stop()
        let result = await ClipApp.sendOnce(" ", home: home, keyStore: keyStore, makeTransport: factory(InMemoryRelay()))
        XCTAssertEqual(result, .failed(.emptyText))
    }
}
