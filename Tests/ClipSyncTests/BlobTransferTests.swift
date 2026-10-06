import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Crypto
import Foundation
import XCTest
@testable import ClipSync
#if canImport(Darwin)
import Darwin
#endif

/// Images and files end to end through SyncEngine (F11, F12): upload, download, resume (N5), bounded memory (N6),
/// tamper detection (N8), hash check before publishing (N12) and garbage collection.
final class BlobTransferTests: XCTestCase {
    let key = VaultKey.generate()

    struct Peer {
        let engine: SyncEngine
        let db: ClipDatabase
        let cache: BlobCache
    }

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BlobTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func makePeer(_ name: String, transport: any SyncTransport, meter: TransferMeter = TransferMeter()) throws -> Peer {
        let db = try ClipDatabase.inMemory()
        let cache = try BlobCache(directory: try tempDirectory())
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: transport, device: DeviceID(), deviceName: name, log: { _ in },
            blobCache: cache, transferMeter: meter)
        return Peer(engine: engine, db: db, cache: cache)
    }

    /// Writes `bytes` of varied content, 1 MiB at a time.
    func makeFile(bytes: Int, seed: UInt8 = 1) throws -> URL {
        let url = try tempDirectory().appendingPathComponent("file-\(seed).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // One patterned 1 MiB block, with the block number stamped at its start so no two chunks are equal.
        var base = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        var written = 0
        var block: UInt64 = 0
        while written < bytes {
            let count = min(1 << 20, bytes - written)
            withUnsafeBytes(of: block.bigEndian) { base.replaceSubrange(0..<8, with: $0) }
            try withAutoreleasePool { try handle.write(contentsOf: base.prefix(count)) }
            written += count
            block += 1
        }
        return url
    }

    func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try withAutoreleasePool({
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return Data(hasher.finalize())
    }

    // MARK: Round trip

    func testImageSyncsWithThumbnailAndDownloadsOnDemand() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let file = try makeFile(bytes: 2_500_000)
        let thumbnail = Data(repeating: 0xff, count: 2_000)
        let item = try await a.engine.addFile(at: file, kind: .image, contentType: "image/png", thumbnail: thumbnail)
        try await a.engine.syncOnce()
        let awaited1 = try await a.engine.uploadPendingBlobs()
        XCTAssertEqual(awaited1, 1)
        XCTAssertEqual(try a.db.pendingBlobUploads(), [])

        try await b.engine.syncOnce()
        let state = try XCTUnwrap(try b.db.item(item))
        XCTAssertEqual(state.content?.kind, .image)
        XCTAssertEqual(state.content?.text, file.lastPathComponent)
        XCTAssertEqual(state.content?.thumbnail, thumbnail, "the thumbnail arrives with the item")
        XCTAssertEqual(state.content?.blob?.chunkCount, 3)
        let awaited2 = try await b.engine.localFile(for: item)
        XCTAssertNil(awaited2, "the full image waits until asked for")

        let url = try await b.engine.fetchBlob(for: item)
        XCTAssertEqual(try sha256(of: url), try sha256(of: file))
        let awaited3 = try await b.engine.localFile(for: item)
        XCTAssertEqual(awaited3, url)
        // A second fetch is served from the cache.
        let gets = await relay.blobGetCount
        _ = try await b.engine.fetchBlob(for: item)
        let awaited4 = await relay.blobGetCount
        XCTAssertEqual(awaited4, gets)
    }

    func testOversizedThumbnailIsDroppedNotFatal() async throws {
        let a = try makePeer("A", transport: InMemoryRelay())
        let item = try await a.engine.addFile(
            at: try makeFile(bytes: 10), kind: .image, thumbnail: Data(count: ItemContent.maxThumbnailBytes + 1))
        XCTAssertNil(try a.db.item(item)?.content?.thumbnail)
        XCTAssertNotNil(try a.db.item(item)?.content?.blob)
    }

    func testSameFileTwiceInARowIsOneItem() async throws {
        let a = try makePeer("A", transport: InMemoryRelay())
        let file = try makeFile(bytes: 100)
        let first = try await a.engine.addFile(at: file)
        let second = try await a.engine.addFile(at: file)
        XCTAssertEqual(first, second)
        XCTAssertEqual(a.cache.storedBlobIDs().count, 1)
    }

    func testEmptyFileSyncs() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let item = try await a.engine.addFile(at: try makeFile(bytes: 0))
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()
        let awaited5 = try await b.engine.fetchBlob(for: item)
        XCTAssertEqual(try Data(contentsOf: awaited5), Data())
    }

    func testFetchBeforeUploadSaysNotYet() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let item = try await a.engine.addFile(at: try makeFile(bytes: 100))
        try await a.engine.syncOnce()  // the op goes out, the blob hasn't yet
        try await b.engine.syncOnce()
        do {
            _ = try await b.engine.fetchBlob(for: item)
            XCTFail("expected notUploadedYet")
        } catch {
            XCTAssertEqual(error as? BlobTransferError, .notUploadedYet(chunk: 0))
        }
    }

    func testTextEngineWithoutCacheRefusesFiles() async throws {
        let engine = try SyncEngine(db: .inMemory(), vaultKey: key, transport: InMemoryRelay(), device: DeviceID(),
                                    deviceName: "T", log: { _ in })
        do {
            _ = try await engine.addFile(at: try makeFile(bytes: 1))
            XCTFail("expected blobsUnavailable")
        } catch {
            XCTAssertEqual(error as? SyncError, .blobsUnavailable)
        }
    }

    // MARK: Resume (N5)

    func testInterruptedUploadResumesFromWhatTheRelayHas() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let item = try await a.engine.addFile(at: try makeFile(bytes: 6 * 1_048_576 + 5))  // 7 chunks
        try await a.engine.syncOnce()
        await relay.failBlobUploads(after: 3)
        do {
            try await a.engine.uploadPendingBlobs()
            XCTFail("expected the dropped connection")
        } catch {
            XCTAssertEqual(error as? TransportError, .network("simulated dropped upload"))
        }
        XCTAssertEqual(try a.db.pendingBlobUploads().count, 1, "the job stays queued")
        let blob = try XCTUnwrap(try a.db.item(item)?.content?.blob)
        let partway = try await relay.blobStatus(blobID: blob.id.description)
        XCTAssertEqual(partway?.received, [0, 1, 2])

        await relay.healBlobTransfers()
        let putsBefore = await relay.blobPutCount
        let progress = ProgressLog()
        try await a.engine.uploadPendingBlobs(progress: progress.record)
        let awaited6 = await relay.blobPutCount - putsBefore
        XCTAssertEqual(awaited6, 4, "only the missing chunks are sent")
        XCTAssertEqual(progress.entries.first?.resumedFrom, 3)
        XCTAssertEqual(progress.entries.last?.done, 7)
        let done = try await relay.blobStatus(blobID: blob.id.description)
        XCTAssertEqual(done?.isComplete, true)
    }

    func testInterruptedDownloadResumesFromLastVerifiedChunk() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let file = try makeFile(bytes: 5 * 1_048_576 + 100)  // 6 chunks
        let item = try await a.engine.addFile(at: file)
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()

        await relay.failBlobDownloads(after: 2)
        do {
            _ = try await b.engine.fetchBlob(for: item)
            XCTFail("expected the dropped connection")
        } catch {
            XCTAssertEqual(error as? TransportError, .network("simulated dropped download"))
        }
        let blob = try XCTUnwrap(try b.db.item(item)?.content?.blob)
        XCTAssertEqual(b.cache.partialSize(of: blob.id), 2 * 1_048_576)
        XCTAssertFalse(b.cache.contains(blob.id), "an unfinished download is never published")

        await relay.healBlobTransfers()
        let getsBefore = await relay.blobGetCount
        let progress = ProgressLog()
        let url = try await b.engine.fetchBlob(for: item, progress: progress.record)
        let awaited7 = await relay.blobGetCount - getsBefore
        XCTAssertEqual(awaited7, 4, "chunks 0 and 1 aren't fetched again")
        XCTAssertEqual(progress.entries.first?.resumedFrom, 2)
        XCTAssertEqual(try sha256(of: url), try sha256(of: file))
    }

    // MARK: Tampering (N8) and verification (N12)

    func testTamperedOrSwappedChunkIsRefused() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let item = try await a.engine.addFile(at: try makeFile(bytes: 3 * 1_048_576))  // 3 full chunks
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()
        let blob = try XCTUnwrap(try b.db.item(item)?.content?.blob).id.description

        // Chunk 1 stored in chunk 0's place: same length, valid GCM under the right key, wrong position.
        let chunk0 = try await relay.blobChunk(blobID: blob, index: 0)
        let chunk1 = try await relay.blobChunk(blobID: blob, index: 1)
        await relay.tamperBlobChunk(blobID: blob, index: 0, with: try XCTUnwrap(chunk1))
        await assertFetchFails(b, item, .corruptChunk(index: 0))

        // A flipped bit in the last chunk's tag.
        await relay.tamperBlobChunk(blobID: blob, index: 0, with: try XCTUnwrap(chunk0))
        let awaited10 = try await relay.blobChunk(blobID: blob, index: 2)
        var last = try XCTUnwrap(awaited10)
        last[last.count - 1] ^= 1
        await relay.tamperBlobChunk(blobID: blob, index: 2, with: last)
        await assertFetchFails(b, item, .corruptChunk(index: 2))
        XCTAssertFalse(b.cache.contains(try XCTUnwrap(try b.db.item(item)?.content?.blob).id))
    }

    /// Another item's chunk, even at the right index and from the same vault, doesn't open: the AAD names the item.
    func testChunkFromAnotherBlobIsRefused() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let first = try await a.engine.addFile(at: try makeFile(bytes: 1000, seed: 1))
        let second = try await a.engine.addFile(at: try makeFile(bytes: 1000, seed: 2))
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()
        let firstBlob = try XCTUnwrap(try b.db.item(first)?.content?.blob).id.description
        let secondBlob = try XCTUnwrap(try b.db.item(second)?.content?.blob).id.description
        let foreign = try await relay.blobChunk(blobID: secondBlob, index: 0)
        await relay.tamperBlobChunk(blobID: firstBlob, index: 0, with: try XCTUnwrap(foreign))
        await assertFetchFails(b, first, .corruptChunk(index: 0))
    }

    func assertFetchFails(_ peer: Peer, _ item: ItemID, _ expected: BlobTransferError,
                          file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await peer.engine.fetchBlob(for: item)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BlobTransferError, expected, file: file, line: line)
        }
    }

    // MARK: Garbage collection

    func testDeletingAnItemFreesItsBlobLocallyAndOnTheRelay() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let kept = try await a.engine.addFile(at: try makeFile(bytes: 100, seed: 1))
        let gone = try await a.engine.addFile(at: try makeFile(bytes: 100, seed: 2))
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()
        _ = try await b.engine.fetchBlob(for: gone)
        let goneBlob = try XCTUnwrap(try a.db.item(gone)?.content?.blob).id
        let keptBlob = try XCTUnwrap(try a.db.item(kept)?.content?.blob).id

        try await b.engine.delete(gone)
        let collected = await b.engine.collectGarbage()
        XCTAssertEqual(collected, .init(localFiles: 1, relayBlobs: 1))
        let awaited12 = await relay.blobIDs
        XCTAssertEqual(awaited12, [keptBlob.description])
        XCTAssertFalse(b.cache.contains(goneBlob))

        try await b.engine.syncOnce()
        try await a.engine.syncOnce()
        let onA = await a.engine.collectGarbage()
        XCTAssertEqual(onA.localFiles, 1)
        XCTAssertEqual(onA.relayBlobs, 1, "each device asks once; deleting twice is harmless")
        XCTAssertEqual(a.cache.storedBlobIDs(), [keptBlob])
        let awaited13 = await a.engine.collectGarbage()
        XCTAssertEqual(awaited13, .init(), "nothing left to do")
    }

    func testExpiryFreesBlobs() async throws {
        let relay = InMemoryRelay()
        let clock = LockedDate(Date(timeIntervalSince1970: 1_700_000_000))
        let db = try ClipDatabase.inMemory()
        let cache = try BlobCache(directory: try tempDirectory())
        let engine = try SyncEngine(db: db, vaultKey: key, transport: relay, device: DeviceID(), deviceName: "A",
                                    now: { clock.value }, log: { _ in }, blobCache: cache)
        _ = try await engine.addFile(at: try makeFile(bytes: 100))
        clock.value = clock.value.addingTimeInterval(10 * 86_400)
        let awaited14 = try await engine.expireItems(olderThan: .seconds(86_400))
        XCTAssertEqual(awaited14, 1)
        let awaited15 = await engine.collectGarbage().localFiles
        XCTAssertEqual(awaited15, 1)
        XCTAssertEqual(cache.storedBlobIDs(), [])
        XCTAssertEqual(try db.pendingBlobUploads(), [], "an expired item's upload isn't needed")
    }

    func testUploadOfDeletedItemIsDropped() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let item = try await a.engine.addFile(at: try makeFile(bytes: 100))
        try await a.engine.delete(item)
        let awaited16 = try await a.engine.uploadPendingBlobs()
        XCTAssertEqual(awaited16, 0)
        XCTAssertEqual(try a.db.pendingBlobUploads(), [])
        let awaited17 = await relay.blobIDs
        XCTAssertEqual(awaited17, [])
    }

    // MARK: Relay reset

    /// The relay lost everything. A device that downloaded the file (not the one that sent it) puts it back.
    func testRelayResetReuploadsFromAnyDeviceWithACopy() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let b = try makePeer("B", transport: relay)
        let file = try makeFile(bytes: 1_500_000)
        let item = try await a.engine.addFile(at: file)
        try await a.engine.syncOnce()
        try await a.engine.uploadPendingBlobs()
        try await b.engine.syncOnce()
        _ = try await b.engine.fetchBlob(for: item)

        await relay.simulateReset()
        try await b.engine.syncOnce()  // sees the new epoch, queues everything again
        let awaited18 = try await b.engine.uploadPendingBlobs()
        XCTAssertEqual(awaited18, 1)
        let c = try makePeer("C", transport: relay)
        try await c.engine.syncOnce()
        let awaited19 = try await c.engine.fetchBlob(for: item)
        XCTAssertEqual(try sha256(of: awaited19), try sha256(of: file))
    }

    // MARK: Run loop

    func testRunLoopUploadsInTheBackground() async throws {
        let relay = InMemoryRelay()
        let a = try makePeer("A", transport: relay)
        let running = Task { await a.engine.run() }
        defer { running.cancel() }
        let item = try await a.engine.addFile(at: try makeFile(bytes: 100))
        let blob = try XCTUnwrap(try a.db.item(item)?.content?.blob).id.description
        for _ in 0..<500 {
            if try await relay.blobStatus(blobID: blob)?.isComplete == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let status = try await relay.blobStatus(blobID: blob)
        XCTAssertEqual(status?.isComplete, true)
    }

    // MARK: Bounded memory (N6)

    /// Streams a 200 MB file up and back down. The transfer never holds more than a couple of chunks
    /// (`TransferMeter`), and on Apple platforms the process footprint, sampled every 5 ms, grows by far less
    /// than the file. The relay side here is a folder of chunk files, so it doesn't count against the test.
    func testTwoHundredMegabytesStayWithinAFewChunks() async throws {
        let size = 200 * 1_048_576
        let file = try makeFile(bytes: size)
        let transport = try DiskBlobTransport(directory: try tempDirectory())
        let meter = TransferMeter()
        let a = try makePeer("A", transport: transport, meter: meter)
        let b = try makePeer("B", transport: transport, meter: meter)

        let sampler = FootprintSampler()
        let started = Date()
        let item = try await a.engine.addFile(at: file)
        try await a.engine.syncOnce()
        let awaited20 = try await a.engine.uploadPendingBlobs()
        XCTAssertEqual(awaited20, 1)
        let uploaded = Date()
        try await b.engine.syncOnce()
        let url = try await b.engine.fetchBlob(for: item)
        let downloaded = Date()
        let footprint = sampler.stop()

        XCTAssertEqual(try sha256(of: url), try sha256(of: file))
        let chunk = WireLimits.maxBlobChunkBodyBytes
        XCTAssertLessThanOrEqual(meter.peakBytes, 2 * chunk, "one plaintext and one sealed chunk at most")
        XCTAssertEqual(meter.currentBytes, 0)
        let report = String(
            format: "N6: 200 MB import+upload %.1f s, download %.1f s; transfer buffers peak %d bytes (%.2f MiB)",
            uploaded.timeIntervalSince(started), downloaded.timeIntervalSince(uploaded), meter.peakBytes,
            Double(meter.peakBytes) / 1_048_576)
        print(report)
        if let footprint {
            print(String(format: "N6: process footprint grew at most %.1f MiB over a %.1f MiB baseline",
                         Double(footprint.growth) / 1_048_576, Double(footprint.baseline) / 1_048_576))
            XCTAssertLessThan(footprint.growth, 48 * 1_048_576, "memory must not scale with the 200 MB file")
        }
    }
}

