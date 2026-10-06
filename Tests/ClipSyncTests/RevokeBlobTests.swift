import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync

/// F13 x F11/F12: revoking a device when the vault holds images and files. The relay wipes the blobs with the log
/// (they're sealed under the old vault key); the remaining devices re-upload every blob they hold under the new key.
/// The lost device can't fetch anything, and a blob only the lost device had stays thumbnail-only.
final class RevokeBlobTests: XCTestCase {
    struct Device {
        let name: String
        let id: DeviceID
        let engine: SyncEngine
        let db: ClipDatabase
        let cache: BlobCache
    }

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RevokeBlobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func makeDevice(_ name: String, relay: InMemoryRelay, key: VaultKey) throws -> Device {
        let db = try ClipDatabase.inMemory()
        let cache = try BlobCache(directory: try tempDirectory())
        let store = InMemoryKeyStore(key: key, deviceKey: .generate())
        let membership = SyncEngine.Membership(
            deviceKey: try store.loadOrCreateDeviceKey(),
            makeTransport: { relay.client(token: $0) },
            saveVaultKey: { try store.saveVaultKey($0) })
        let id = DeviceID()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: relay.client(token: key.authToken), device: id, deviceName: name,
            log: { _ in }, blobCache: cache, membership: membership)
        return Device(name: name, id: id, engine: engine, db: db, cache: cache)
    }

    /// `bytes` of content that differs per `seed`, so every file is its own blob.
    func makeFile(bytes: Int, seed: UInt8) throws -> URL {
        let url = try tempDirectory().appendingPathComponent("file-\(seed).bin")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }).write(to: url)
        return url
    }

    func blobRef(_ device: Device, _ item: ItemID) throws -> BlobRef {
        try XCTUnwrap(try device.db.item(item)?.content?.blob)
    }

    func testRevokeWipesRelayBlobsAndRemainingDevicesReuploadWhatTheyHold() async throws {
        let oldKey = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: oldKey.authTokenSHA256)
        let mac = try makeDevice("Mac", relay: relay, key: oldKey)
        let pc = try makeDevice("PC", relay: relay, key: oldKey)
        let lost = try makeDevice("Lost iPhone", relay: relay, key: oldKey)

        let macFile = try makeFile(bytes: 1_048_576 + 300, seed: 1)  // two chunks
        let lostFile = try makeFile(bytes: 5000, seed: 2)
        let lostOnlyFile = try makeFile(bytes: 4000, seed: 3)
        let fromMac = try await mac.engine.addFile(at: macFile)
        let fromLost = try await lost.engine.addFile(at: lostFile)
        let lostOnly = try await lost.engine.addFile(at: lostOnlyFile, kind: .image, thumbnail: Data([0xff, 0xd8]))
        for device in [mac, pc, lost] {
            try await device.engine.syncOnce()
            try await device.engine.uploadPendingBlobs()
        }
        for device in [mac, pc, lost] { try await device.engine.syncOnce() }
        // The PC downloads the lost phone's first file, so it holds a copy; nobody but the phone has the second.
        _ = try await pc.engine.fetchBlob(for: fromLost)
        let before = await relay.blobIDs
        XCTAssertEqual(before.count, 3)

        try await mac.engine.revoke([lost.id.rawValue.uuidString])
        let newKey = await mac.engine.currentVaultKey
        let wiped = await relay.blobIDs
        XCTAssertEqual(wiped, [], "the revoke wipes blobs sealed under the old key, with the log")

        // The Mac re-uploads what it holds under the new key.
        try await mac.engine.syncOnce()
        try await mac.engine.uploadPendingBlobs()
        let macRef = try blobRef(mac, fromMac)
        let afterMac = await relay.blobIDs
        XCTAssertEqual(afterMac, [macRef.id.description])

        // The PC hasn't synced since the revoke. A download gets 401, picks up the new key by syncing, and resumes
        // with it; the Mac's file is there under the new key.
        let fetched = try await pc.engine.fetchBlob(for: fromMac)
        XCTAssertEqual(try Data(contentsOf: fetched), try Data(contentsOf: macFile))
        let pcKey = await pc.engine.currentVaultKey
        XCTAssertEqual(pcKey, newKey)
        // The PC re-uploads the copy it downloaded from the lost phone before the revoke.
        try await pc.engine.uploadPendingBlobs()
        let lostRef = try blobRef(pc, fromLost)
        let lostOnlyRef = try blobRef(pc, lostOnly)
        let afterPC = await relay.blobIDs
        XCTAssertEqual(afterPC, [macRef.id.description, lostRef.id.description])

        // Every chunk on the relay opens under the new key and not under the old one.
        let newClient = relay.client(token: newKey.authToken)
        for (ref, item) in [(macRef, fromMac), (lostRef, fromLost)] {
            for index in 0..<ref.chunkCount {
                let sealed = try await XCTUnwrapAsync(try await newClient.blobChunk(blobID: ref.id.description, index: index))
                XCTAssertNoThrow(try BlobCipher(vaultKey: newKey, item: item, blob: ref).open(sealed, index: index))
                XCTAssertThrowsError(try BlobCipher(vaultKey: oldKey, item: item, blob: ref).open(sealed, index: index))
            }
        }

        // The Mac gets the lost phone's file, re-uploaded by the PC; it never had it itself.
        let macCopy = try await mac.engine.fetchBlob(for: fromLost)
        XCTAssertEqual(try Data(contentsOf: macCopy), try Data(contentsOf: lostFile))

        // The file only the lost phone had: the item and its thumbnail survive, the payload is unavailable.
        let thumbnail = try mac.db.item(lostOnly)?.content?.thumbnail
        XCTAssertEqual(thumbnail, Data([0xff, 0xd8]))
        do {
            _ = try await mac.engine.fetchBlob(for: lostOnly)
            XCTFail("a blob nobody remaining holds was downloaded")
        } catch {
            XCTAssertEqual(error as? BlobTransferError, .notUploadedYet(chunk: 0))
        }
        XCTAssertFalse(afterPC.contains(lostOnlyRef.id.description))

        // The lost device can't fetch anything any more, and says it was removed.
        do {
            _ = try await lost.engine.fetchBlob(for: fromMac)
            XCTFail("the revoked device downloaded a file")
        } catch {
            XCTAssertEqual(error as? SyncError, .deviceRevoked)
        }
        XCTAssertFalse(lost.cache.contains(macRef.id))
        // Nor can its old token touch any blob route: no reads, no deletes, and no planting old-key chunks.
        let oldClient = relay.client(token: oldKey.authToken)
        await assertUnauthorized { _ = try await oldClient.blobStatus(blobID: macRef.id.description) }
        await assertUnauthorized { _ = try await oldClient.blobChunk(blobID: macRef.id.description, index: 0) }
        await assertUnauthorized { try await oldClient.deleteBlob(blobID: macRef.id.description) }
        await assertUnauthorized {
            try await oldClient.putBlobChunk(
                blobID: lostOnlyRef.id.description, index: 0, count: 1, data: Data(count: 64))
        }
        let final = await relay.blobIDs
        XCTAssertEqual(final, afterPC)
    }

    /// An upload that started before another device revoked gets 401 part way, stays queued, and finishes under
    /// the new key after the next sync; the relay never keeps the old-key chunks it had accepted.
    func testAnUploadInterruptedByARevokeFinishesUnderTheNewKey() async throws {
        let oldKey = VaultKey.generate()
        let relay = InMemoryRelay()
        await relay.pin(tokenSHA256: oldKey.authTokenSHA256)
        let mac = try makeDevice("Mac", relay: relay, key: oldKey)
        let pc = try makeDevice("PC", relay: relay, key: oldKey)
        let lost = try makeDevice("Lost iPhone", relay: relay, key: oldKey)
        for device in [mac, pc, lost] { try await device.engine.syncOnce() }

        let file = try makeFile(bytes: 2 * 1_048_576 + 10, seed: 4)  // three chunks
        let item = try await pc.engine.addFile(at: file)
        try await pc.engine.syncOnce()
        // One chunk lands under the old key, then the connection drops.
        await relay.failBlobUploads(after: 1)
        do {
            try await pc.engine.uploadPendingBlobs()
            XCTFail("the upload should have been cut off")
        } catch {}
        await relay.healBlobTransfers()

        try await mac.engine.revoke([lost.id.rawValue.uuidString])
        let newKey = await mac.engine.currentVaultKey
        // Still on the old key, the PC's retry is refused; the job stays queued.
        do {
            try await pc.engine.uploadPendingBlobs()
            XCTFail("an old-key upload went through after the revoke")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorized)
        }
        let empty = await relay.blobIDs
        XCTAssertEqual(empty, [])

        try await pc.engine.syncOnce()
        let uploaded = try await pc.engine.uploadPendingBlobs()
        XCTAssertEqual(uploaded, 1)
        let fetched = try await mac.engine.fetchBlob(for: item)
        XCTAssertEqual(try Data(contentsOf: fetched), try Data(contentsOf: file))
        let ref = try XCTUnwrap(try pc.db.item(item)?.content?.blob)
        let sealed = try await XCTUnwrapAsync(
            try await relay.client(token: newKey.authToken).blobChunk(blobID: ref.id.description, index: 0))
        XCTAssertThrowsError(try BlobCipher(vaultKey: oldKey, item: item, blob: ref).open(sealed, index: 0))
    }

    func assertUnauthorized(_ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("the old token got through", line: line)
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorized, line: line)
        }
    }

    func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, line: UInt = #line) async throws -> T {
        let result = try await value()
        return try XCTUnwrap(result, line: line)
    }
}
