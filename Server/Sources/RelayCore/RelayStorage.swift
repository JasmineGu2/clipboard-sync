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

/// Persistence for the relay. The server only ever sees ciphertext and routing IDs.
public protocol RelayStorage: Actor {
    /// Appends envelopes in one transaction. Envelopes whose opID is already stored are ignored,
    /// so client retries are safe.
    func append(_ envelopes: [Envelope]) throws -> AppendResult
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
}

public struct StorageError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}
