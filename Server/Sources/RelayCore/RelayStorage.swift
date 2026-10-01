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

/// Persistence for the relay. The server only ever sees ciphertext and routing IDs.
public protocol RelayStorage: Actor {
    /// Appends envelopes in one transaction. Envelopes whose opID is already stored are ignored,
    /// so client retries are safe.
    func append(_ envelopes: [Envelope]) throws -> AppendResult
    /// Envelopes with seq > `after`, ascending, at most `limit`.
    func page(after: Int64, limit: Int) throws -> LogPage
    func latestSeq() throws -> Int64

    /// Stores (or overwrites) a pairing blob.
    func putPairing(id: String, blob: Data, expiresAt: Int64, now: Int64) throws
    /// Returns the blob once and deletes it. nil when missing or expired.
    func takePairing(id: String, now: Int64) throws -> Data?

    /// Stores `hash` as the auth token hash if none is stored yet (trust on first use).
    /// Returns the stored hash, which is `hash` on first use.
    func adoptAuthTokenHash(_ hash: String) throws -> String
}

public struct StorageError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}
