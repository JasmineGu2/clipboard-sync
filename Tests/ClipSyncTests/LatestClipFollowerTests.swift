import ClipCore
import ClipCrypto
import ClipStore
import XCTest
@testable import ClipSync

final class LatestClipFollowerTests: XCTestCase {
    let key = VaultKey.generate()

    struct Device {
        let clock: TestClock
        let engine: SyncEngine
        let db: ClipDatabase
        var follower: LatestClipFollower

        /// What the follower would put on the clipboard after this device syncs.
        mutating func sync() async throws -> String? {
            try await engine.syncOnce()
            return follower.update(newest: try db.items(limit: 1).first)?.text
        }
    }

    func makeDevice(_ name: String, relay: InMemoryRelay, at seconds: Double) throws -> Device {
        let id = DeviceID()
        let clock = TestClock(seconds)
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay, device: id, deviceName: name,
            now: { clock.now() }, log: { _ in })
        var follower = LatestClipFollower(device: id)
        _ = follower.update(newest: try db.items(limit: 1).first)  // baseline, like app start
        return Device(clock: clock, engine: engine, db: db, follower: follower)
    }

    func testFirstUpdateIsABaselineAndNeverWrites() throws {
        var follower = LatestClipFollower(device: DeviceID())
        var state = ItemState(id: ItemID())
        state.content = ItemContent(text: "old", sourceDevice: DeviceID(), sourceDeviceName: "PC", createdAt: Date())
        XCTAssertNil(follower.update(newest: state))
        XCTAssertNil(follower.update(newest: state))
    }

    func testANewerCopyFromAnotherDeviceIsWritten() async throws {
        let relay = InMemoryRelay()
        var mac = try makeDevice("Mac", relay: relay, at: 1_000)
        let pc = try makeDevice("PC", relay: relay, at: 2_000)

        _ = try await pc.engine.addText("from the PC")
        try await pc.engine.syncOnce()
        let written = try await mac.sync()
        XCTAssertEqual(written, "from the PC")
        // Syncing again with nothing new writes nothing.
        let again = try await mac.sync()
        XCTAssertNil(again)
    }

    func testALocalCopyIsNeverWrittenBack() async throws {
        var mac = try makeDevice("Mac", relay: InMemoryRelay(), at: 1_000)
        _ = try await mac.engine.addText("copied here")
        let written = try await mac.sync()
        XCTAssertNil(written)
    }

    func testABacklogWritesOnlyTheNewestItem() async throws {
        let relay = InMemoryRelay()
        var mac = try makeDevice("Mac", relay: relay, at: 1_000)
        let pc = try makeDevice("PC", relay: relay, at: 2_000)

        for (offset, text) in ["one", "two", "three"].enumerated() {
            pc.clock.set(2_000 + Double(offset))
            _ = try await pc.engine.addText(text)
        }
        try await pc.engine.syncOnce()
        let written = try await mac.sync()
        XCTAssertEqual(written, "three")
    }

    func testAnOlderRemoteCopyArrivingLateDoesNotReplaceANewerLocalOne() async throws {
        let relay = InMemoryRelay()
        let pc = try makeDevice("PC", relay: relay, at: 1_000)
        var mac = try makeDevice("Mac", relay: relay, at: 2_000)

        _ = try await pc.engine.addText("older, from the PC")  // made offline, pushed later
        _ = try await mac.engine.addText("newer, on the Mac")
        let first = try await mac.sync()
        XCTAssertNil(first)
        try await pc.engine.syncOnce()
        let second = try await mac.sync()
        XCTAssertNil(second)
    }

    func testDeletingTheNewestItemDoesNotWriteTheOneBeforeIt() async throws {
        let relay = InMemoryRelay()
        var mac = try makeDevice("Mac", relay: relay, at: 1_000)
        let pc = try makeDevice("PC", relay: relay, at: 2_000)

        _ = try await pc.engine.addText("older, from the PC")
        pc.clock.set(2_001)
        let newer = try await pc.engine.addText("newer, from the PC")
        try await pc.engine.syncOnce()
        let first = try await mac.sync()
        XCTAssertEqual(first, "newer, from the PC")

        try await pc.engine.delete(newer)
        try await pc.engine.syncOnce()
        let second = try await mac.sync()
        XCTAssertNil(second)
    }

    func testEditingTheNewestRemoteItemDoesNotWriteItAgain() async throws {
        let relay = InMemoryRelay()
        var mac = try makeDevice("Mac", relay: relay, at: 1_000)
        let pc = try makeDevice("PC", relay: relay, at: 2_000)

        let item = try await pc.engine.addText("from the PC")
        try await pc.engine.syncOnce()
        let first = try await mac.sync()
        XCTAssertEqual(first, "from the PC")

        try await pc.engine.setPinned(item, true)
        try await pc.engine.setTitle(item, "Renamed")
        try await pc.engine.syncOnce()
        let second = try await mac.sync()
        XCTAssertNil(second)
    }
}
