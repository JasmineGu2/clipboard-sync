import ClipWire
import Foundation
import Logging
import Testing

@testable import RelayCore

// Stale-blob purge (incomplete uploads by age, orphan chunk rows) and the running blob byte counter: kept in the
// same transaction as every change, migrated into older databases, never out of step after a failure mid-write.

private let blobB = "7F9619FF-8B86-D011-B42D-00C04FC964FF"
private let blobC = "8F9619FF-8B86-D011-B42D-00C04FC964FF"
private let day: Int64 = 86_400

private func put(_ storage: SQLiteRelayStorage, _ blob: String, _ index: Int, of count: Int, bytes: Int = 50,
                 at now: Int64 = 1_000) async throws -> BlobChunkPutResult {
    try await storage.putBlobChunk(blobID: blob, index: index, count: count,
                                   data: Data(repeating: UInt8(index & 0xff), count: bytes), now: now, maxTotalBytes: .max)
}

/// The counter must equal the exact sum after anything at all.
private func expectCounterExact(_ storage: SQLiteRelayStorage, _ comment: Comment? = nil,
                                sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let counter = try await storage.blobBytesStored()
    let exact = try await storage.recountBlobBytes()
    #expect(counter == exact, comment, sourceLocation: sourceLocation)
}

private func tempDBPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite3").path
}

private func removeDB(_ path: String) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}

private struct InjectedFault: Error {}

private func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
}

@Suite struct StaleBlobPurgeTests {
    @Test func purgesOnlyIncompleteBlobsUntouchedPastTheCutoff() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        // A: incomplete, last chunk at t=1000. B: complete, old. C: incomplete but touched again at t=1000+8d.
        _ = try await put(storage, blobA, 0, of: 3, at: 1_000)
        _ = try await put(storage, blobB, 0, of: 2, at: 1_000)
        _ = try await put(storage, blobB, 1, of: 2, at: 1_000)
        _ = try await put(storage, blobC, 0, of: 2, at: 1_000)
        _ = try await put(storage, blobC, 1, of: 2, at: 1_000)
        try await storage.deleteBlob(blobID: blobC)
        _ = try await put(storage, blobC, 0, of: 2, at: 1_000 + 8 * day)

        let now = 1_000 + 8 * day
        let result = try await storage.purgeStaleBlobs(untouchedSince: now - 7 * day)
        #expect(result == BlobPurgeResult(blobs: 1, bytes: 50))
        #expect(try await storage.blobStatus(blobID: blobA) == nil)
        #expect(try await storage.blobStatus(blobID: blobB)?.received == [0, 1])
        #expect(try await storage.blobStatus(blobID: blobC)?.received == [0])
        #expect(try await storage.blobBytesStored() == 150)
        try await expectCounterExact(storage)

