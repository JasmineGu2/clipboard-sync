import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync

/// F16: direct device-to-device sync while the relay is unreachable.
final class PeerSyncTests: XCTestCase {
    struct Device {
        let name: String
        let id: DeviceID
        let engine: SyncEngine
        let db: ClipDatabase
        let store: InMemoryKeyStore
        let listener: PeerListener?

        var idString: String { id.rawValue.uuidString }

        func texts() throws -> Set<String> {
            Set(try db.items(limit: 10_000).compactMap { $0.content?.text })
        }
    }

    /// Records every request a dialer sends, so tests can replay or tamper with one.
    final class RecordingDialer: PeerDialer, @unchecked Sendable {
        let inner: any PeerDialer
        private let lock = NSLock()
        private var sent: [(host: String, port: Int, request: Data)] = []
        init(_ inner: any PeerDialer) { self.inner = inner }
        var requests: [(host: String, port: Int, request: Data)] { lock.withLock { sent } }

        func exchange(host: String, port: Int, request: Data, timeout: Duration) async throws -> Data {
            lock.withLock { sent.append((host, port, request)) }
            return try await inner.exchange(host: host, port: port, request: request, timeout: timeout)
        }
    }

    func makeDevice(
        _ name: String, relay: InMemoryRelay, key: VaultKey, network: InMemoryPeerNetwork, listens: Bool,
        dialer: (any PeerDialer)? = nil, store: InMemoryKeyStore? = nil, db: ClipDatabase? = nil, id: DeviceID = DeviceID(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> Device {
        let db = try db ?? ClipDatabase.inMemory()
        let store = store ?? InMemoryKeyStore(key: key, deviceKey: .generate())
        let membership = SyncEngine.Membership(
            deviceKey: try store.loadOrCreateDeviceKey(),
            makeTransport: { relay.client(token: $0) },
            saveVaultKey: { try store.saveVaultKey($0) })
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay.client(token: key.authToken), device: id, deviceName: name,
            now: now, log: { _ in }, membership: membership)
        let listener = listens ? network.makeListener() : nil
        if let listener { try listener.start(handler: { await engine.handlePeerRequest($0) }) }
        await engine.enablePeerSync(PeerSetup(dialer: dialer ?? network.dialer, listenAddress: listener?.boundAddress))
        return Device(name: name, id: id, engine: engine, db: db, store: store, listener: listener)
    }

    /// A pinned relay, a Mac and a PC that listen, and an iPhone that only dials. All synced through the relay, so
    /// each has the others' device records cached.
    func makeVault() async throws -> (InMemoryRelay, VaultKey, InMemoryPeerNetwork, Device, Device, Device) {
        let key = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: key.authTokenSHA256)
        let network = InMemoryPeerNetwork()
        let mac = try await makeDevice("Mac", relay: relay, key: key, network: network, listens: true)
        let pc = try await makeDevice("PC", relay: relay, key: key, network: network, listens: true)
        let phone = try await makeDevice("iPhone", relay: relay, key: key, network: network, listens: false)
        for device in [mac, pc, phone] {
            try await device.engine.addText("from \(device.name)")
            try await device.engine.syncOnce()
        }
        // A second round: every device registered, so each one's cache (refreshed below) lists all three.
        for device in [mac, pc, phone] {
            await device.engine.forcePeerDirectoryRefresh()
            try await device.engine.syncOnce()
        }
        return (relay, key, network, mac, pc, phone)
    }

    func relayDown(_ relay: InMemoryRelay, _ devices: [Device]) async {
        await relay.setReachable(false)
        for device in devices { try? await device.engine.syncOnce() }
    }

    // MARK: The guarantee

    func testDevicesSyncDirectlyWhileTheRelayIsDownAndTheRelayCatchesUpAfter() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        let synced: Set = ["from Mac", "from PC", "from iPhone"]
        for device in [mac, pc, phone] { XCTAssertEqual(try device.texts(), synced) }

        await relayDown(relay, [mac, pc, phone])
        for device in [mac, pc, phone] {
            let path = await device.engine.syncPath
            XCTAssertEqual(path, .offline, device.name)
        }
        try await mac.engine.addText("mac offline")
        try await pc.engine.addText("pc offline")
        try await phone.engine.addText("phone offline")
        let pcItem = try XCTUnwrap(try pc.db.items(limit: 10).first { $0.content?.text == "from PC" }?.id)
        try await phone.engine.setPinned(pcItem, true)

