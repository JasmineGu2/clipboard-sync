import ClipCore
import ClipStore
import Crypto
import Foundation

// Blob mode for the crash test (Tests/ClipStoreTests/BlobCrashInjectionTests.swift, PRD N12 for payload files).
// Writes blobs into a BlobCache in a loop, the way downloads and imports do, until the test kills the process.
//
// Usage: ClipStoreCrashWriter blob <cache dir> <seed>
//
// Every blob's size, chunk size and bytes follow from its ID (`BlobPattern`; the test has the same function), so
// the test can check any file it finds, and a later run can resume a partial download it didn't start.
//
// Protocol on stdout, one line per event, written unbuffered:
//   READY            the cache is open
//   B <id> <how>     starting blob <id>; how is "download", "resume", "corrupt" (a download that writes one chunk
//                    with a flipped byte, as a lying disk or a bug would) or "import"
//   D <id>           finish() / import returned: the blob is complete
//   R <id>           finish() refused the blob (hash mismatch) and removed the partial file

enum BlobPattern {
    /// Size (1 B to 2 MiB) and chunk size (4 KiB, 64 KiB or 1 MiB) from the ID. Kept in step with the test's copy.
    static func shape(_ id: BlobID) -> (size: Int, chunkSize: Int) {
        let seed = seed(id)
        let chunkSizes = [4 << 10, 64 << 10, 1 << 20]
        return (Int((seed >> 24) % UInt64(2 << 20)) + 1, chunkSizes[Int((seed >> 8) % 3)])
    }

    static func seed(_ id: BlobID) -> UInt64 {
        withUnsafeBytes(of: id.rawValue.uuid) { $0.load(as: UInt64.self) }
    }

    /// `count` bytes of the blob's content starting at `offset` (a multiple of 8).
    static func bytes(_ id: BlobID, offset: Int, count: Int) -> Data {
        var state = seed(id) &+ UInt64(offset / 8) &* 0x9E37_79B9_7F4A_7C15
        var data = Data(capacity: count + 8)
        while data.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            withUnsafeBytes(of: z.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.prefix(count)
    }

    static func ref(_ id: BlobID) -> BlobRef {
        let (size, chunkSize) = shape(id)
        var hasher = SHA256()
        var offset = 0
        while offset < size {
            let count = min(chunkSize, size - offset)
            hasher.update(data: bytes(id, offset: offset, count: count))
            offset += count
        }
        return BlobRef(id: id, size: Int64(size), sha256: Data(hasher.finalize()), chunkSize: chunkSize, contentType: nil)
    }
}

func runBlobWriter(directory: URL, seed: UInt64) -> Never {
    let cache: BlobCache
    do {
        cache = try BlobCache(directory: directory)
    } catch {
        FileHandle.standardError.write(Data("open cache failed: \(error)\n".utf8))
        exit(1)
    }
    var rng = Rng(state: seed)
    emit("READY")

    /// Downloads (or resumes) `id`; `corruptChunk` flips one byte of that chunk before writing it.
    func download(_ id: BlobID, how: String, corruptChunk: Int? = nil) throws {
        let ref = BlobPattern.ref(id)
        emit("B \(id) \(how)")
        let download = try cache.beginDownload(ref)
        defer { download.close() }
        while !download.isComplete {
            let index = download.verifiedChunks
            var chunk = BlobPattern.bytes(id, offset: index * ref.chunkSize, count: ref.plaintextLength(ofChunk: index))
            if index == corruptChunk, !chunk.isEmpty { chunk[chunk.startIndex] ^= 0x5A }
            try download.append(chunk)
        }
        do {
            try download.finish()
            emit("D \(id)")
        } catch BlobCacheError.hashMismatch {
            emit("R \(id)")
        }
    }

    do {
        // Partial downloads a killed run left behind, as a restarted app would resume them.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".partial") {
            if let uuid = UUID(uuidString: String(name.dropLast(".partial".count))) {
                try download(BlobID(uuid), how: "resume")
            }
        }
        while true {
            let id = BlobID(UUID())
            switch rng.below(10) {
            case 0..<6:
                try download(id, how: "download")
            case 6, 7:
                let ref = BlobPattern.ref(id)
                emit("B \(id) import")
                _ = try cache.importData(BlobPattern.bytes(id, offset: 0, count: Int(ref.size)), as: id,
                                         maxBytes: .max)
                emit("D \(id)")
            default:
                let ref = BlobPattern.ref(id)
                try download(id, how: "corrupt", corruptChunk: rng.below(ref.chunkCount))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("blob write failed: \(error)\n".utf8))
        exit(1)
    }
}
