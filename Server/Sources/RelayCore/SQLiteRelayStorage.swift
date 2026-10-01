import ClipWire
import Foundation
import RelaySQLite

/// SQLite-backed storage. The actor serializes all access to the one connection.
public actor SQLiteRelayStorage: RelayStorage {
    /// `nonisolated(unsafe)` only so `deinit` (which is nonisolated) can close it. Every other use is on the actor,
    /// and deinit runs when no other reference, and so no other access, can exist.
    private nonisolated(unsafe) let db: OpaquePointer
    static let authTokenKey = "auth_token_sha256"
    /// The last operator pin applied (see `seedAuthTokenHash`).
    static let authSeedKey = "auth_token_seed_sha256"

    /// Opens (creating if needed) the database at `path`. Use ":memory:" for tests.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(handle)
            throw StorageError(code: rc, message: message)
        }
        do {
            try Self.exec(handle, """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA busy_timeout = 5000;
                CREATE TABLE IF NOT EXISTS envelopes(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    op_id TEXT UNIQUE NOT NULL,
                    item_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    ciphertext BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pairing(
                    id TEXT PRIMARY KEY,
                    blob BLOB NOT NULL,
                    expires_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS meta(
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        self.db = handle
    }

    public static func inMemory() throws -> SQLiteRelayStorage {
        try SQLiteRelayStorage(path: ":memory:")
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: Envelopes

    public func append(_ envelopes: [Envelope]) throws -> AppendResult {
        var inserted = 0
        if !envelopes.isEmpty {
            try transaction {
                // Skip known opIDs before inserting rather than relying on INSERT OR IGNORE: an ignored insert
                // still uses up an AUTOINCREMENT value, which would leave gaps in seq.
                let exists = try Statement(db, "SELECT 1 FROM envelopes WHERE op_id = ?")
                let insert = try Statement(db, """
                    INSERT INTO envelopes(op_id, item_id, device_id, ciphertext) VALUES(?, ?, ?, ?)
                    """)
                for envelope in envelopes {
                    try exists.reset()
                    try exists.bind(1, envelope.opID)
                    if try exists.step() { continue }
                    try insert.reset()
                    try insert.bind(1, envelope.opID)
                    try insert.bind(2, envelope.itemID)
                    try insert.bind(3, envelope.deviceID)
                    try insert.bind(4, envelope.ciphertext)
                    _ = try insert.step()
                    inserted += 1
                }
            }
        }
        return AppendResult(inserted: inserted, latestSeq: try latestSeq())
    }

    public func page(after: Int64, limit: Int) throws -> LogPage {
        let limit = max(1, limit)
        let query = try Statement(db, """
            SELECT seq, op_id, item_id, device_id, ciphertext FROM envelopes
            WHERE seq > ? ORDER BY seq ASC LIMIT ?
            """)
        try query.bind(1, after)
        try query.bind(2, Int64(limit) + 1)  // one extra row tells us hasMore
        var rows: [Envelope] = []
        while try query.step() {
            rows.append(Envelope(
                opID: query.text(1),
                itemID: query.text(2),
                deviceID: query.text(3),
                ciphertext: query.blob(4),
                seq: query.int64(0)
            ))
        }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast(rows.count - limit) }
        return LogPage(envelopes: rows, hasMore: hasMore, latestSeq: try latestSeq())
    }

    public func latestSeq() throws -> Int64 {
        let query = try Statement(db, "SELECT COALESCE(MAX(seq), 0) FROM envelopes")
        _ = try query.step()
        return query.int64(0)
    }

    // MARK: Pairing

    public func putPairing(
        id: String, blob: Data, expiresAt: Int64, now: Int64, maxLive: Int
    ) throws -> PairingPutResult {
        var result = PairingPutResult.stored
        try transaction {
            try purgeExpiredPairings(now: now)
            // After the purge every remaining row is live, so these checks need no expiry filter.
            let exists = try Statement(db, "SELECT 1 FROM pairing WHERE id = ?")
            try exists.bind(1, id)
            if try exists.step() {
                result = .idTaken
                return
            }
            let count = try Statement(db, "SELECT COUNT(*) FROM pairing")
            _ = try count.step()
            if count.int64(0) >= Int64(maxLive) {
                result = .full
                return
            }
            let put = try Statement(db, "INSERT INTO pairing(id, blob, expires_at) VALUES(?, ?, ?)")
            try put.bind(1, id)
            try put.bind(2, blob)
            try put.bind(3, expiresAt)
            _ = try put.step()
        }
        return result
    }

    public func takePairing(id: String, now: Int64) throws -> Data? {
        var result: Data?
        try transaction {
            try purgeExpiredPairings(now: now)
            let get = try Statement(db, "SELECT blob, expires_at FROM pairing WHERE id = ?")
            try get.bind(1, id)
            guard try get.step() else { return }
            let blob = get.blob(0)
            let expiresAt = get.int64(1)
            let delete = try Statement(db, "DELETE FROM pairing WHERE id = ?")
            try delete.bind(1, id)
            _ = try delete.step()
            if expiresAt > now { result = blob }
        }
        return result
    }

    private func purgeExpiredPairings(now: Int64) throws {
        let purge = try Statement(db, "DELETE FROM pairing WHERE expires_at <= ?")
        try purge.bind(1, now)
        _ = try purge.step()
    }

    // MARK: Auth

    public func authTokenHash() throws -> String? {
        try readMeta(Self.authTokenKey)
    }

    public func adoptAuthTokenHash(_ hash: String) throws -> String {
        let insert = try Statement(db, "INSERT OR IGNORE INTO meta(key, value) VALUES(?, ?)")
        try insert.bind(1, Self.authTokenKey)
        try insert.bind(2, hash)
        _ = try insert.step()
        guard let stored = try readMeta(Self.authTokenKey) else {
            throw StorageError(code: SQLITE_ERROR, message: "auth token hash missing after insert")
        }
        return stored
    }

    public func setAuthTokenHash(_ hash: String) throws {
        try writeMeta(Self.authTokenKey, hash)
    }

    public func seedAuthTokenHash(_ hash: String) throws -> String {
        var current = hash
        try transaction {
            if try readMeta(Self.authSeedKey) == hash, let stored = try readMeta(Self.authTokenKey) {
                current = stored  // same pin as last time: keep any rotation made since
                return
            }
            try writeMeta(Self.authTokenKey, hash)
            try writeMeta(Self.authSeedKey, hash)
        }
        return current
    }

    private func readMeta(_ key: String) throws -> String? {
        let select = try Statement(db, "SELECT value FROM meta WHERE key = ?")
        try select.bind(1, key)
        guard try select.step() else { return nil }
        return select.text(0)
    }

    private func writeMeta(_ key: String, _ value: String) throws {
        let upsert = try Statement(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
        try upsert.bind(1, key)
        try upsert.bind(2, value)
        _ = try upsert.step()
    }

    // MARK: Diagnostics

    /// The connection's journal mode ("wal" for file databases, "memory" for in-memory ones).
    func journalMode() throws -> String {
        let query = try Statement(db, "PRAGMA journal_mode")
        _ = try query.step()
        return query.text(0)
    }

    // MARK: Helpers

    private func transaction(_ body: () throws -> Void) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw StorageError(code: rc, message: message)
        }
    }
}

/// A prepared statement. Used only inside the storage actor.
private final class Statement {
    private let db: OpaquePointer
    private let handle: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StorageError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        self.db = db
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// SQLITE_TRANSIENT: SQLite copies the bound bytes before the call returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func reset() throws {
        sqlite3_reset(handle)
        try check(sqlite3_clear_bindings(handle))
    }

    /// Binds the string's exact UTF-8 bytes. Passing the real length (never -1) means SQLite doesn't scan for
    /// a NUL terminator, so the stored text is exactly what was validated.
    func bind(_ index: Int32, _ value: String) throws {
        var value = value
        let handle = self.handle
        let rc = value.withUTF8 { bytes -> Int32 in
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                // A nil pointer would bind NULL; bind empty text instead.
                return sqlite3_bind_text(handle, index, "", 0, Self.transient)
            }
            return base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                sqlite3_bind_text(handle, index, $0, Int32(bytes.count), Self.transient)
            }
        }
        try check(rc)
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ index: Int32, _ value: Data) throws {
        if value.isEmpty {
            // A nil pointer would bind NULL; bind an empty blob instead.
            try check(sqlite3_bind_zeroblob(handle, index, 0))
            return
        }
        try value.withUnsafeBytes { raw in
            try check(sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), Self.transient))
        }
    }

    /// Returns true when a row is available, false when done.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StorageError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    /// Reads the column's exact byte length rather than stopping at the first NUL.
    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else {
            throw StorageError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}
