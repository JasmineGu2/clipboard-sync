import ClipCore
import CSQLite
import Foundation

/// A SQLite failure: the result code and SQLite's message.
public struct StoreError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "SQLite error \(code): \(message)" }
}

/// Local op log plus the materialized items and their full-text index. See docs/design.md §4.
///
/// One connection, guarded by a lock, so calls from any thread are serialized.
/// Every mutation runs in a transaction; with WAL this gives crash safety (PRD N12).
public final class ClipDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Test hook: runs inside `insertRemote`'s transaction, just before the commit.
    var beforeCommitHook: (() throws -> Void)?

    private static let cursorKey = "sync_cursor"

    public init(path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.isoWithFraction))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Self.isoWithFraction.parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad ISO-8601 date \(string)"))
        }
        self.encoder = encoder
        self.decoder = decoder

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw StoreError(code: rc, message: "open \(path): \(message)")
        }
        db = handle
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
            try migrate()
        } catch {
            close()
            throw error
        }
    }

    public convenience init(url: URL) throws {
        let path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        try self.init(path: path)
    }

    /// A private in-memory database (tests, previews).
    public static func inMemory() throws -> ClipDatabase {
        try ClipDatabase(path: ":memory:")
    }

    deinit { close() }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        for stmt in statements.values { sqlite3_finalize(stmt) }
        statements = [:]
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: Writes

    /// Stores unseen ops and re-folds the items they touch, in one transaction.
    /// Returns the ops that were new; duplicates are ignored. `outbound: true` queues them for push.
    @discardableResult
    public func insert(_ ops: [Op], outbound: Bool) throws -> [Op] {
        try locked {
            try inTransaction { try insertOps(ops, outbound: outbound) }
        }
    }

    /// Stores ops pulled from the relay and moves the sync cursor in the same transaction (PRD N12).
    @discardableResult
    public func insertRemote(_ ops: [Op], newCursor: Int64) throws -> [Op] {
        try locked {
            try inTransaction {
                let inserted = try insertOps(ops, outbound: false)
                try writeMeta(Self.cursorKey, String(newCursor))
                try beforeCommitHook?()
                return inserted
            }
        }
    }

    /// Rebuilds every item and the search index from the op log. A repair tool; also used by tests.
    public func refoldAll() throws {
        try locked {
            try inTransaction {
                var folded: [ItemID: ItemState] = [:]
                var order: [ItemID] = []
                try query("SELECT body FROM ops ORDER BY rowid") { stmt in
                    let op = try decoder.decode(Op.self, from: columnData(stmt, 0))
                    if folded[op.itemID] == nil {
                        folded[op.itemID] = ItemState(id: op.itemID)
                        order.append(op.itemID)
                    }
                    folded[op.itemID]!.apply(op)
                }
                try run("DELETE FROM items_fts")
                try run("DELETE FROM items")
                for id in order { try writeState(folded[id]!) }
            }
        }
    }

    /// Clears the outbound flag once the relay has accepted these ops.
    public func markSent(_ ids: [OpID]) throws {
        try locked {
            try inTransaction {
                for id in ids {
                    try run("UPDATE ops SET outbound_pending = 0 WHERE op_id = ?", [.text(id.description)])
                }
            }
        }
    }

    public func setSyncCursor(_ cursor: Int64) throws {
        try locked { try writeMeta(Self.cursorKey, String(cursor)) }
    }

    /// Sets a meta value; nil removes the key.
    public func setMeta(_ key: String, _ value: String?) throws {
        try locked { try writeMeta(key, value) }
    }

    // MARK: Reads

    /// Visible items, newest first by create timestamp.
    public func items(limit: Int = 100, offset: Int = 0) throws -> [ItemState] {
        try locked {
            try states(
                """
                SELECT state FROM items WHERE visible = 1
                ORDER BY created_wall DESC, created_counter DESC, created_device DESC
                LIMIT ? OFFSET ?
                """,
                [.int(Int64(limit)), .int(Int64(offset))]
            )
        }
    }

    /// The stored state of one item, visible or not; nil if no op for it has been seen.
    public func item(_ id: ItemID) throws -> ItemState? {
        try locked {
            try states("SELECT state FROM items WHERE item_id = ?", [.text(id.description)]).first
        }
    }

    /// Full-text search over text, title and tags. Each word is a prefix match; all words must match.
    /// Ranked by bm25, then newest first. An empty query returns `items(limit:)`.
    public func search(_ query: String, limit: Int = 100) throws -> [ItemState] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
            .filter { word in word.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
        if tokens.isEmpty {
            if query.allSatisfy(\.isWhitespace) { return try items(limit: limit) }
            return []  // only punctuation or symbols: nothing the tokenizer indexes
        }
        let match = tokens
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " AND ")
        return try locked {
            try states(
                """
                SELECT i.state FROM items_fts f JOIN items i ON i.rowid = f.rowid
                WHERE items_fts MATCH ? AND i.visible = 1
                ORDER BY bm25(items_fts, 0.0, 1.0, 2.0, 2.0),
                         i.created_wall DESC, i.created_counter DESC, i.created_device DESC
                LIMIT ?
                """,
                [.text(match), .int(Int64(limit))]
            )
        }
    }

    /// Ops waiting to be pushed, oldest first.
    public func pendingOutbound(limit: Int = 500) throws -> [Op] {
        try locked {
            var ops: [Op] = []
            try query("SELECT body FROM ops WHERE outbound_pending = 1 ORDER BY rowid LIMIT ?", [.int(Int64(limit))]) { stmt in
                ops.append(try decoder.decode(Op.self, from: columnData(stmt, 0)))
            }
            return ops
        }
    }

    /// The relay sequence number this device has pulled up to (0 before the first pull).
    public func syncCursor() throws -> Int64 {
        try locked { try readMeta(Self.cursorKey).flatMap(Int64.init) ?? 0 }
    }

    public func meta(_ key: String) throws -> String? {
        try locked { try readMeta(key) }
    }

    /// Number of visible items.
    public func count() throws -> Int {
        try locked {
            var n = 0
            try query("SELECT count(*) FROM items WHERE visible = 1") { n = Int(sqlite3_column_int64($0, 0)) }
            return n
        }
    }

    // MARK: Schema

    private static let migrations: [String] = [
        """
        CREATE TABLE ops (
            op_id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            ts_wall INTEGER,
            ts_counter INTEGER,
            ts_device TEXT,
            body BLOB NOT NULL, -- JSON-encoded Op
            outbound_pending INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX ops_item ON ops(item_id);
        CREATE INDEX ops_outbound ON ops(outbound_pending) WHERE outbound_pending = 1;

        CREATE TABLE items (
            item_id TEXT PRIMARY KEY,
            state BLOB NOT NULL, -- JSON-encoded ItemState
            visible INTEGER,
            pinned INTEGER,
            created_wall INTEGER,
            created_counter INTEGER,
            created_device TEXT,
            preview TEXT
        );
        CREATE INDEX items_newest ON items(created_wall DESC, created_counter DESC, created_device DESC)
            WHERE visible = 1;

        -- rowid matches items.rowid so a row can be replaced without scanning.
        CREATE VIRTUAL TABLE items_fts USING fts5(
            item_id UNINDEXED, text, title, tags,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        """,
    ]

    private func migrate() throws {
        var version = 0
        try query("PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
        guard version < Self.migrations.count else { return }
        try inTransaction {
            for index in version..<Self.migrations.count {
                try exec(Self.migrations[index])
            }
            try exec("PRAGMA user_version = \(Self.migrations.count)")
        }
    }

    // MARK: Internals (lock held)

    private func insertOps(_ ops: [Op], outbound: Bool) throws -> [Op] {
        var inserted: [Op] = []
        var newOps: [ItemID: [Op]] = [:]
        var order: [ItemID] = []
        for op in ops {
            try run(
                """
                INSERT OR IGNORE INTO ops (op_id, item_id, ts_wall, ts_counter, ts_device, body, outbound_pending)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(op.id.description), .text(op.itemID.description),
                    .int(Int64(bitPattern: op.timestamp.wallMillis)), .int(Int64(op.timestamp.counter)),
                    .text(op.timestamp.device.description), .blob(encoder.encode(op)),
                    .int(outbound ? 1 : 0),
                ]
            )
            guard sqlite3_changes(db) > 0 else { continue }
            inserted.append(op)
            if newOps[op.itemID] == nil { order.append(op.itemID) }
            newOps[op.itemID, default: []].append(op)
        }
        // Merge is commutative and idempotent, so folding only the new ops into the stored state
        // gives the same result as refolding the item's whole history.
        for id in order {
            var state = try states("SELECT state FROM items WHERE item_id = ?", [.text(id.description)]).first
                ?? ItemState(id: id)
            for op in newOps[id]! { state.apply(op) }
            try writeState(state)
        }
        return inserted
    }

    private func writeState(_ state: ItemState) throws {
        let created = state.createdBy
        var rowid: Int64 = 0
        try query(
            """
            INSERT INTO items (item_id, state, visible, pinned, created_wall, created_counter, created_device, preview)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                state = excluded.state, visible = excluded.visible, pinned = excluded.pinned,
                created_wall = excluded.created_wall, created_counter = excluded.created_counter,
                created_device = excluded.created_device, preview = excluded.preview
            RETURNING rowid
            """,
            [
                .text(state.id.description), .blob(encoder.encode(state)),
                .int(state.isVisible ? 1 : 0), .int(state.pinned.value ? 1 : 0),
                created.map { SQLValue.int(Int64(bitPattern: $0.wallMillis)) } ?? SQLValue.null,
                created.map { SQLValue.int(Int64($0.counter)) } ?? SQLValue.null,
                created.map { SQLValue.text($0.device.description) } ?? SQLValue.null,
                state.content.map { SQLValue.text(String($0.text.prefix(200))) } ?? SQLValue.null,
            ]
        ) { rowid = sqlite3_column_int64($0, 0) }

        try run("DELETE FROM items_fts WHERE rowid = ?", [.int(rowid)])
        if state.isVisible, let content = state.content {
            try run(
                "INSERT INTO items_fts (rowid, item_id, text, title, tags) VALUES (?, ?, ?, ?, ?)",
                [
                    .int(rowid), .text(state.id.description), .text(content.text),
                    .text(state.title.value ?? ""), .text(state.visibleTags.joined(separator: " ")),
                ]
            )
        }
    }

    private func readMeta(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = columnText($0, 0) }
        return value
    }

    private func writeMeta(_ key: String, _ value: String?) throws {
        if let value {
            try run(
                "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    private func states(_ sql: String, _ args: [SQLValue]) throws -> [ItemState] {
        var result: [ItemState] = []
        try query(sql, args) { stmt in
            result.append(try decoder.decode(ItemState.self, from: columnData(stmt, 0)))
        }
        return result
    }

    // MARK: SQLite plumbing (lock held)

    private enum SQLValue {
        case int(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    /// SQLITE_TRANSIENT: SQLite copies bound text and blobs before the bind call returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { throw StoreError(code: SQLITE_MISUSE, message: "database is closed") }
        return try body()
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// For fixed SQL with no parameters (pragmas, schema, transaction control).
    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorMessage)
            throw StoreError(code: rc, message: message)
        }
    }

    private func run(_ sql: String, _ args: [SQLValue] = []) throws {
        try query(sql, args) { _ in }
    }

    private func query(_ sql: String, _ args: [SQLValue] = [], row: (OpaquePointer) throws -> Void) throws {
        let stmt = try prepared(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, index, v)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, index, s, Int32(s.utf8.count), Self.transient)
            case .blob(let data):
                rc = data.withUnsafeBytes { bytes in
                    bytes.count == 0
                        ? sqlite3_bind_zeroblob(stmt, index, 0)
                        : sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null:
                rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else { throw StoreError(code: rc, message: lastErrorMessage()) }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw StoreError(code: rc, message: lastErrorMessage())
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let stmt = statements[sql] { return stmt }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw StoreError(code: rc, message: lastErrorMessage()) }
        statements[sql] = stmt
        return stmt
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func columnData(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: cString, count: count), as: UTF8.self)
    }
}