        // A second pass finds nothing.
        #expect(try await storage.purgeStaleBlobs(untouchedSince: now - 7 * day) == BlobPurgeResult())
    }

    @Test func eachNewChunkRestartsTheClock() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await put(storage, blobA, 0, of: 3, at: 1_000)
        _ = try await put(storage, blobA, 1, of: 3, at: 1_000 + 6 * day)
        // Created 8 days before the cutoff check, but its last chunk is only 2 days old.
        #expect(try await storage.purgeStaleBlobs(untouchedSince: 1_000 + 8 * day - 7 * day).blobs == 0)
        // A retried chunk the relay already holds isn't progress and doesn't touch it.
        _ = try await put(storage, blobA, 1, of: 3, at: 1_000 + 30 * day)
        #expect(try await storage.purgeStaleBlobs(untouchedSince: 1_000 + 14 * day - 7 * day).blobs == 1)
        try await expectCounterExact(storage)
    }

    @Test func anUploadResumesFromScratchAfterAPurge() async throws {
        let relay = try Relay()
        let storage = relay.storage
        let clock = relay.clock
        try await relay.run { client async throws in
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0)).status == .noContent)
            clock.advance(by: 8 * day)
            let purged = try await BlobPurger(storage: storage, now: { clock.now }).runOnce()
            #expect(purged.blobs == 1)
            // The resume query says nothing is there, so the device sends every chunk again.
            #expect(try await client.blobStatus().status == .notFound)
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0)).status == .noContent)
            #expect(try await client.putChunk(1, count: 2, body: chunkBody(1)).status == .noContent)
            #expect(try decode(BlobStatus.self, try await client.blobStatus()).isComplete)
        }
        try await expectCounterExact(storage)
    }

    @Test func orphanChunkRowsArePurgedWhateverTheirAge() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await put(storage, blobA, 0, of: 1, at: 1_000)
        // No code path leaves chunks without a blobs row; plant some as an older relay or a hand edit might have.
        try await storage.execForTesting("""
            INSERT INTO blob_chunks(blob_id, idx, data) VALUES('\(blobB)', 0, zeroblob(70));
            INSERT INTO blob_chunks(blob_id, idx, data) VALUES('\(blobB)', 1, zeroblob(30));
            UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 100 AS TEXT) WHERE key = 'blob_bytes_stored';
            """)
        let result = try await storage.purgeStaleBlobs(untouchedSince: 0)
        #expect(result == BlobPurgeResult(blobs: 1, bytes: 100))
        #expect(try await storage.blobChunk(blobID: blobB, index: 0) == nil)
        #expect(try await storage.blobStatus(blobID: blobA)?.received == [0])
        #expect(try await storage.blobBytesStored() == 50)
        try await expectCounterExact(storage)
    }

    @Test func purgerUsesItsMaxAgeAndRunsOnATimer() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        let clock = TestClock()
        _ = try await put(storage, blobA, 0, of: 2, at: clock.now)
        let purger = BlobPurger(storage: storage, maxAgeSeconds: 7 * day, now: { clock.now })
        clock.advance(by: 7 * day)
        // Exactly the max age is not yet past it.
        #expect(try await purger.runOnce().blobs == 0)

        // The loop's first pass runs at once; later passes pick up blobs that go stale while it runs.
        let loop = Task { await purger.run(every: .milliseconds(20), logger: Logger(label: "test")) }
        defer { loop.cancel() }
        clock.advance(by: 1)
        try await waitUntil { (try? await storage.blobStatus(blobID: blobA)) == nil }
        #expect(try await storage.blobStatus(blobID: blobA) == nil)
        _ = try await put(storage, blobB, 0, of: 2, at: clock.now)
        clock.advance(by: 7 * day + 1)
        try await waitUntil { (try? await storage.blobStatus(blobID: blobB)) == nil }
        #expect(try await storage.blobStatus(blobID: blobB) == nil)
        try await expectCounterExact(storage)
    }
}

