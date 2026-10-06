import ClipWire
import Foundation

/// Result of appending envelopes to the log.
public struct AppendResult: Sendable, Equatable {
    /// Envelopes actually inserted (duplicates by opID are ignored).
    public var inserted: Int
    /// Highest seq in the log after the append (0 when empty).
    public var latestSeq: Int64
}

/// One page of the log.
public struct LogPage: Sendable, Equatable {
    /// seq > after, ascending, each with `seq` set.
    public var envelopes: [Envelope]
    /// True when more envelopes exist after the last one returned.
    public var hasMore: Bool
    /// Highest seq in the log at the time of the query.
    public var latestSeq: Int64
}

/// Outcome of storing a pairing blob.
public enum PairingPutResult: Sendable, Equatable {
    case stored
    /// An unexpired blob already uses this ID (HTTP 409).
    case idTaken
    /// The relay already holds `maxLive` unexpired blobs (HTTP 429).
    case full
}

/// Outcome of storing one blob chunk.
public enum BlobChunkPutResult: Sendable, Equatable {
    case stored
    /// That chunk was already stored; the first copy is kept (HTTP 204 all the same, so retries are safe).
    case alreadyStored
    /// The blob's first chunk gave a different chunk count (HTTP 409).
    case countMismatch(existing: Int)
    /// Storing it would pass the relay's blob storage cap (HTTP 507).
    case full
}

/// What a stale-blob purge removed.
public struct BlobPurgeResult: Sendable, Equatable {
    public var blobs = 0
    public var bytes: Int64 = 0
    public init(blobs: Int = 0, bytes: Int64 = 0) {
        self.blobs = blobs
        self.bytes = bytes
    }
}

/// Outcome of storing a device record.
public enum DevicePutResult: Sendable, Equatable {
    case stored
    /// The relay already holds a different public key for this device ID (HTTP 409). A device keeps one key for
    /// life, so this is someone else claiming its ID.
    case keyMismatch
    /// The relay already holds `maxDevices` records (HTTP 429).
    case full
}

/// Persistence for the relay. The server only ever sees ciphertext and routing IDs.
public protocol RelayStorage: Actor {
    /// Appends envelopes in one transaction. Envelopes whose opID is already stored are ignored,
    /// so client retries are safe.
    func append(_ envelopes: [Envelope]) throws -> AppendResult
    /// `append`, but only if `tokenHash` is still the stored auth hash, checked in the same transaction.
    /// Throws `AuthChanged` otherwise, so a push authorized just before a revoke can't land after it.
    func append(_ envelopes: [Envelope], requiringTokenHash tokenHash: String) throws -> AppendResult
    /// Envelopes with seq > `after`, ascending, at most `limit`.
    func page(after: Int64, limit: Int) throws -> LogPage
    func latestSeq() throws -> Int64
    /// This database's epoch: a random UUID string made when the database is first created, then never changed.
    /// Clients compare it across responses to notice that the relay lost its log (design §4).
    func epoch() throws -> String

    /// Purges expired blobs, then inserts this one unless the ID is taken or `maxLive` blobs are held.
    /// Never overwrites: a second PUT to a live ID is refused, so nobody can swap a parked key.
    func putPairing(id: String, blob: Data, expiresAt: Int64, now: Int64, maxLive: Int) throws -> PairingPutResult
    /// Returns the blob once and deletes it. nil when missing or expired.
    func takePairing(id: String, now: Int64) throws -> Data?

    // Every blob method takes the token hash its request was authorized with and refuses (`AuthChanged`) when the
    // stored hash differs, checked in the same storage call: a request authorized just before a revoke must not
    // touch blobs after it. An upload that slipped through would plant a chunk under the old vault key, and since
    // the first copy of a chunk is kept, the re-upload under the new key would be ignored. nil skips the check.