        // The iPhone can't listen, so it dials both; the Mac and PC dial each other.
        for _ in 0..<2 {
            for device in [phone, mac, pc] { await device.engine.syncWithPeers() }
        }
        let all = synced.union(["mac offline", "pc offline", "phone offline"])
        for device in [mac, pc, phone] {
            XCTAssertEqual(try device.texts(), all, device.name)
            XCTAssertEqual(try device.db.item(pcItem)?.pinned.value, true, device.name)
            let path = await device.engine.syncPath
            XCTAssertEqual(path, .direct(peers: 2), device.name)
        }

        // The relay comes back: normal sync resumes and the relay gets every op, each once.
        await relay.setReachable(true)
        for device in [mac, pc, phone] { try await device.engine.syncOnce() }
        let path = await mac.engine.syncPath
        XCTAssertEqual(path, .relay)
        let envelopes = await relay.envelopes
        XCTAssertEqual(Set(envelopes.map(\.opID)).count, envelopes.count, "the relay stores each op once")
        let opsOnDevice = try mac.db.ops(afterSeq: 0, limit: 10_000).count
        XCTAssertEqual(envelopes.count, opsOnDevice)
        for device in [mac, pc, phone] {
            XCTAssertEqual(try device.db.pendingOutbound(limit: 1000), [], device.name)
        }
    }

    func testOpsADeviceGotDirectlyReachTheRelayEvenIfTheirAuthorNeverReturns() async throws {
        let (relay, key, network, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        try await phone.engine.addText("only on the phone")
        await phone.engine.syncWithPeers()  // the phone hands it to the Mac and the PC, then is lost
        await relay.setReachable(true)
        try await mac.engine.syncOnce()
        let fresh = try await makeDevice("New Mac", relay: relay, key: key, network: network, listens: false)
        try await fresh.engine.syncOnce()
        XCTAssertTrue(try fresh.texts().contains("only on the phone"))
    }

    func testRepeatedExchangesAddNothing() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        try await phone.engine.addText("once")
        for _ in 0..<5 { await phone.engine.syncWithPeers() }
        let before = try mac.db.ops(afterSeq: 0, limit: 10_000).count
        for _ in 0..<5 {
            await phone.engine.syncWithPeers()
            await mac.engine.syncWithPeers()
        }
        XCTAssertEqual(try mac.db.ops(afterSeq: 0, limit: 10_000).count, before)
        XCTAssertEqual(try mac.texts().filter { $0 == "once" }.count, 1)
    }

    func testLargeBacklogPagesAcrossRounds() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        for i in 0..<1_200 { try await phone.engine.addText("bulk \(i)") }
        await phone.engine.syncWithPeers()
        XCTAssertEqual(try mac.db.count(), 1_203)
        await pc.engine.syncWithPeers()  // the PC pulls it from the Mac's log, in pages
        XCTAssertEqual(try pc.db.count(), 1_203)
    }

    func testAResponderWhoseLogChangedIsResyncedFromScratch() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        await phone.engine.syncWithPeers()
        // The Mac's log ID changes (a new database answering as the same device): the phone's cursors into it are
        // meaningless, so it starts over from 0 both ways.
        try mac.db.setMeta("log_id", "replaced")
        try await phone.engine.addText("after the change")
        await phone.engine.syncWithPeers()
        XCTAssertTrue(try mac.texts().contains("after the change"))
        let json = try XCTUnwrap(try phone.db.meta(SyncEngine.peerCursorKey(mac.idString)))
        let cursor = try JSONDecoder().decode(PeerCursor.self, from: Data(json.utf8))
        XCTAssertEqual(cursor.logID, "replaced")
        XCTAssertEqual(cursor.pushed, try phone.db.ops(afterSeq: 0, limit: 10_000).last?.seq)
    }

    // MARK: Who may connect

    func testARevokedDeviceCanNeitherDialNorBeDialed() async throws {
        let (relay, _, network, mac, pc, phone) = try await makeVault()
        try await mac.engine.revoke([phone.idString])
        try await pc.engine.syncOnce()  // picks up the new key
        try await mac.engine.syncOnce()
        await mac.engine.forcePeerDirectoryRefresh()
        await pc.engine.forcePeerDirectoryRefresh()
        try await mac.engine.syncOnce()
        try await pc.engine.syncOnce()
        await relay.setReachable(false)

        // The lost phone still has the old key and its old device list.
        try await phone.engine.addText("from the thief")
        let recording = RecordingDialer(network.dialer)
        await phone.engine.enablePeerSync(PeerSetup(dialer: recording))
        let reached = await phone.engine.syncWithPeers()
        XCTAssertEqual(reached, 0)
        for device in [mac, pc] {
            XCTAssertFalse(try device.texts().contains("from the thief"), device.name)
        }
        // Each refusal: the phone isn't in their list any more (and couldn't open a request under the new key).
        for request in recording.requests {
            let answer = await mac.engine.handlePeerRequest(request.request)
            let frame = try JSONDecoder().decode(PeerResponseFrame.self, from: answer)
            XCTAssertNotNil(frame.error)
        }
        // And neither remaining device dials it.
        let macPeers = await mac.engine.peers().map(\.id)
        XCTAssertFalse(macPeers.contains(phone.idString))
        try await mac.engine.addText("after the revoke")
        await mac.engine.syncWithPeers()
        XCTAssertFalse(try phone.texts().contains("after the revoke"))
    }

    func testADeviceOnAnOlderVaultKeyIsRefusedEvenIfListed() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        // The PC still lists the Mac, but the Mac has moved to a new key (it revoked the phone) and the PC hasn't
        // heard yet: their PSKs differ, so neither accepts the other.
        try await mac.engine.revoke([phone.idString])
        await relay.setReachable(false)
        try await pc.engine.addText("pc on the old key")
        let reached = await pc.engine.syncWithPeers()
        XCTAssertEqual(reached, 0)
        XCTAssertFalse(try mac.texts().contains("pc on the old key"))
    }

    func testAStrangerAndATamperedRequestAreRefused() async throws {
        let (relay, key, network, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        // A device with the vault key but no record in the Mac's list (never synced): unknown.
        let stranger = try await makeDevice("Stranger", relay: relay, key: key, network: network, listens: false)
        let macPeerFound = await phone.engine.peers().first { $0.id == mac.idString }
        let macPeer = try XCTUnwrap(macPeerFound)
        do {
            try await stranger.engine.exchange(with: macPeer, dialer: network.dialer)
            XCTFail("a stranger got through")
        } catch PeerSyncError.refused(let refusal) {
            XCTAssertEqual(refusal, .unknownDevice)
        }

        let recording = RecordingDialer(network.dialer)
        await phone.engine.enablePeerSync(PeerSetup(dialer: recording))
        try await phone.engine.addText("x")
        await phone.engine.syncWithPeers()
        let original = try XCTUnwrap(recording.requests.first { "\($0.host):\($0.port)" == macPeer.address })
        var frame = try JSONDecoder().decode(PeerRequestFrame.self, from: original.request)
        frame.sealed[frame.sealed.count - 1] ^= 1
        let answer = await mac.engine.handlePeerRequest(try JSONEncoder().encode(frame))
        XCTAssertEqual(try JSONDecoder().decode(PeerResponseFrame.self, from: answer).error, .unauthenticated)

        // Claiming to be the PC with the phone's request: the sender key doesn't match.
        var spoofed = try JSONDecoder().decode(PeerRequestFrame.self, from: original.request)
        spoofed.from = pc.idString
        let spoofAnswer = await mac.engine.handlePeerRequest(try JSONEncoder().encode(spoofed))
        XCTAssertEqual(try JSONDecoder().decode(PeerResponseFrame.self, from: spoofAnswer).error, .unauthenticated)
    }

    func testAReplayedRequestIsRefused() async throws {
        let (relay, _, network, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        let recording = RecordingDialer(network.dialer)
        await phone.engine.enablePeerSync(PeerSetup(dialer: recording))
        await phone.engine.syncWithPeers()
        let macAddress = try XCTUnwrap(mac.listener?.boundAddress)
        let request = try XCTUnwrap(recording.requests.first { "\($0.host):\($0.port)" == macAddress }).request
        let answer = await mac.engine.handlePeerRequest(request)
        XCTAssertEqual(try JSONDecoder().decode(PeerResponseFrame.self, from: answer).error, .replay)
    }

    func testARequestOutsideTheClockWindowIsRefused() async throws {
        let (relay, key, network, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        // The same phone (same database and device key) with its clock 10 minutes behind.
        let slow = try await makeDevice(
            "iPhone", relay: relay, key: key, network: network, listens: false, store: phone.store,
            db: phone.db, id: phone.id, now: { Date().addingTimeInterval(-600) })
        let macPeerFound = await slow.engine.peers().first { $0.id == mac.idString }
        let macPeer = try XCTUnwrap(macPeerFound)
        do {
            try await slow.engine.exchange(with: macPeer, dialer: network.dialer)
            XCTFail("a request from 10 minutes ago got through")
        } catch PeerSyncError.refused(let refusal) {
            XCTAssertEqual(refusal, .clockSkew)
        }
    }

    /// A frame from `device` to `peer`, sealed for real, with whatever request a test wants.
    func frame(_ request: PeerRequest, from device: Device, to peer: Device, key: VaultKey) throws -> Data {
        let sealed = try PeerChannel.sealRequest(
            try JSONEncoder().encode(request), from: device.idString, to: peer.idString,
            deviceKey: try XCTUnwrap(try device.store.loadDeviceKey()),
            recipient: try XCTUnwrap(try peer.store.loadDeviceKey()).publicKey, vaultKey: key)
        return try JSONEncoder().encode(PeerRequestFrame(
            from: device.idString, to: peer.idString, enc: sealed.encapsulatedKey, sealed: sealed.ciphertext))
    }

    func testAnExtremeTimestampIsRefusedNotACrash() async throws {
        let (relay, key, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        for sentAt in [Int64.min, Int64.max, 0] {
            let request = PeerRequest(sentAtMillis: sentAt, envelopes: [], logID: nil, after: 0, limit: 10)
            let answer = await mac.engine.handlePeerRequest(try frame(request, from: phone, to: mac, key: key))
            XCTAssertEqual(try JSONDecoder().decode(PeerResponseFrame.self, from: answer).error, .clockSkew)
        }
    }

    func testARestoredLogWithTheSameIDIsExchangedAgain() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        await phone.engine.syncWithPeers()
        // Pretend the Mac's log was longer before (a backup restored it): the phone's cursor is past its end.
        let json = try XCTUnwrap(try phone.db.meta(SyncEngine.peerCursorKey(mac.idString)))
        var cursor = try JSONDecoder().decode(PeerCursor.self, from: Data(json.utf8))
        cursor.pulled += 1_000
        cursor.pushed += 1_000
        try phone.db.setMeta(
            SyncEngine.peerCursorKey(mac.idString), String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self))
        try await mac.engine.addText("written after the restore")
        try await phone.engine.addText("phone after the restore")
        await phone.engine.syncWithPeers()
        XCTAssertTrue(try phone.texts().contains("written after the restore"))
        XCTAssertTrue(try mac.texts().contains("phone after the restore"))
    }

    /// A member answering with seqs past its own log (or not climbing) can't park the dialer's cursor.
    func testAResponseWithSeqsOutsideTheLogIsRejected() async throws {
        let (relay, key, _, mac, pc, phone) = try await makeVault()
        await relayDown(relay, [mac, pc, phone])
        let macKey = try XCTUnwrap(try mac.store.loadDeviceKey())
        let phoneKey = try XCTUnwrap(try phone.store.loadDeviceKey())
        let op = Op(itemID: ItemID(), timestamp: HLCTimestamp(wallMillis: 1, counter: 0, device: mac.id),
                    kind: .setPinned(true))
        var envelope = try OpCipher(vaultKey: key).seal(op, device: mac.id)

        /// Opens the phone's request as the Mac would, then answers with `seq` and `latestSeq` of its choosing.
        struct Liar: PeerDialer {
            let macKey: DeviceKey, phoneKey: Data, key: VaultKey, from: String, to: String
            let envelope: Envelope, latestSeq: Int64
            func exchange(host: String, port: Int, request: Data, timeout: Duration) async throws -> Data {
                let frame = try JSONDecoder().decode(PeerRequestFrame.self, from: request)
                let opened = try PeerChannel.openRequest(
                    encapsulatedKey: frame.enc, ciphertext: frame.sealed, from: from, to: to, deviceKey: macKey,
                    sender: phoneKey, vaultKey: key)
                let response = PeerResponse(logID: "liar", envelopes: [envelope], hasMore: false, latestSeq: latestSeq)
                return try JSONEncoder().encode(PeerResponseFrame(
                    sealed: try opened.responseKey.seal(try JSONEncoder().encode(response))))
            }
        }
        let macPeerFound = await phone.engine.peers().first { $0.id == mac.idString }
        let macPeer = try XCTUnwrap(macPeerFound)
        for (seq, latest) in [(Int64.max, Int64(5)), (Int64(0), Int64(5)), (Int64(-3), Int64(5))] {
            envelope.seq = seq
            let liar = Liar(macKey: macKey, phoneKey: phoneKey.publicKey, key: key, from: phone.idString,
                            to: mac.idString, envelope: envelope, latestSeq: latest)
            do {
                try await phone.engine.exchange(with: macPeer, dialer: liar)
                XCTFail("accepted seq \(seq)")
            } catch PeerSyncError.badResponse {}
            XCTAssertNil(try phone.db.item(op.itemID), "nothing from a bad page is stored")
        }
    }

    func testOnlyTailnetAddressesAreDialed() async throws {
        let (_, _, _, mac, _, _) = try await makeVault()
        for host in ["192.168.1.10", "10.0.0.1", "127.0.0.1", "8.8.8.8"] {
            let dialable = await mac.engine.isDialable(host)
            XCTAssertFalse(dialable, host)
        }
        let tailnet = await mac.engine.isDialable("100.100.1.2")
        XCTAssertTrue(tailnet)
    }

    func testResponsesDoNotOpenForAnotherRequest() throws {
        let key = VaultKey.generate()
        let a = DeviceKey.generate(), b = DeviceKey.generate()
        let first = try PeerChannel.sealRequest(Data("1".utf8), from: "A", to: "B", deviceKey: a, recipient: b.publicKey, vaultKey: key)
        let second = try PeerChannel.sealRequest(Data("2".utf8), from: "A", to: "B", deviceKey: a, recipient: b.publicKey, vaultKey: key)
        let opened = try PeerChannel.openRequest(
            encapsulatedKey: first.encapsulatedKey, ciphertext: first.ciphertext, from: "A", to: "B", deviceKey: b,
            sender: a.publicKey, vaultKey: key)
        let response = try opened.responseKey.seal(Data("answer".utf8))
        XCTAssertEqual(try first.responseKey.open(response), Data("answer".utf8))
        XCTAssertThrowsError(try second.responseKey.open(response))
    }

    // MARK: Discovery

    func testListenersAdvertiseTheirAddressSealedAndARevokeKeepsIt() async throws {
        let (relay, _, _, mac, pc, phone) = try await makeVault()
        let peers = await phone.engine.peers()
        XCTAssertEqual(Set(peers.compactMap(\.address)), Set([mac.listener!.boundAddress, pc.listener!.boundAddress]))
        XCTAssertNil(peers.first { $0.id == phone.idString })
        // The relay sees only sealed records: the address isn't in the clear.
        let records = await relay.deviceRecords
        for record in records {
            XCTAssertNil(String(data: record.sealed, encoding: .utf8)?.range(of: "100.64"))
        }
        try await mac.engine.revoke([phone.idString])
        try await pc.engine.syncOnce()
        await pc.engine.forcePeerDirectoryRefresh()
        try await pc.engine.syncOnce()
        let pcPeers = await pc.engine.peers()
        XCTAssertEqual(pcPeers.map(\.address), [mac.listener!.boundAddress])
    }
}

extension SyncEngine {
    /// Test hook: the next successful sync re-reads the device list.
    func forcePeerDirectoryRefresh() { peerDirectoryRefreshedAt = nil }
}
