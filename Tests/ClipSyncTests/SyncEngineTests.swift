import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync

/// A clock tests can move. Whole seconds, so dates survive JSON round trips exactly.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double

    init(_ seconds: Double = 1_700_000_000) { self.seconds = seconds }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: seconds)
    }

    func set(_ value: Double) {
        lock.lock()
        seconds = value
        lock.unlock()
    }
}

final class SyncEngineTests: XCTestCase {
    let key = VaultKey.generate()

    struct Peer {
        let engine: SyncEngine
        let db: ClipDatabase
    }

    func makePeer(_ name: String, relay: InMemoryRelay, clock: TestClock = TestClock()) throws -> Peer {
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: DeviceID(), deviceName: name,
            now: { clock.now() }, log: { _ in }
        )
        return Peer(engine: engine, db: db)
    }

    func allStates(_ db: ClipDatabase) throws -> [ItemState] {
        try db.items(limit: 10_000)
    }

    // MARK: Convergence

    func testTwoDevicesConvergeAfterAddPinTagDelete() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)

        let first = try await a.engine.addText("hello")
        let second = try await a.engine.addText("world")
        try await a.engine.setPinned(first, true)
        try await a.engine.setTag(first, "work", present: true)
        try await a.engine.setTitle(first, "Greeting")
        try await a.engine.delete(second)
        try await a.engine.syncOnce()
        try await b.engine.syncOnce()

        let item = try XCTUnwrap(try b.db.item(first))
        XCTAssertEqual(item.content?.text, "hello")
        XCTAssertTrue(item.pinned.value)
        XCTAssertEqual(item.visibleTags, ["work"])
        XCTAssertEqual(item.title.value, "Greeting")
        XCTAssertEqual(try b.db.item(second)?.deleted, true)
        XCTAssertEqual(try allStates(a.db), try allStates(b.db))

        // And back the other way.
        try await b.engine.setTag(first, "work", present: false)
        try await b.engine.syncOnce()
        try await a.engine.syncOnce()
        XCTAssertEqual(try a.db.item(first)?.visibleTags, [])
        XCTAssertEqual(try allStates(a.db), try allStates(b.db))
        let cursorA = try a.db.syncCursor()
        let latest = await relay.latestSeq
        XCTAssertEqual(cursorA, latest)
    }

    func testConcurrentEditsConverge() async throws {
        let relay = InMemoryRelay()
        let clockA = TestClock(1_700_000_000)
        let clockB = TestClock(1_700_000_000)
        let a = try makePeer("A", relay: relay, clock: clockA)
        let b = try makePeer("B", relay: relay, clock: clockB)

        let item = try await a.engine.addText("shared")
        try await a.engine.syncOnce()
        try await b.engine.syncOnce()

        // Both edit the same fields offline, B with a clock that runs behind.
        clockB.set(1_699_999_000)
        try await a.engine.setPinned(item, true)
        try await b.engine.setPinned(item, false)
        try await a.engine.setTitle(item, "from A")
        try await b.engine.setTitle(item, "from B")
        try await b.engine.setTag(item, "x", present: true)
        try await a.engine.delete(item)
        _ = try await b.engine.addText("only on B")

        try await a.engine.syncOnce()
        try await b.engine.syncOnce()
        try await a.engine.syncOnce()

        let stateA = try XCTUnwrap(try a.db.item(item))
        let stateB = try XCTUnwrap(try b.db.item(item))
        XCTAssertEqual(stateA, stateB)
        XCTAssertTrue(stateA.deleted)
        XCTAssertEqual(try allStates(a.db), try allStates(b.db))
        XCTAssertEqual(try a.db.items().map { $0.content?.text }, ["only on B"])
    }

    // MARK: Failure handling

    func testRepushAfterLostResponseIsIdempotent() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)
        _ = try await a.engine.addText("once")

        await relay.loseNextPushResponses(1)
        do {
            try await a.engine.syncOnce()
            XCTFail("expected the simulated lost response")
        } catch {
            XCTAssertEqual(error as? TransportError, .network("simulated lost response"))
        }
        let status = await a.engine.status
        XCTAssertEqual(status, .offline(lastError: "network error: simulated lost response"))
        XCTAssertEqual(try a.db.pendingOutbound().count, 1, "not marked sent without a response")

        try await a.engine.syncOnce()
        let count = await relay.envelopes.count
        XCTAssertEqual(count, 1, "the relay deduped the retry")
        XCTAssertEqual(try a.db.pendingOutbound().count, 0)
        let statusAfter = await a.engine.status
        XCTAssertEqual(statusAfter, .idle)

        try await b.engine.syncOnce()
        XCTAssertEqual(try b.db.items().map { $0.content?.text }, ["once"])
    }

    func testPoisonedEnvelopeIsSkippedAndSyncContinues() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)

        _ = try await a.engine.addText("before")
        try await a.engine.syncOnce()
        let poison = Envelope(
            opID: UUID().uuidString, itemID: UUID().uuidString, deviceID: UUID().uuidString,
            ciphertext: Data(repeating: 0xAB, count: 64))
        await relay.inject([poison])
        _ = try await a.engine.addText("after")
        try await a.engine.syncOnce()

        try await b.engine.syncOnce()
        XCTAssertEqual(Set(try b.db.items().compactMap { $0.content?.text }), ["before", "after"])
        let latest = await relay.latestSeq
        XCTAssertEqual(try b.db.syncCursor(), latest)
        let skipped = try await b.engine.undecryptableOpIDs()
        XCTAssertEqual(skipped, [poison.opID])
    }

    func testPullFailureSetsOfflineThenRecovers() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        await relay.failNextPulls(1)
        do {
            try await a.engine.syncOnce()
            XCTFail("expected failure")
        } catch {}
        try await a.engine.syncOnce()
        let synced = await a.engine.lastSyncedAt
        XCTAssertNotNil(synced)
    }

    // MARK: Paging and batching

    func testPagingManyOps() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)
        for index in 0..<1200 { _ = try await a.engine.addText("clip \(index)") }

        try await a.engine.syncOnce()
        let sizes = await relay.pushSizes
        XCTAssertEqual(sizes, [500, 500, 200])

        try await b.engine.syncOnce()
        XCTAssertEqual(try b.db.count(), 1200)
        XCTAssertEqual(try b.db.syncCursor(), 1200)
        XCTAssertEqual(try a.db.syncCursor(), 1200)
    }

    func testPushSplitsByBodySize() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)
        // ~200 KB each: about 270 KB per envelope in base64, so 4 MB holds ~15.
        for index in 0..<30 {
            _ = try await a.engine.addText(String(repeating: "\(index % 10)", count: 200_000))
        }
        try await a.engine.syncOnce()
        let sizes = await relay.pushSizes
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertEqual(sizes.reduce(0, +), 30)
        try await b.engine.syncOnce()
        XCTAssertEqual(try b.db.count(), 30)
    }

    func testBatchesRespectCountAndBytes() throws {
        let envelope = Envelope(opID: "o", itemID: "i", deviceID: "d", ciphertext: Data(count: 1000))
        let byCount = try SyncEngine.batches(Array(repeating: envelope, count: 7), maxCount: 3)
        XCTAssertEqual(byCount.map(\.count), [3, 3, 1])
        let bySize = try SyncEngine.batches(Array(repeating: envelope, count: 5), maxBytes: 3000)
        XCTAssertEqual(bySize.map(\.count), [2, 2, 1])
        for batch in bySize {
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(PushRequest(envelopes: batch)).count, 3000)
        }
    }

    func testOversizedOpIsRejectedLocally() async throws {
        let a = try makePeer("A", relay: InMemoryRelay())
        do {
            _ = try await a.engine.addText(String(repeating: "x", count: WireLimits.maxCiphertextBytes))
            XCTFail("expected opTooLarge")
        } catch let error as SyncError {
            guard case .opTooLarge = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try a.db.pendingOutbound().count, 0)
    }

    // MARK: Local behavior

    func testRepeatedClipboardTextIsDeduped() async throws {
        let a = try makePeer("A", relay: InMemoryRelay())
        let first = try await a.engine.addText("same")
        let again = try await a.engine.addText("same")
        XCTAssertEqual(first, again)
        XCTAssertEqual(try a.db.count(), 1)

        _ = try await a.engine.addText("other")
        let third = try await a.engine.addText("same")
        XCTAssertNotEqual(third, first, "only the newest item is compared")
        XCTAssertEqual(try a.db.count(), 3)
    }

    func testEmptyTextIsRejected() async throws {
        let a = try makePeer("A", relay: InMemoryRelay())
        for text in ["", "   ", "\n\t "] {
            do {
                _ = try await a.engine.addText(text)
                XCTFail("expected emptyText for \(text.debugDescription)")
            } catch {
                XCTAssertEqual(error as? SyncError, .emptyText)
            }
        }
        XCTAssertEqual(try a.db.count(), 0)
    }

    func testChangesFireOnLocalRecord() async throws {
        let a = try makePeer("A", relay: InMemoryRelay())
        var iterator = a.engine.changes.makeAsyncIterator()
        _ = try await a.engine.addText("ping")
        let fired: Void? = await iterator.next()
        XCTAssertNotNil(fired)
    }

    func testClockDoesNotGoBackwardsAcrossRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("clips.sqlite").path
        let device = DeviceID()
        let relay = InMemoryRelay()

        let clock = TestClock(1_700_000_100)
        var db = try ClipDatabase(path: path)
        var engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: device, deviceName: "A",
            now: { clock.now() }, log: { _ in })
        let item = try await engine.addText("one")
        try await engine.setPinned(item, true)
        let before = try XCTUnwrap(try db.item(item)?.pinned.timestamp)
        db.close()

        // Restart with the wall clock an hour behind.
        clock.set(1_700_000_100 - 3600)
        db = try ClipDatabase(path: path)
        engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: device, deviceName: "A",
            now: { clock.now() }, log: { _ in })
        try await engine.setPinned(item, false)
        let after = try XCTUnwrap(try db.item(item)?.pinned.timestamp)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(try db.item(item)?.pinned.value, false, "the newer local edit wins")
        db.close()
    }

    func testClockPersistsObservedRemoteTimestamps() async throws {
        let relay = InMemoryRelay()
        // 30 minutes ahead: within HybridClock.maxForwardSkewMillis, so B must follow it (further skew is clamped).
        let ahead = try makePeer("Ahead", relay: relay, clock: TestClock(1_700_001_800))
        let item = try await ahead.engine.addText("from the future")
        try await ahead.engine.syncOnce()

        let db = try ClipDatabase.inMemory()
        let device = DeviceID()
        let clock = TestClock(1_700_000_000)
        var engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: device, deviceName: "B",
            now: { clock.now() }, log: { _ in })
        try await engine.syncOnce()
        engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: device, deviceName: "B",
            now: { clock.now() }, log: { _ in })
        try await engine.setTitle(item, "renamed")
        let title = try XCTUnwrap(try db.item(item)?.title)
        XCTAssertEqual(title.value, "renamed")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(title.timestamp).wallMillis, 1_700_001_800_000)
    }

    // MARK: Run loop

    func testRunDeliversRemoteChangeViaLongPoll() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let b = try makePeer("B", relay: relay)
        let changed = Flag()
        let watcher = Task {
            for await _ in b.engine.changes {
                await changed.set()
                break
            }
        }
        let runner = Task { await b.engine.run() }
        defer {
            runner.cancel()
            watcher.cancel()
        }
        try await Task.sleep(for: .milliseconds(200))  // let B settle into its long-poll

        let start = ContinuousClock.now
        _ = try await a.engine.addText("live")
        try await a.engine.syncOnce()
        try await waitUntil(timeout: .seconds(1)) { try b.db.count() == 1 }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        try await waitUntil(timeout: .seconds(1)) { await changed.value }

        runner.cancel()
        await runner.value  // run() returns promptly on cancellation, mid long-poll
    }

    func testRunPushesLocalOpImmediately() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        let runner = Task { await a.engine.run() }
        defer { runner.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        _ = try await a.engine.addText("push me")
        try await waitUntil(timeout: .seconds(1)) { await relay.envelopes.count == 1 }
        runner.cancel()
        await runner.value
    }

    func testRunRecoversAfterFailures() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", relay: relay)
        _ = try await a.engine.addText("eventually")
        await relay.failNextPushes(2)
        let runner = Task { await a.engine.run() }
        defer { runner.cancel() }
        // Backoff: up to 0.5 s, then up to 1 s.
        try await waitUntil(timeout: .seconds(4)) { await relay.envelopes.count == 1 }
        runner.cancel()
        await runner.value
    }

    func testBackoffDoublesToThirtySeconds() {
        let top: (ClosedRange<Double>) -> Double = { $0.upperBound }
        let bottom: (ClosedRange<Double>) -> Double = { $0.lowerBound }
        XCTAssertEqual(SyncEngine.backoff(failures: 1, random: top), 0.5)
        XCTAssertEqual(SyncEngine.backoff(failures: 2, random: top), 1)
        XCTAssertEqual(SyncEngine.backoff(failures: 4, random: top), 4)
        XCTAssertEqual(SyncEngine.backoff(failures: 20, random: top), 30)
        XCTAssertEqual(SyncEngine.backoff(failures: 20, random: bottom), 15)
    }

    // MARK: Relay reset

    func testRelayResetResetsCursorAndRepulls() async throws {
        let oldRelay = InMemoryRelay()
        let a = try makePeer("A", relay: oldRelay)
        let b = try makePeer("B", relay: oldRelay)
        let early = try await a.engine.addText("before reset")
        _ = try await a.engine.addText("also before")
        _ = try await a.engine.addText("and this")
        try await a.engine.syncOnce()
        try await b.engine.syncOnce()
        XCTAssertEqual(try a.db.syncCursor(), 3)
        XCTAssertEqual(try b.db.syncCursor(), 3)

        // The relay is replaced by an empty one; both devices keep their databases and cursors.
        let newRelay = InMemoryRelay()
        do {
            _ = try await newRelay.pull(after: 3, limit: 10, wait: 0)
            XCTFail("expected cursorAhead")
        } catch {
            XCTAssertEqual(error as? TransportError, .cursorAhead(latestSeq: 0))
        }
        let a2 = try SyncEngine(db: a.db, vaultKey: key, transport: newRelay, device: DeviceID(), deviceName: "A",
                                log: { _ in })
        let b2 = try SyncEngine(db: b.db, vaultKey: key, transport: newRelay, device: DeviceID(), deviceName: "B",
                                log: { _ in })

        // Empty relay: A resets to 0 and finds nothing, without failing.
        try await a2.syncOnce()
        XCTAssertEqual(try a.db.syncCursor(), 0)
        let aStatus = await a2.status
        XCTAssertEqual(aStatus, .idle)

        // B writes to the new relay; its own cursor (3) is ahead of the new log (1) too.
        let late = try await b2.addText("after reset")
        try await b2.syncOnce()
        XCTAssertEqual(try b.db.syncCursor(), 1)
        try await a2.syncOnce()
        XCTAssertEqual(try a.db.syncCursor(), 1)
        XCTAssertEqual(try a.db.item(late)?.content?.text, "after reset")
        XCTAssertEqual(try a.db.item(early)?.content?.text, "before reset")
        XCTAssertEqual(try allStates(a.db), try allStates(b.db))
    }

    func testRelayRejectsControlCharactersInIDs() async throws {
        let relay = InMemoryRelay()
        for bad in ["op\u{0}x", "op\nx", "op\u{7f}", "op\u{85}"] {
            let envelope = Envelope(opID: bad, itemID: "item", deviceID: "dev", ciphertext: Data([1]))
            do {
                _ = try await relay.push(PushRequest(envelopes: [envelope]))
                XCTFail("expected badRequest for \(bad.debugDescription)")
            } catch {
                guard case .badRequest = error as? TransportError else {
                    return XCTFail("expected badRequest, got \(error)")
                }
            }
        }
        XCTAssertTrue(WireLimits.isValidID("op-1 é"))
        XCTAssertFalse(WireLimits.isValidID(""))
        XCTAssertFalse(WireLimits.isValidID(String(repeating: "x", count: WireLimits.maxIDBytes + 1)))
    }

    // MARK: Pairing

    func testPairingRoundTrip() async throws {
        let relay = InMemoryRelay()
        let code = try await SyncEngine.startPairing(vaultKey: key, transport: relay)
        // Typed loosely by a user: lower case and spaces.
        let typed = code.display.lowercased().replacingOccurrences(of: "-", with: " ")
        let received = try await SyncEngine.completePairing(code: typed, transport: relay)
        XCTAssertEqual(received, key)

        do {
            _ = try await SyncEngine.completePairing(code: code.display, transport: relay)
            XCTFail("a code works once")
        } catch {
            XCTAssertEqual(error as? SyncError, .pairingNotFound)
        }
    }

    func testWrongOrMalformedPairingCodeFails() async throws {
        let relay = InMemoryRelay()
        _ = try await SyncEngine.startPairing(vaultKey: key, transport: relay)
        do {
            _ = try await SyncEngine.completePairing(code: PairingCode.generate().display, transport: relay)
            XCTFail("expected pairingNotFound")
        } catch {
            XCTAssertEqual(error as? SyncError, .pairingNotFound)
        }
        do {
            _ = try await SyncEngine.completePairing(code: "not a code", transport: relay)
            XCTFail("expected invalidPairingCode")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidPairingCode)
        }
    }

    func testPairingIDCannotBeOverwrittenAndTableIsCapped() async throws {
        let relay = InMemoryRelay()
        let id = "0123456789abcdef0123456789abcdef"
        try await relay.putPairing(id: id, blob: Data([1]))
        do {
            try await relay.putPairing(id: id, blob: Data([2]))
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? TransportError, .conflict)
        }
        let taken = try await relay.takePairing(id: id)
        XCTAssertEqual(taken, Data([1]))

        for n in 0..<WireLimits.maxLivePairings {
            try await relay.putPairing(id: String(format: "%032x", n), blob: Data([1]))
        }
        do {
            try await relay.putPairing(id: String(repeating: "f", count: 32), blob: Data([1]))
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? TransportError, .rateLimited)
        }
    }

    func testExpiredPairingCodeFails() async throws {
        let clock = TestClock()
        let relay = InMemoryRelay(now: { clock.now() })
        let code = try await SyncEngine.startPairing(vaultKey: key, transport: relay)
        clock.set(1_700_000_000 + 11 * 60)
        do {
            _ = try await SyncEngine.completePairing(code: code.display, transport: relay)
            XCTFail("expected pairingNotFound")
        } catch {
            XCTAssertEqual(error as? SyncError, .pairingNotFound)
        }
    }

    // MARK: Helpers

    func waitUntil(
        timeout: Duration, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if try await condition() { return }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}
