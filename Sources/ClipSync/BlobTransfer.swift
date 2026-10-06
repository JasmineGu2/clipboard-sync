import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation

public enum BlobTransferError: Error, Equatable, Sendable {
    /// The item has no blob (a text item), or no visible item has that ID.
    case notABlobItem
    /// This device has no copy to upload (it never had one, or it was collected).
    case noLocalCopy
    /// The relay doesn't have chunk `index` yet: the sending device hasn't finished uploading. Try again later.
    case notUploadedYet(chunk: Int)
    /// The relay holds this blob with a different chunk count than the item says.
    case relayCountMismatch
    /// The item's blob reference is outside the limits (size, chunk size, hash length), so it's refused unread.
    case invalidBlobRef
    /// Chunk `index` didn't open: tampered, moved, or from another blob. Nothing from it was written.
    case corruptChunk(index: Int)
}

/// Where a transfer is, for progress output.
public struct BlobProgress: Equatable, Sendable {
    public var blob: BlobID
    /// Chunks the relay (upload) or this device (download) now holds.
    public var done: Int
    public var total: Int
    /// Chunks that were already there when this attempt started: the resume point (N5).
    public var resumedFrom: Int
}

public typealias BlobProgressHandler = @Sendable (BlobProgress) -> Void

/// Counts the chunk bytes a transfer holds in memory, and the peak, so tests can check N6 (memory bounded by
/// a few chunks, not the file size). Only buffers the transfer itself makes are counted; the test also measures
/// the process footprint where the platform reports it.
public final class TransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highest = 0

    public init() {}

    public var peakBytes: Int { lock.withLock { highest } }
    public var currentBytes: Int { lock.withLock { current } }

    func hold(_ bytes: Int) {
        lock.withLock {
            current += bytes
            highest = max(highest, current)
        }
    }

    func release(_ bytes: Int) {
        lock.withLock { current -= bytes }
    }

    public func reset() {
        lock.withLock {
            current = 0
            highest = 0
        }
    }
}