/// Collects progress callbacks from a transfer.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BlobProgress] = []
    var entries: [BlobProgress] { lock.withLock { stored } }
    var record: BlobProgressHandler { { [self] progress in lock.withLock { stored.append(progress) } } }
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A relay stand-in that keeps chunks as files and ops in memory, so a 200 MB test doesn't hold 200 MB.
actor DiskBlobTransport: SyncTransport, BlobTransport {
    private let ops = InMemoryRelay()
    private let directory: URL
    private var counts: [String: Int] = [:]

    init(directory: URL) throws { self.directory = directory }

    func push(_ request: PushRequest) async throws -> PushResponse { try await ops.push(request) }
    func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        try await ops.pull(after: after, limit: limit, wait: wait)
    }
    func putPairing(id: String, blob: Data) async throws { try await ops.putPairing(id: id, blob: blob) }
    func takePairing(id: String) async throws -> Data? { try await ops.takePairing(id: id) }

    private func url(_ blobID: String, _ index: Int) -> URL { directory.appendingPathComponent("\(blobID)-\(index)") }

    func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {
        counts[blobID] = count
        try data.write(to: url(blobID, index))
    }

    func blobStatus(blobID: String) async throws -> BlobStatus? {
        guard let count = counts[blobID] else { return nil }
        let received = (0..<count).filter { FileManager.default.fileExists(atPath: url(blobID, $0).path) }
        return BlobStatus(blobID: blobID, chunkCount: count, received: received)
    }

    func blobChunk(blobID: String, index: Int) async throws -> Data? {
        // Data(contentsOf:) autoreleases its buffer on Apple platforms; drain it here like a real transport would.
        withAutoreleasePool { try? Data(contentsOf: url(blobID, index)) }
    }

    func deleteBlob(blobID: String) async throws {
        for index in 0..<(counts[blobID] ?? 0) { try? FileManager.default.removeItem(at: url(blobID, index)) }
        counts[blobID] = nil
    }
}

/// Samples the process's physical footprint every 5 ms on Apple platforms (nil elsewhere).
final class FootprintSampler: @unchecked Sendable {
    struct Result {
        var baseline: Int
        var growth: Int
    }

    private let lock = NSLock()
    private var running = true
    private var peak = 0
    private let baseline: Int?
    private let done = DispatchSemaphore(value: 0)

    init() {
        baseline = Self.footprint()
        guard baseline != nil else { return }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                if let now = Self.footprint() { lock.withLock { peak = max(peak, now) } }
                Thread.sleep(forTimeInterval: 0.005)
            }
            done.signal()
        }
    }

    func stop() -> Result? {
        guard let baseline else { return nil }
        lock.withLock { running = false }
        done.wait()
        return Result(baseline: baseline, growth: max(0, lock.withLock { peak } - baseline))
    }

    static func footprint() -> Int? {
        #if canImport(Darwin)
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int(info.ri_phys_footprint) : nil
        #else
        return nil
        #endif
    }
}
