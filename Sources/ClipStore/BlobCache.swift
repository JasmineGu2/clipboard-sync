import ClipCore
import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum BlobCacheError: Error, Equatable, Sendable {
    /// The file is over the size limit for one blob.
    case tooLarge(bytes: Int64)
    /// No complete copy of this blob on this device.
    case missing
    /// A downloaded chunk wasn't the length its position needs.
    case wrongChunkLength
    /// Every chunk arrived, but the whole file doesn't match the size or SHA-256 in the item. The partial file is
    /// removed, so the next attempt starts over.
    case hashMismatch
    /// The source file couldn't be read, or a cache file couldn't be written.
    case io(String)
}

/// The local, plaintext copies of image and file payloads, one file per blob (design §6). Platform-neutral:
/// Foundation file handles only, plus `fsync` on directories where the OS has it.
///
/// Crash safety (N12): a blob file only ever appears complete. Imports and downloads write to a temporary or
/// `.partial` file, fsync it, check its size and SHA-256, then rename it into place and fsync the directory.
/// A crash leaves at most a stray temporary file (collected later) or a partial download (resumed).
///
/// Memory (N6): every read and write goes one chunk at a time, so nothing here holds more than one chunk.
public final class BlobCache: Sendable {
    public let directory: URL
    /// Read and write buffer for imports, exports and hashing.
    static let ioChunk = 1 << 20
    private static let partialSuffix = ".partial"
    private static let tempPrefix = "tmp-"