@Suite struct BlobByteCounterTests {
    @Test func freshDatabaseStartsAtZero() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        #expect(try await storage.blobBytesStored() == 0)
    }

    /// A random mix of every operation that changes chunks; after each one the counter equals the exact sum.
    @Test func matchesTheExactSumThroughEveryKindOfChange() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        let blobs = [blobA, blobB, blobC]
        var state: UInt64 = 42
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        for step in 0..<400 {
            let blob = blobs[next(blobs.count)]
            switch next(10) {
            case 0..<6: _ = try await put(storage, blob, next(4), of: 4, bytes: 28 + next(200), at: Int64(step))
            case 6, 7: try await storage.deleteBlob(blobID: blob)
            case 8: _ = try await storage.purgeStaleBlobs(untouchedSince: Int64(step - next(50)))
            default:
                if next(4) == 0 {
                    _ = try await storage.revoke(newTokenHash: "h\(step)", devices: [], handoffs: [],
                                                 maxHandoffsPerDevice: 8, expectedDeviceIDs: nil)
                }
            }
            try await expectCounterExact(storage, "step \(step)")
        }
    }

    @Test func capIsCheckedAgainstTheCounter() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        #expect(try await storage.putBlobChunk(blobID: blobA, index: 0, count: 3, data: Data(count: 60), now: 1,
                                               maxTotalBytes: 100) == .stored)
        #expect(try await storage.putBlobChunk(blobID: blobA, index: 1, count: 3, data: Data(count: 41), now: 1,
                                               maxTotalBytes: 100) == .full)
        #expect(try await storage.putBlobChunk(blobID: blobA, index: 1, count: 3, data: Data(count: 40), now: 1,
                                               maxTotalBytes: 100) == .stored)
        try await storage.deleteBlob(blobID: blobA)
        // Space freed by a delete is usable at once.
        #expect(try await storage.putBlobChunk(blobID: blobA, index: 0, count: 1, data: Data(count: 100), now: 1,
                                               maxTotalBytes: 100) == .stored)
    }

    /// A database from before the counter (and before `touched_at`) gets both when opened.
    @Test func migratesAnOlderDatabase() async throws {
        let path = tempDBPath("relay-migrate")
        defer { removeDB(path) }
        do {
            let storage = try SQLiteRelayStorage(path: path)
            _ = try await put(storage, blobA, 0, of: 2, bytes: 70, at: 5_000)
            _ = try await put(storage, blobB, 0, of: 1, bytes: 30, at: 6_000)
            // Turn it back into the old schema.
            try await storage.execForTesting("""
                DELETE FROM meta WHERE key = 'blob_bytes_stored';
                ALTER TABLE blobs DROP COLUMN touched_at;
                """)
        }
        let reopened = try SQLiteRelayStorage(path: path)
        #expect(try await reopened.blobBytesStored() == 100)
        // touched_at came from created_at: A (incomplete, from t=5000) is stale at a cutoff past it.
        #expect(try await reopened.purgeStaleBlobs(untouchedSince: 5_000).blobs == 0)
        #expect(try await reopened.purgeStaleBlobs(untouchedSince: 5_001) == BlobPurgeResult(blobs: 1, bytes: 70))
        try await expectCounterExact(reopened)
        // Opening again changes nothing.
        let again = try SQLiteRelayStorage(path: path)
        #expect(try await again.blobBytesStored() == 30)
    }

    /// Every write that changes chunks fails at its last step, just before commit. The rollback must take the
    /// counter back with the chunks: neither may change.
    @Test func aFailureBeforeCommitLeavesCounterAndChunksUnchanged() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await put(storage, blobA, 0, of: 3)
        _ = try await put(storage, blobB, 0, of: 2, at: 1)
        await storage.setFaultHook { _ in throw InjectedFault() }

        await #expect(throws: InjectedFault.self) { _ = try await put(storage, blobA, 1, of: 3) }
        await #expect(throws: InjectedFault.self) { try await storage.deleteBlob(blobID: blobA) }
        await #expect(throws: InjectedFault.self) { _ = try await storage.purgeStaleBlobs(untouchedSince: .max) }
        await #expect(throws: InjectedFault.self) {
            _ = try await storage.revoke(newTokenHash: "h", devices: [], handoffs: [], maxHandoffsPerDevice: 8,
                                         expectedDeviceIDs: nil)
        }
        await storage.setFaultHook(nil)
        #expect(try await storage.blobBytesStored() == 100)
        #expect(try await storage.blobStatus(blobID: blobA)?.received == [0])
        #expect(try await storage.blobStatus(blobID: blobB)?.received == [0])
        try await expectCounterExact(storage)
    }

    /// A crash mid-transaction: the hook copies the database files exactly as they are on disk at that moment (with
    /// a tiny page cache, so the transaction has already spilled into the WAL), then the copy is opened like a
    /// relay restarting after the crash. Counter and chunks must agree, and match the state before the write.
    @Test func aCrashMidTransactionLeavesCounterAndChunksInStep() async throws {
        for operation in ["putBlobChunk", "deleteBlob", "purgeStaleBlobs", "revoke"] {
            let path = tempDBPath("relay-crash")
            let snapshot = tempDBPath("relay-crash-snapshot")
            defer {
                removeDB(path)
                removeDB(snapshot)
            }
            let storage = try SQLiteRelayStorage(path: path)
            for index in 0..<3 { _ = try await put(storage, blobA, index, of: 4, bytes: 300_000, at: 1) }
            _ = try await put(storage, blobB, 0, of: 1, bytes: 200_000, at: 1)
            let before = try await storage.blobBytesStored()
            try await storage.execForTesting("PRAGMA cache_size = 2; PRAGMA cache_spill = 2")
            let walBefore = fileSize(path + "-wal")
            await storage.setFaultHook { _ in
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                    try FileManager.default.copyItem(atPath: path + suffix, toPath: snapshot + suffix)
                }
                throw InjectedFault()
            }
            await #expect(throws: InjectedFault.self, "\(operation)") {
                switch operation {
                case "putBlobChunk": _ = try await put(storage, blobA, 3, of: 4, bytes: 300_000, at: 2)
                case "deleteBlob": try await storage.deleteBlob(blobID: blobA)
                case "purgeStaleBlobs": _ = try await storage.purgeStaleBlobs(untouchedSince: .max)
                default:
                    _ = try await storage.revoke(newTokenHash: "h", devices: [], handoffs: [], maxHandoffsPerDevice: 8,
                                                 expectedDeviceIDs: nil)
                }
            }
            // For the upload, the tiny cache pushed the open transaction's pages into the WAL, so the snapshot holds
            // a half-written transaction, not just the state before it. Deletes dirty too few pages to spill (freed
            // overflow pages go on the free list), so for them the snapshot is the pre-write state on disk.
            if operation == "putBlobChunk" {
                #expect(fileSize(snapshot + "-wal") > walBefore,
                        "the upload never reached the WAL, so the snapshot proves little")
            }

            let restarted = try SQLiteRelayStorage(path: snapshot)
            try await expectCounterExact(restarted, "\(operation)")
            #expect(try await restarted.blobBytesStored() == before, "\(operation)")
            #expect(try await restarted.blobStatus(blobID: blobA)?.received == [0, 1, 2], "\(operation)")
        }
    }
}

