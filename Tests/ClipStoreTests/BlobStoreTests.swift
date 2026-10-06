import ClipCore
import Crypto
import Foundation
import XCTest
@testable import ClipStore

/// Blob bookkeeping in ClipDatabase (schema v4) and the on-disk BlobCache (N5, N6, N12).
final class BlobStoreTests: XCTestCase {
    let device = DeviceID()

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BlobStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func ref(_ data: Data, chunkSize: Int = 4, id: BlobID = BlobID()) -> BlobRef {
        BlobRef(id: id, size: Int64(data.count), sha256: Data(SHA256.hash(data: data)), chunkSize: chunkSize,
                contentType: "application/octet-stream")
    }

    func createOp(item: ItemID = ItemID(), blob: BlobRef?, wall: UInt64 = 1) -> Op {
        let content = ItemContent(
            kind: blob == nil ? .text : .file, text: "f.bin", sourceDevice: device, sourceDeviceName: "Test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), blob: blob)
        return Op(itemID: item, timestamp: HLCTimestamp(wallMillis: wall, counter: 0, device: device), kind: .create(content))
    }

    // MARK: ClipDatabase

    func testUploadIsQueuedWithItsCreateOp() throws {
        let db = try ClipDatabase.inMemory()
        let blob = ref(Data("hello".utf8))
        let create = createOp(blob: blob)
        try db.insert([create], outbound: true, blobUploads: [BlobUpload(blob: blob.id, item: create.itemID)])
        XCTAssertEqual(try db.pendingBlobUploads(), [BlobUpload(blob: blob.id, item: create.itemID)])
        XCTAssertEqual(try db.item(create.itemID)?.content?.blob, blob)
        XCTAssertEqual(try db.item(forBlob: blob.id)?.id, create.itemID)
        try db.finishBlobUpload(blob.id)
        XCTAssertEqual(try db.pendingBlobUploads(), [])
    }

    func testLiveAndDeadBlobsFollowVisibility() throws {
        let db = try ClipDatabase.inMemory()
        let kept = ref(Data("a".utf8)), gone = ref(Data("b".utf8))
        let keptOp = createOp(blob: kept, wall: 1), goneOp = createOp(blob: gone, wall: 2)
        let textOp = createOp(blob: nil, wall: 3)
        try db.insert([keptOp, goneOp, textOp], outbound: false)
        XCTAssertEqual(try db.liveBlobIDs(), [kept.id, gone.id])
        XCTAssertEqual(try db.deadBlobIDs(), [])

        let delete = Op(itemID: goneOp.itemID, timestamp: HLCTimestamp(wallMillis: 9, counter: 0, device: device), kind: .delete)
        try db.insert([delete], outbound: false)
        XCTAssertEqual(try db.liveBlobIDs(), [kept.id])
        XCTAssertEqual(try db.deadBlobIDs(), [gone.id])
        XCTAssertEqual(try db.deadBlobIDs(uncollectedOnly: true), [gone.id])
        XCTAssertNil(try db.item(forBlob: gone.id))

        try db.markRelayCollected([gone.id])
        XCTAssertEqual(try db.deadBlobIDs(uncollectedOnly: true), [])
        XCTAssertEqual(try db.deadBlobIDs(), [gone.id])
    }

    /// A delete that arrives before its create (ops can come in any order) still ends with the blob dead.
    func testDeleteBeforeCreateStillMarksBlobDead() throws {
        let db = try ClipDatabase.inMemory()
        let blob = ref(Data("z".utf8))
        let create = createOp(blob: blob)
        let delete = Op(itemID: create.itemID, timestamp: HLCTimestamp(wallMillis: 9, counter: 0, device: device), kind: .delete)
        try db.insert([delete], outbound: false)
        try db.insert([create], outbound: false)
        XCTAssertEqual(try db.deadBlobIDs(), [blob.id])
        XCTAssertEqual(try db.liveBlobIDs(), [])
    }

    func testRelayResetQueuesEveryLiveBlobAgain() throws {
        let db = try ClipDatabase.inMemory()
        let live = ref(Data("a".utf8)), dead = ref(Data("b".utf8))
        let liveOp = createOp(blob: live, wall: 1), deadOp = createOp(blob: dead, wall: 2)
        try db.insert([liveOp, deadOp], outbound: false)
        try db.insert([Op(itemID: deadOp.itemID, timestamp: HLCTimestamp(wallMillis: 5, counter: 0, device: device), kind: .delete)],
                      outbound: false)
        try db.markRelayCollected([dead.id])
        try db.markAllOutbound()
        XCTAssertEqual(try db.pendingBlobUploads(), [BlobUpload(blob: live.id, item: liveOp.itemID)])
        // The new relay never had the dead blob, but asking it to delete again is harmless.
        XCTAssertEqual(try db.deadBlobIDs(uncollectedOnly: true), [dead.id])
    }

    func testRefoldKeepsBlobColumn() throws {
        let db = try ClipDatabase.inMemory()
        let blob = ref(Data("a".utf8))
        try db.insert([createOp(blob: blob)], outbound: false)
        try db.refoldAll()
        XCTAssertEqual(try db.liveBlobIDs(), [blob.id])
    }

    // MARK: BlobCache: import and read

    func testImportHashesAndChunksAreReadable() throws {
        let dir = try tempDirectory()
        let cache = try BlobCache(directory: dir.appendingPathComponent("blobs"))
        let source = dir.appendingPathComponent("source.bin")
        let data = Data((0..<10).map { UInt8($0) })
        try data.write(to: source)
        let id = BlobID()
        let imported = try cache.importFile(at: source, as: id, maxBytes: 100)
        XCTAssertEqual(imported.size, 10)
        XCTAssertEqual(imported.sha256, Data(SHA256.hash(data: data)))
        XCTAssertTrue(cache.contains(id))
        XCTAssertEqual(try cache.readChunk(of: id, index: 2, chunkSize: 4, length: 2), Data([8, 9]))
        XCTAssertThrowsError(try cache.readChunk(of: id, index: 2, chunkSize: 4, length: 4)) {
            XCTAssertEqual($0 as? BlobCacheError, .wrongChunkLength)
        }
        // Nothing but the blob itself is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [id.description])

        let out = dir.appendingPathComponent("out.bin")
        try cache.export(id, to: out)
        XCTAssertEqual(try Data(contentsOf: out), data)
    }

    func testImportRefusesOversizedFileAndLeavesNothing() throws {
        let dir = try tempDirectory()
        let cache = try BlobCache(directory: dir.appendingPathComponent("blobs"))
        let source = dir.appendingPathComponent("big.bin")
        try Data(count: 11).write(to: source)
        let id = BlobID()
        XCTAssertThrowsError(try cache.importFile(at: source, as: id, maxBytes: 10)) {
            XCTAssertEqual($0 as? BlobCacheError, .tooLarge(bytes: 11))
        }
        XCTAssertFalse(cache.contains(id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [])
    }

    // MARK: BlobCache: download, resume, verify

    func testDownloadResumesFromLastWholeChunk() throws {
        let cache = try BlobCache(directory: try tempDirectory())
        let data = Data("0123456789".utf8)
        let blob = ref(data)
        let first = try cache.beginDownload(blob)
        XCTAssertEqual(first.verifiedChunks, 0)
        try first.append(Data("0123".utf8))
        first.close()
        // A crash mid-write left half of chunk 1 on disk.
        let partial = cache.partialURL(for: blob.id)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("45".utf8))
        try handle.close()

        let second = try cache.beginDownload(blob)
        XCTAssertEqual(second.verifiedChunks, 1, "the half chunk is cut off")
        XCTAssertEqual(second.resumedChunks, 1)
        XCTAssertEqual(cache.partialSize(of: blob.id), 4)
        try second.append(Data("4567".utf8))
        try second.append(Data("89".utf8))
        XCTAssertTrue(second.isComplete)
        let url = try second.finish()
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertTrue(cache.contains(blob.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDownloadRejectsWrongChunkLength() throws {
        let cache = try BlobCache(directory: try tempDirectory())
        let download = try cache.beginDownload(ref(Data("0123456789".utf8)))
        XCTAssertThrowsError(try download.append(Data("012".utf8))) {
            XCTAssertEqual($0 as? BlobCacheError, .wrongChunkLength)
        }
    }

    /// N12: a file whose bytes don't hash to the item's SHA-256 never becomes a blob, and the next try starts over.
    func testHashMismatchNeverPublishes() throws {
        let cache = try BlobCache(directory: try tempDirectory())
        let blob = ref(Data("0123456789".utf8))
        let download = try cache.beginDownload(blob)
        try download.append(Data("0123".utf8))
        try download.append(Data("XXXX".utf8))  // right length, wrong bytes (e.g. garbled on disk after a crash)
        try download.append(Data("89".utf8))
        XCTAssertThrowsError(try download.finish()) { XCTAssertEqual($0 as? BlobCacheError, .hashMismatch) }
        XCTAssertFalse(cache.contains(blob.id))
        XCTAssertEqual(try cache.beginDownload(blob).verifiedChunks, 0)
    }

    func testEmptyBlobDownloads() throws {
        let cache = try BlobCache(directory: try tempDirectory())
        let blob = ref(Data())
        let download = try cache.beginDownload(blob)
        XCTAssertEqual(download.verifiedChunks, 0)
        try download.append(Data())
        XCTAssertEqual(try Data(contentsOf: try download.finish()), Data())
    }

    // MARK: BlobCache: garbage collection

    func testGarbageCollectionKeepsLiveRemovesDeadAndOldOrphans() throws {
        let cache = try BlobCache(directory: try tempDirectory())
        let live = BlobID(), dead = BlobID(), freshOrphan = BlobID(), oldOrphan = BlobID()
        for id in [live, dead, freshOrphan, oldOrphan] { _ = try cache.importData(Data("x".utf8), as: id, maxBytes: 10) }
        let deadPartial = try cache.beginDownload(ref(Data("0123456789".utf8), id: BlobID()))
        deadPartial.close()
        let old = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.url(for: oldOrphan).path)
        let staleTemp = cache.directory.appendingPathComponent("tmp-crashed")
        FileManager.default.createFile(atPath: staleTemp.path, contents: Data("half".utf8))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: staleTemp.path)

        let removed = cache.collectGarbage(live: [live], dead: [dead, deadPartial.ref.id], orphanAge: 86_400)
        XCTAssertEqual(removed, 4)
        XCTAssertEqual(cache.storedBlobIDs(), [live, freshOrphan])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemp.path))
    }
}