    public init(directory: URL) throws {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BlobCacheError.io("create \(directory.path): \(error)")
        }
    }

    /// Where a complete blob lives. Only exists once verified.
    public func url(for id: BlobID) -> URL {
        directory.appendingPathComponent(id.description)
    }

    func partialURL(for id: BlobID) -> URL {
        directory.appendingPathComponent(id.description + Self.partialSuffix)
    }

    public func contains(_ id: BlobID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Bytes downloaded so far for an unfinished blob (0 when none).
    public func partialSize(of id: BlobID) -> Int64 {
        Self.fileSize(partialURL(for: id)) ?? 0
    }

    // MARK: Import

    public struct Imported: Equatable, Sendable {
        public var size: Int64
        public var sha256: Data
    }

    /// Copies `source` into the cache as blob `id`, hashing it on the way, one chunk at a time.
    /// The copy is what gets uploaded, so a later edit of the original can't change a blob mid-upload.
    public func importFile(at source: URL, as id: BlobID, maxBytes: Int64) throws -> Imported {
        guard let declared = Self.fileSize(source) else { throw BlobCacheError.io("can't read \(source.path)") }
        guard declared <= maxBytes else { throw BlobCacheError.tooLarge(bytes: declared) }
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw BlobCacheError.io("open \(source.path): \(error)")
        }
        defer { try? input.close() }
        return try write(as: id, maxBytes: maxBytes) { sink in
            while let data = try input.read(upToCount: Self.ioChunk), !data.isEmpty {
                try sink(data)
            }
        }
    }

    /// Stores in-memory bytes (a pasteboard image) as blob `id`.
    public func importData(_ data: Data, as id: BlobID, maxBytes: Int64) throws -> Imported {
        guard Int64(data.count) <= maxBytes else { throw BlobCacheError.tooLarge(bytes: Int64(data.count)) }
        return try write(as: id, maxBytes: maxBytes) { sink in
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.ioChunk, data.count)
                try sink(data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
                offset = end
            }
        }
    }

    /// Writes through a temporary file, then fsyncs and renames it into place.
    private func write(as id: BlobID, maxBytes: Int64, _ produce: ((Data) throws -> Void) throws -> Void) throws -> Imported {
        let temp = directory.appendingPathComponent(Self.tempPrefix + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw BlobCacheError.io("create \(temp.path)")
        }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: temp) } }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: temp)
        } catch {
            throw BlobCacheError.io("open \(temp.path): \(error)")
        }
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            defer { try? output.close() }
            try produce { data in
                size += Int64(data.count)
                // The file may have grown since it was measured.
                guard size <= maxBytes else { throw BlobCacheError.tooLarge(bytes: size) }
                hasher.update(data: data)
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        } catch let error as BlobCacheError {
            throw error
        } catch {
            throw BlobCacheError.io("write \(temp.path): \(error)")
        }
        try moveIntoPlace(temp, url(for: id))
        finished = true
        return Imported(size: size, sha256: Data(hasher.finalize()))
    }

    // MARK: Reading

    /// Reads `length` bytes of chunk `index` from a complete blob. Opens and closes the file each time, so a long
    /// upload holds no file open between chunks.
    public func readChunk(of id: BlobID, index: Int, chunkSize: Int, length: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url(for: id))
        } catch {
            throw BlobCacheError.missing
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else { throw BlobCacheError.wrongChunkLength }
            return data
        } catch let error as BlobCacheError {
            throw error
        } catch {
            throw BlobCacheError.io("read \(id): \(error)")
        }
    }

    /// Copies a complete blob to `destination` (temp file next to it, then rename), one chunk at a time.
    /// An existing file at `destination` is replaced.
    public func export(_ id: BlobID, to destination: URL) throws {
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: url(for: id))
        } catch {
            throw BlobCacheError.missing
        }
        defer { try? source.close() }
        let folder = destination.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw BlobCacheError.io("create \(temp.path)")
        }
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            while let data = try source.read(upToCount: Self.ioChunk), !data.isEmpty {
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw BlobCacheError.io("export to \(destination.path): \(error)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw BlobCacheError.io("move to \(destination.path): \(error)")
        }
    }

    // MARK: Download

    /// Opens (or resumes) the download of `ref`. A partial file from an earlier attempt is cut back to its last
    /// whole chunk and re-hashed, so the download continues from the last verified chunk (N5).
    public func beginDownload(_ ref: BlobRef) throws -> BlobDownload {
        let partial = partialURL(for: ref.id)
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw BlobCacheError.io("create \(partial.path)")
            }
        }
        let existing = Self.fileSize(partial) ?? 0
        // Whole chunks already on disk. Each was checked by GCM before it was written; the final SHA-256 check
        // catches anything a crash garbled after that.
        var chunks = 0
        var offset: Int64 = 0
        while chunks < ref.chunkCount {
            let length = Int64(ref.plaintextLength(ofChunk: chunks))
            // `length > 0`: an empty blob's single empty chunk is still fetched and authenticated.
            guard length > 0, offset + length <= existing else { break }
            offset += length
            chunks += 1
        }
        let handle: FileHandle
        var hasher = SHA256()
        do {
            handle = try FileHandle(forUpdating: partial)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: 0)
            var remaining = offset
            while remaining > 0 {
                let want = Int(min(Int64(Self.ioChunk), remaining))
                guard let data = try handle.read(upToCount: want), data.count == want else {
                    throw BlobCacheError.io("short read re-hashing \(partial.path)")
                }
                hasher.update(data: data)
                remaining -= Int64(want)
            }
            try handle.seek(toOffset: UInt64(offset))
        } catch let error as BlobCacheError {
            throw error
        } catch {
            throw BlobCacheError.io("resume \(partial.path): \(error)")
        }
        return BlobDownload(cache: self, ref: ref, handle: handle, hasher: hasher, verifiedChunks: chunks, bytes: offset)
    }

    /// Removes a blob's complete and partial files.
    public func remove(_ id: BlobID) {
        try? FileManager.default.removeItem(at: url(for: id))
        try? FileManager.default.removeItem(at: partialURL(for: id))
    }

    // MARK: Garbage collection

    /// Removes the files of `dead` blobs (deleted or expired items), and anything that isn't `live` and hasn't
    /// been touched for `orphanAge` (a temporary file from a crash, or an import whose item was never recorded).
    /// Returns how many files went.
    @discardableResult
    public func collectGarbage(live: Set<BlobID>, dead: Set<BlobID>, orphanAge: TimeInterval, now: Date = Date()) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names {
            let idText = name.hasSuffix(Self.partialSuffix) ? String(name.dropLast(Self.partialSuffix.count)) : name
            let id = UUID(uuidString: idText).map(BlobID.init)
            if let id, live.contains(id) { continue }
            let file = directory.appendingPathComponent(name)
            let isDead = id.map(dead.contains) ?? false
            if !isDead {
                let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
                guard let modified, now.timeIntervalSince(modified) > orphanAge else { continue }
            }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// IDs of the complete blobs on disk.
    public func storedBlobIDs() -> Set<BlobID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { UUID(uuidString: $0).map(BlobID.init) })
    }

    // MARK: Helpers

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// Renames `temp` to `final` and fsyncs the folder, so the new name survives a crash. If `final` already
    /// exists (the same blob finished elsewhere first), the temp file is dropped: blob files never change.
    func moveIntoPlace(_ temp: URL, _ final: URL) throws {
        if FileManager.default.fileExists(atPath: final.path) {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        do {
            try FileManager.default.moveItem(at: temp, to: final)
        } catch {
            if FileManager.default.fileExists(atPath: final.path) {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            throw BlobCacheError.io("rename to \(final.path): \(error)")
        }
        syncDirectory()
    }

    /// fsync on the cache folder, where the OS allows it. Windows has no directory fsync; NTFS journals renames.
    private func syncDirectory() {
        #if !os(Windows)
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        _ = close(fd)
        #endif
    }
}

/// One download in progress, written to the blob's `.partial` file. Not thread-safe: one task drives it.
public final class BlobDownload {
    public let ref: BlobRef
    /// Chunks written and fsynced so far; the next chunk to fetch.
    public private(set) var verifiedChunks: Int
    /// Chunks that were already on disk when this download (re)started.
    public let resumedChunks: Int
    private let cache: BlobCache
    private let handle: FileHandle
    private var hasher: SHA256
    private var bytes: Int64
    private var closed = false

    init(cache: BlobCache, ref: BlobRef, handle: FileHandle, hasher: SHA256, verifiedChunks: Int, bytes: Int64) {
        self.cache = cache
        self.ref = ref
        self.handle = handle
        self.hasher = hasher
        self.verifiedChunks = verifiedChunks
        self.resumedChunks = verifiedChunks
        self.bytes = bytes
    }

    deinit { close() }

    public var isComplete: Bool { verifiedChunks == ref.chunkCount }

    /// Appends the next chunk's plaintext (already opened, so already authenticated) and fsyncs it.
    public func append(_ plaintext: Data) throws {
        guard verifiedChunks < ref.chunkCount, plaintext.count == ref.plaintextLength(ofChunk: verifiedChunks) else {
            throw BlobCacheError.wrongChunkLength
        }
        do {
            try handle.write(contentsOf: plaintext)
            try handle.synchronize()
        } catch {
            throw BlobCacheError.io("write \(ref.id).partial: \(error)")
        }
        hasher.update(data: plaintext)
        bytes += Int64(plaintext.count)
        verifiedChunks += 1
    }

    /// Checks size and SHA-256, then moves the file into place. On a mismatch the partial file is removed.
    @discardableResult
    public func finish() throws -> URL {
        guard isComplete else { throw BlobCacheError.wrongChunkLength }
        close()
        let digest = Data(hasher.finalize())
        let partial = cache.partialURL(for: ref.id)
        guard bytes == ref.size, digest == ref.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw BlobCacheError.hashMismatch
        }
        try cache.moveIntoPlace(partial, cache.url(for: ref.id))
        return cache.url(for: ref.id)
    }

    /// Closes the file and keeps what was written, for a later resume.
    public func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