@Suite struct BindPolicyTests {
    @Test(arguments: [
        ("127.0.0.1", BindPolicy.Kind.loopback), ("127.8.9.10", .loopback), ("localhost", .loopback),
        ("::1", .loopback), ("[::1]", .loopback), ("::ffff:127.0.0.1", .loopback),
        ("100.64.0.0", .tailnet), ("100.101.102.103", .tailnet), ("100.127.255.255", .tailnet),
        ("fd7a:115c:a1e0::1", .tailnet), ("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240", .tailnet),
        ("::ffff:100.100.1.2", .tailnet),
        ("0.0.0.0", .everyInterface), ("::", .everyInterface),
        ("100.63.255.255", .other), ("100.128.0.0", .other), ("10.0.0.5", .other), ("192.168.1.2", .other),
        ("203.0.113.7", .other), ("fd7a:115c:a1e1::1", .other), ("2001:db8::1", .other),
        ("relay.example.com", .other), ("macbook-air.tailc07d02.ts.net", .other), ("", .other), ("127.0.0.1.", .other),
    ])
    func classifies(_ host: String, _ kind: BindPolicy.Kind) {
        #expect(BindPolicy.classify(host) == kind, "\(host)")
    }

    @Test func refusesOutsideTheTailnetUnlessAllowed() {
        #expect(BindPolicy.decide(host: "100.100.1.2", allowNonTailnet: false) == .allow)
        #expect(BindPolicy.decide(host: "127.0.0.1", allowNonTailnet: false) == .allow)
        for host in ["0.0.0.0", "::", "203.0.113.7", "relay.example.com"] {
            guard case .refuse(let message) = BindPolicy.decide(host: host, allowNonTailnet: false) else {
                Issue.record("\(host) should be refused")
                continue
            }
            #expect(message.contains("--allow-non-tailnet"))
            guard case .warn = BindPolicy.decide(host: host, allowNonTailnet: true) else {
                Issue.record("\(host) with the flag should start with a warning")
                continue
            }
        }
        // The 0.0.0.0 warning stays when the operator opts in.
        #expect(BindPolicy.decide(host: "0.0.0.0", allowNonTailnet: true)
            == .warn("Listening on every interface. Outside a container whose published port is pinned to the "
                + "Tailscale IP, bind the Tailscale IP instead."))
    }

    /// The real binary: a refused address exits with status 2 before the database is even created.
    @Test func theRelayBinaryRefusesToStart() throws {
        let relay = try relayExecutable()
        let cases: [(arguments: [String], environment: [String: String])] = [
            (["--host", "0.0.0.0"], [:]),
            (["--host", "203.0.113.7"], [:]),
            ([], ["CLIP_RELAY_HOST": "::"]),
            (["--host", "0.0.0.0", "--allow-non-tailnet=0"], ["CLIP_RELAY_ALLOW_NON_TAILNET": "1"]),
        ]
        for (arguments, environment) in cases {
            let db = tempDBPath("relay-refuse")
            defer { removeDB(db) }
            let process = Process()
            process.executableURL = relay
            process.arguments = arguments + ["--port", "1", "--db", db]
            process.environment = environment
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 2, "\(arguments) \(environment)")
            #expect(message.contains("refusing to bind"), "\(arguments): \(message)")
            #expect(!FileManager.default.fileExists(atPath: db), "\(arguments): opened the database first")
        }
    }

    private func relayExecutable() throws -> URL {
        var folders = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent() }
        folders.append(Bundle.main.bundleURL)
        folders.append(Bundle.main.bundleURL.deletingLastPathComponent())
        // Server/Tests/RelayTests/<this file> -> Server/.build/debug
        folders.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug"))
        for folder in folders {
            let url = folder.appendingPathComponent("ClipRelay")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw StorageError(code: 1, message: "ClipRelay not found in \(folders.map(\.path)); run `swift build` first")
    }
}