/// Moves blobs between the local cache and the relay, one sealed chunk at a time (design §6).
///
/// - Upload: asks the relay which chunks it has, then sends only the missing ones (N5).
/// - Download: resumes from the last whole chunk in the `.partial` file, opens each chunk (GCM checks it belongs
///   to this item, blob, index and size) before writing it, and publishes the file only after its SHA-256
///   matches the item (N12).
/// - Memory: at most one plaintext and one sealed chunk per transfer (N6).
///
/// An actor so that two requests for the same download share one transfer instead of fighting over the file.
public actor BlobTransferer {
    public let cache: BlobCache
    public let meter: TransferMeter
    private let transport: any BlobTransport
    private let vaultKey: VaultKey
    /// Downloads in flight, each with the callers waiting on it. Cancelled only when every waiter has left.
    private var downloads: [BlobID: (task: Task<URL, Error>, waiters: Set<UUID>)] = [:]

    public init(cache: BlobCache, transport: any BlobTransport, vaultKey: VaultKey, meter: TransferMeter = TransferMeter()) {
        self.cache = cache
        self.transport = transport
        self.vaultKey = vaultKey
        self.meter = meter
    }

    /// Checks a blob reference from a (decrypted, so trusted-to-be-from-the-vault) op against the wire limits
    /// before acting on it, so a buggy or hostile device can't make this one allocate or loop without bound.
    public static func isValid(_ ref: BlobRef) -> Bool {
        ref.size >= 0 && ref.size <= WireLimits.maxBlobBytes
            && ref.chunkSize > 0 && ref.chunkSize <= WireLimits.blobChunkPlaintextBytes
            && ref.chunkCount <= WireLimits.maxBlobChunks
            && ref.sha256.count == 32
    }

    // MARK: Upload

    public enum UploadOutcome: Equatable, Sendable {
        /// The relay now holds every chunk. `resumedFrom` chunks were already there.
        case uploaded(resumedFrom: Int)
        /// No copy on this device, so nothing to send.
        case noLocalCopy
    }

    public func upload(_ ref: BlobRef, item: ItemID, progress: BlobProgressHandler? = nil) async throws -> UploadOutcome {
        guard Self.isValid(ref) else { throw BlobTransferError.invalidBlobRef }
        guard cache.contains(ref.id) else { return .noLocalCopy }
        let blobID = ref.id.description
        var received = Set<Int>()
        if let status = try await transport.blobStatus(blobID: blobID) {
            guard status.chunkCount == ref.chunkCount else { throw BlobTransferError.relayCountMismatch }
            received = Set(status.received)
        }
        let resumedFrom = received.count
        let cipher = BlobCipher(vaultKey: vaultKey, item: item, blob: ref)
        var done = resumedFrom
        progress?(BlobProgress(blob: ref.id, done: done, total: ref.chunkCount, resumedFrom: resumedFrom))
        for index in 0..<ref.chunkCount where !received.contains(index) {
            try Task.checkCancellation()
            let sealed = try sealChunk(index, of: ref, with: cipher)
            meter.hold(sealed.count)
            defer { meter.release(sealed.count) }
            try await transport.putBlobChunk(blobID: blobID, index: index, count: ref.chunkCount, data: sealed)
            done += 1
            progress?(BlobProgress(blob: ref.id, done: done, total: ref.chunkCount, resumedFrom: resumedFrom))
        }
        return .uploaded(resumedFrom: resumedFrom)
    }

    /// Reads and seals one chunk. The plaintext is released before the upload starts, so a transfer holds one
    /// plaintext chunk only while sealing.
    private func sealChunk(_ index: Int, of ref: BlobRef, with cipher: BlobCipher) throws -> Data {
        try withAutoreleasePool {
            let length = ref.plaintextLength(ofChunk: index)
            let plaintext = try cache.readChunk(of: ref.id, index: index, chunkSize: ref.chunkSize, length: length)
            meter.hold(plaintext.count)
            defer { meter.release(plaintext.count) }
            return try cipher.seal(plaintext, index: index)
        }
    }

    // MARK: Download

    /// Returns the blob's file in the cache, downloading (or resuming) it first if needed.
    public func download(_ ref: BlobRef, item: ItemID, progress: BlobProgressHandler? = nil) async throws -> URL {
        guard Self.isValid(ref) else { throw BlobTransferError.invalidBlobRef }
        if cache.contains(ref.id) { return cache.url(for: ref.id) }
        let waiter = UUID()
        let task: Task<URL, Error>
        if let running = downloads[ref.id] {
            task = running.task
            downloads[ref.id]?.waiters.insert(waiter)
        } else {
            task = Task { try await self.performDownload(ref, item: item, progress: progress) }
            downloads[ref.id] = (task, [waiter])
        }
        defer { leave(ref.id, waiter, cancelling: false) }
        let id = ref.id
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(id, waiter, cancelling: true) }
        }
    }

    /// One caller stops waiting. A cancelled caller cancels the download only if nobody else still wants it.
    private func leave(_ blob: BlobID, _ waiter: UUID, cancelling: Bool) {
        guard var entry = downloads[blob], entry.waiters.remove(waiter) != nil else { return }
        if entry.waiters.isEmpty {
            if cancelling { entry.task.cancel() }
            downloads[blob] = nil
        } else {
            downloads[blob] = entry
        }
    }

    private func performDownload(_ ref: BlobRef, item: ItemID, progress: BlobProgressHandler?) async throws -> URL {
        let download = try cache.beginDownload(ref)
        defer { download.close() }
        let cipher = BlobCipher(vaultKey: vaultKey, item: item, blob: ref)
        let blobID = ref.id.description
        let resumedFrom = download.verifiedChunks
        progress?(BlobProgress(blob: ref.id, done: resumedFrom, total: ref.chunkCount, resumedFrom: resumedFrom))
        while !download.isComplete {
            try Task.checkCancellation()
            let index = download.verifiedChunks
            // The sealed size is exact (plaintext plus nonce and tag), so anything else is refused, and a body
            // over it is cut off while it's read rather than after (a hostile relay can't make this buffer more).
            let expected = ref.plaintextLength(ofChunk: index) + WireLimits.blobChunkOverheadBytes
            let fetched: Data?
            do {
                fetched = try await transport.blobChunk(blobID: blobID, index: index, maxBytes: expected)
            } catch TransportError.responseTooLarge {
                throw BlobTransferError.corruptChunk(index: index)
            }
            guard let sealed = fetched else { throw BlobTransferError.notUploadedYet(chunk: index) }
            guard sealed.count == expected else { throw BlobTransferError.corruptChunk(index: index) }
            meter.hold(sealed.count)
            defer { meter.release(sealed.count) }
            let plaintext: Data
            do {
                plaintext = try cipher.open(sealed, index: index)
            } catch {
                throw BlobTransferError.corruptChunk(index: index)
            }
            meter.hold(plaintext.count)
            defer { meter.release(plaintext.count) }
            try download.append(plaintext)
            progress?(BlobProgress(blob: ref.id, done: download.verifiedChunks, total: ref.chunkCount, resumedFrom: resumedFrom))
        }
        return try download.finish()
    }
}
