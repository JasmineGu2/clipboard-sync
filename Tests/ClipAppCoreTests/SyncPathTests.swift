import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

/// F16: the history shows whether it syncs through the relay or directly.
@MainActor
final class SyncPathTests: XCTestCase {
    func testHistoryShowsDirectWhileTheRelayIsDownAndRelayAfter() async throws {
        let key = VaultKey.generate()
        let relay = InMemoryRelay()
        let network = InMemoryPeerNetwork()
        var engines: [SyncEngine] = []
        var dbs: [ClipDatabase] = []
        for (name, listens) in [("Mac", true), ("iPhone", false)] {
            let db = try ClipDatabase.inMemory()
            let store = InMemoryKeyStore(key: key, deviceKey: .generate())
            let engine = try SyncEngine(
                db: db, vaultKey: key, transport: relay.client(token: key.authToken), device: DeviceID(),
                deviceName: name, log: { _ in },
                membership: SyncEngine.Membership(
                    deviceKey: try store.loadOrCreateDeviceKey(), makeTransport: { relay.client(token: $0) },
                    saveVaultKey: { try store.saveVaultKey($0) }))
            let listener = listens ? network.makeListener() : nil
            try listener?.start { await engine.handlePeerRequest($0) }
            await engine.enablePeerSync(PeerSetup(dialer: network.dialer, listenAddress: listener?.boundAddress))
            engines.append(engine)
            dbs.append(db)
        }
        for engine in engines { try await engine.syncOnce() }
        for engine in engines { _ = try await engine.devices() }  // both registered; each caches the other
        let phone = HistoryModel(engine: engines[1], db: dbs[1], pasteboard: FakePasteboard())

        await relay.setReachable(false)
        let sent = await phone.send("over the tailnet")
        XCTAssertTrue(sent)
        await engines[1].syncWithPeers()
        await phone.syncNow()
        XCTAssertEqual(phone.syncStatus, .direct(peers: 1))
        XCTAssertEqual(phone.syncStatus.text, "Server unreachable. Syncing directly with 1 of your devices.")
        XCTAssertEqual(phone.syncPath.text, "Sync path: direct to 1 device(s), relay unreachable")
        XCTAssertEqual(try dbs[0].items(limit: 10).first?.content?.text, "over the tailnet")

        await relay.setReachable(true)
        await phone.syncNow()
        XCTAssertEqual(phone.syncPath, .relay)
        XCTAssertEqual(phone.syncPath.text, Strings.syncPathRelay)
    }
}