    /// Stores one sealed blob chunk. The first chunk of a blob fixes its chunk count. Refuses (`.full`) when the
    /// blob bytes stored would pass `maxTotalBytes`.
    func putBlobChunk(
        blobID: String, index: Int, count: Int, data: Data, now: Int64, maxTotalBytes: Int64,
        requiringTokenHash tokenHash: String?
    ) throws -> BlobChunkPutResult
    /// The blob's chunk count and the indexes stored, ascending; nil when no chunk of it is stored.
    func blobStatus(blobID: String, requiringTokenHash tokenHash: String?) throws -> (chunkCount: Int, received: [Int])?
    /// One stored chunk's bytes, or nil.
    func blobChunk(blobID: String, index: Int, requiringTokenHash tokenHash: String?) throws -> Data?
    /// Removes a blob and all its chunks. Removing a missing blob is not an error.
    func deleteBlob(blobID: String, requiringTokenHash tokenHash: String?) throws
    /// Total bytes of every stored chunk. A running total kept in the same transaction as every change to the
    /// chunks (upload, delete, purge, revoke), so reading it is O(1).
    func blobBytesStored() throws -> Int64
    /// Removes, in one transaction, every blob that is still incomplete (fewer chunks than its count) and had no
    /// chunk uploaded since `cutoff` (unix seconds): an upload abandoned by a device that went away, or whose item
    /// was deleted mid-upload. Complete blobs are never purged by age: the relay can't tell whether an item still
    /// uses one (design §6).
    func purgeStaleBlobs(untouchedSince cutoff: Int64) throws -> BlobPurgeResult

    /// The stored auth token hash, or nil if none has been set or adopted yet.
    func authTokenHash() throws -> String?
    /// Stores `hash` as the auth token hash if none is stored yet (trust on first use).
    /// Returns the stored hash, which is `hash` on first use.
    func adoptAuthTokenHash(_ hash: String) throws -> String
    /// Replaces the stored hash (token rotation).
    func setAuthTokenHash(_ hash: String) throws
    /// Applies an operator-pinned hash (`--token-sha256`) and returns the hash now in force.
    /// The pin is written once per distinct value: if the same value was already applied, a hash rotated
    /// since then is kept, so a restart doesn't undo a revocation. A new pin value always wins.
    func seedAuthTokenHash(_ hash: String) throws -> String

    /// Inserts or replaces a device record, unless a different public key is stored for that ID or `maxDevices`
    /// other records are held.
    func putDevice(_ record: DeviceRecord, maxDevices: Int) throws -> DevicePutResult
    /// Every device record, ordered by device ID.
    func devices() throws -> [DeviceRecord]
    /// Handoff blobs for one device, oldest first.
    func handoffs(deviceID: String) throws -> [Data]
    /// Revocation, in one transaction: stores `newTokenHash`, deletes every envelope, pairing blob and image or file
    /// blob (all sealed under the old vault key; remaining devices re-upload what they hold), makes a new
    /// epoch, replaces the device table with `devices`, deletes handoffs for devices not in it, appends `handoffs`,
    /// and keeps at most `maxHandoffsPerDevice` per device (the newest). Returns the new epoch.
    /// With `expectedDeviceIDs`, throws `DeviceListChanged` (and changes nothing) unless the stored device IDs are
    /// exactly those: a device that registered after the revoker read the list would otherwise be dropped.
    func revoke(
        newTokenHash: String, devices: [DeviceRecord], handoffs: [Handoff], maxHandoffsPerDevice: Int,
        expectedDeviceIDs: [String]?
    ) throws -> String
}

extension RelayStorage {
    /// The blob methods without a token check, for tests and tools that talk to storage directly.
    public func putBlobChunk(
        blobID: String, index: Int, count: Int, data: Data, now: Int64, maxTotalBytes: Int64
    ) throws -> BlobChunkPutResult {
        try putBlobChunk(
            blobID: blobID, index: index, count: count, data: data, now: now, maxTotalBytes: maxTotalBytes,
            requiringTokenHash: nil)
    }

    public func blobStatus(blobID: String) throws -> (chunkCount: Int, received: [Int])? {
        try blobStatus(blobID: blobID, requiringTokenHash: nil)
    }

    public func blobChunk(blobID: String, index: Int) throws -> Data? {
        try blobChunk(blobID: blobID, index: index, requiringTokenHash: nil)
    }

    public func deleteBlob(blobID: String) throws {
        try deleteBlob(blobID: blobID, requiringTokenHash: nil)
    }
}

/// The auth hash changed between a request's auth check and its write (a revoke landed in between).
public struct AuthChanged: Error {}
/// The device list changed since the revoker read it.
public struct DeviceListChanged: Error {}

public struct StorageError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}
