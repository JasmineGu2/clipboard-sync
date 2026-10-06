import ClipCore
import CSQLite
import Foundation

/// A blob this device has to upload, and the item it belongs to.
public struct BlobUpload: Hashable, Sendable {
    public var blob: BlobID
    public var item: ItemID
    public init(blob: BlobID, item: ItemID) {
        self.blob = blob
        self.item = item
    }
}

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
/// Every mutation runs in a transaction. WAL with `synchronous = FULL` makes each commit durable once the call
/// returns, so a copied clip or a queued outbound op survives power loss (PRD N12).
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
        // Shared with ClipCrypto so stored and synced copies encode identically (see ClipCoding).
        let encoder = ClipCoding.makeEncoder()
        let decoder = ClipCoding.makeDecoder()
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
            try exec("PRAGMA synchronous = FULL")
            try migrate()
            try createQueryTokenizer()
        } catch {
            close()
            throw error
        }
    }

    public convenience init(url: URL) throws {
        let path = try url.withUnsafeFileSystemRepresentation { pointer -> String in
            guard let pointer else {
                throw StoreError(code: SQLITE_CANTOPEN, message: "no file system path for \(url)")
            }
            return String(cString: pointer)
        }
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
        try insert(ops, outbound: outbound, blobUploads: [])
    }

    /// `insert`, plus queues blob uploads in the same transaction, so a crash can't leave an image or file item
    /// whose payload nobody will ever upload (N12).
    @discardableResult
    public func insert(_ ops: [Op], outbound: Bool, blobUploads: [BlobUpload]) throws -> [Op] {
        try locked {
            try inTransaction {
                let inserted = try insertOps(ops, outbound: outbound)
                for upload in blobUploads {
                    try run(
                        "INSERT OR IGNORE INTO blob_uploads (blob_id, item_id) VALUES (?, ?)",
                        [.text(upload.blob.description), .text(upload.item.description)])
                }
                return inserted
            }
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
                try query("SELECT body FROM ops ORDER BY seq") { stmt in
                    let op = try decoder.decode(Op.self, from: columnData(stmt, 0))
                    if folded[op.itemID] == nil { order.append(op.itemID) }
                    folded[op.itemID, default: ItemState(id: op.itemID)].apply(op)
                }
                try run("DELETE FROM items_fts")
                try run("DELETE FROM items")
                for id in order {
                    if let state = folded[id] { try writeState(state) }
                }
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

    /// Queues every stored op for push again and resets the sync cursor to 0, in one transaction.
    /// Used when the relay lost its log: ops that lived only on the old relay go back up, and the relay
    /// dedupes by opID, so devices re-pushing the same ops is harmless.
    ///
    /// The relay's blobs went with its log, so every visible item's blob is queued for upload too. A device that
    /// doesn't hold a blob's file drops that job (`finishBlobUpload`); one that does puts the blob back.
    public func markAllOutbound() throws {
        try locked {
            try inTransaction {
                try run("UPDATE ops SET outbound_pending = 1 WHERE outbound_pending = 0")
                try writeMeta(Self.cursorKey, "0")
                try run(
                    """
                    INSERT OR IGNORE INTO blob_uploads (blob_id, item_id)
                    SELECT blob_id, item_id FROM items WHERE visible = 1 AND blob_id IS NOT NULL
                    """)
                try run("DELETE FROM blob_relay_gc")
            }
        }
    }

    // MARK: Blobs (F11, F12)

    /// Blob uploads still to do, oldest first.
    public func pendingBlobUploads(limit: Int = 100) throws -> [BlobUpload] {
        try locked {
            var uploads: [BlobUpload] = []
            try query("SELECT blob_id, item_id FROM blob_uploads ORDER BY rowid LIMIT ?", [.int(Int64(limit))]) { stmt in
                if let blob = columnText(stmt, 0).flatMap(UUID.init(uuidString:)),
                   let item = columnText(stmt, 1).flatMap(UUID.init(uuidString:)) {
                    uploads.append(BlobUpload(blob: BlobID(blob), item: ItemID(item)))
                }
            }
            return uploads
        }
    }

    /// Drops an upload job: the relay holds every chunk, the item is gone, or this device has no copy.
    public func finishBlobUpload(_ blob: BlobID) throws {
        try locked { try run("DELETE FROM blob_uploads WHERE blob_id = ?", [.text(blob.description)]) }
    }

    /// Blobs that some visible item points at. Everything else in the blob cache may be collected.
    public func liveBlobIDs() throws -> Set<BlobID> {
        try locked {
            var ids: Set<BlobID> = []
            try query("SELECT blob_id FROM items WHERE visible = 1 AND blob_id IS NOT NULL") { stmt in
                if let id = columnText(stmt, 0).flatMap(UUID.init(uuidString:)) { ids.insert(BlobID(id)) }
            }
            return ids
        }
    }

    /// Blobs of deleted (or expired) items. Deletes are sticky, so these are never needed again on any device.
    /// `uncollectedOnly` leaves out the ones already deleted from the relay (`markRelayCollected`).
    public func deadBlobIDs(uncollectedOnly: Bool = false, limit: Int = 500) throws -> [BlobID] {
        try locked {
            var ids: [BlobID] = []
            let filter = uncollectedOnly ? "AND blob_id NOT IN (SELECT blob_id FROM blob_relay_gc)" : ""
            try query(
                "SELECT blob_id FROM items WHERE visible = 0 AND blob_id IS NOT NULL \(filter) ORDER BY id LIMIT ?",
                [.int(Int64(limit))]
            ) { stmt in
                if let id = columnText(stmt, 0).flatMap(UUID.init(uuidString:)) { ids.append(BlobID(id)) }
            }
            return ids
        }
    }

    /// Remembers that these blobs were deleted from the relay, so garbage collection doesn't ask again.
    public func markRelayCollected(_ blobs: [BlobID]) throws {
        try locked {
            try inTransaction {
                for blob in blobs {
                    try run("INSERT OR IGNORE INTO blob_relay_gc (blob_id) VALUES (?)", [.text(blob.description)])
                    try run("DELETE FROM blob_uploads WHERE blob_id = ?", [.text(blob.description)])
                }
            }
        }
    }

    /// The visible item that points at `blob`, if any.
    public func item(forBlob blob: BlobID) throws -> ItemState? {
        try locked {
            try states("SELECT state FROM items WHERE blob_id = ? AND visible = 1", [.text(blob.description)]).first
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

    /// Every visible pinned item, newest first. Not paged: pinned sets are small, and they must show
    /// however old the items are.
    public func pinnedItems() throws -> [ItemState] {
        try locked {
            try states(
                """
                SELECT state FROM items WHERE visible = 1 AND pinned = 1
                ORDER BY created_wall DESC, created_counter DESC, created_device DESC
                """,
                []
            )
        }
    }

    /// Visible, unpinned items whose create op is older than `cutoffMillis` (F14), oldest first.
    /// Uses the create op's HLC wall time, the same column the history is ordered by.
    public func expiredItemIDs(createdBeforeMillis cutoffMillis: UInt64, limit: Int = 500) throws -> [ItemID] {
        try locked {
            var ids: [ItemID] = []
            try query(
                """
                SELECT item_id FROM items WHERE visible = 1 AND pinned = 0 AND created_wall < ?
                ORDER BY created_wall, created_counter, created_device
                LIMIT ?
                """,
                [.int(Int64(clamping: cutoffMillis)), .int(Int64(limit))]
            ) { stmt in
                if let text = columnText(stmt, 0), let uuid = UUID(uuidString: text) { ids.append(ItemID(uuid)) }
            }
            return ids
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
    /// Words the tokenizer reduces to nothing (punctuation, emoji, lone combining marks) are ignored;
    /// a query made only of such words returns [].
    public func search(_ query: String, limit: Int = 100) throws -> [ItemState] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty { return try items(limit: limit) }
        return try locked {
            let searchable = try wordsWithTokens(words)
            if searchable.isEmpty { return [] }
            let match = searchable
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
                .joined(separator: " AND ")
            return try states(
                """
                SELECT i.state FROM items_fts f JOIN items i ON i.id = f.rowid
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
            try query("SELECT body FROM ops WHERE outbound_pending = 1 ORDER BY seq LIMIT ?", [.int(Int64(limit))]) { stmt in
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

    /// The highest timestamp of any stored op (local or remote), or nil when the log is empty.
    public func maxOpTimestamp() throws -> HLCTimestamp? {
        try locked {
            var body: Data?
            // ts_wall holds the UInt64 bit pattern: values past Int64.max are stored negative, so they sort first.
            try query(
                """
                SELECT body FROM ops
                ORDER BY ts_wall < 0 DESC, ts_wall DESC, ts_counter DESC, ts_device DESC
                LIMIT 1
                """
            ) { body = columnData($0, 0) }
            return try body.map { try decoder.decode(Op.self, from: $0).timestamp }
        }
    }

    /// Test hook: reads an integer pragma on this connection, e.g. "synchronous".
    func pragma(_ name: String) throws -> Int64 {
        try locked {
            var value: Int64 = 0
            try query("PRAGMA \(name)") { value = sqlite3_column_int64($0, 0) }
            return value
        }
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

    private static let tokenizer = "unicode61 remove_diacritics 2"

    /// Schema steps: step N takes the database from user_version N to N + 1. Never edit a shipped step.
    private var migrations: [() throws -> Void] {
        [
            { try self.exec(Self.schemaV1) },
            { try self.exec(Self.schemaV2); try self.reindexAllItems() },
            { try self.exec(Self.schemaV3) },
            { try self.exec(Self.schemaV4) },
        ]
    }

    private static let schemaV1 = """
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
        """

    /// v2: items gets an INTEGER PRIMARY KEY, so its rowids (and the FTS rowids keyed on them) survive VACUUM.
    /// The FTS index is then rebuilt from the stored states, which also repairs a v1 index that a VACUUM
    /// already knocked out of step.
    private static let schemaV2 = """
        CREATE TABLE items_v2 (
            id INTEGER PRIMARY KEY,
            item_id TEXT UNIQUE NOT NULL,
            state BLOB NOT NULL, -- JSON-encoded ItemState
            visible INTEGER,
            pinned INTEGER,
            created_wall INTEGER,
            created_counter INTEGER,
            created_device TEXT,
            preview TEXT
        );
        INSERT INTO items_v2 (item_id, state, visible, pinned, created_wall, created_counter, created_device, preview)
            SELECT item_id, state, visible, pinned, created_wall, created_counter, created_device, preview
            FROM items ORDER BY rowid;
        DROP TABLE items_fts;
        DROP TABLE items;
        ALTER TABLE items_v2 RENAME TO items;
        CREATE INDEX items_newest ON items(created_wall DESC, created_counter DESC, created_device DESC)
            WHERE visible = 1;

        -- rowid = items.id
        CREATE VIRTUAL TABLE items_fts USING fts5(
            item_id UNINDEXED, text, title, tags,
            tokenize = '\(tokenizer)'
        );
        """

    /// v3: ops gets `seq INTEGER PRIMARY KEY`, the local insertion order. pendingOutbound and refoldAll order by
    /// it; the old implicit rowid could be renumbered by VACUUM. seq takes the old rowid, so the order is kept.
    private static let schemaV3 = """
        CREATE TABLE ops_v3 (
            seq INTEGER PRIMARY KEY,
            op_id TEXT UNIQUE NOT NULL,
            item_id TEXT NOT NULL,
            ts_wall INTEGER,
            ts_counter INTEGER,
            ts_device TEXT,
            body BLOB NOT NULL, -- JSON-encoded Op
            outbound_pending INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO ops_v3 (seq, op_id, item_id, ts_wall, ts_counter, ts_device, body, outbound_pending)
            SELECT rowid, op_id, item_id, ts_wall, ts_counter, ts_device, body, outbound_pending
            FROM ops ORDER BY rowid;
        DROP TABLE ops;
        ALTER TABLE ops_v3 RENAME TO ops;
        CREATE INDEX ops_item ON ops(item_id);
        CREATE INDEX ops_outbound ON ops(outbound_pending) WHERE outbound_pending = 1;
        """

    /// v4 (blobs, F11/F12): items.blob_id mirrors `content.blob.id`, so garbage collection can ask which blobs
    /// visible items still use. No backfill: no item had a blob before v4.
    /// blob_uploads: payloads this device still has to upload (queued with the create op, in one transaction).
    /// blob_relay_gc: dead blobs this device already deleted from the relay.
    private static let schemaV4 = """
        ALTER TABLE items ADD COLUMN blob_id TEXT;
        CREATE INDEX items_blob ON items(blob_id) WHERE blob_id IS NOT NULL;
        CREATE TABLE blob_uploads (blob_id TEXT PRIMARY KEY, item_id TEXT NOT NULL);
        CREATE TABLE blob_relay_gc (blob_id TEXT PRIMARY KEY);
        """

    private func migrate() throws {
        var version = 0
        try query("PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
        let steps = migrations
        guard version < steps.count else { return }
        try inTransaction {
            for step in steps[version...] { try step() }
            try exec("PRAGMA user_version = \(steps.count)")
        }
    }

    /// A scratch FTS table with the same tokenizer as items_fts, used to ask which query words produce tokens.
    /// It lives in the connection's temp schema, so nothing is written to the database file.
    private func createQueryTokenizer() throws {
        try exec(
            """
            CREATE VIRTUAL TABLE temp.query_words USING fts5(word, tokenize = '\(Self.tokenizer)');
            CREATE VIRTUAL TABLE temp.query_words_vocab USING fts5vocab(temp, query_words, 'instance');
            """
        )
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
            for op in newOps[id, default: []] { state.apply(op) }
            try writeState(state)
        }
        return inserted
    }

    private func writeState(_ state: ItemState) throws {
        let created = state.createdBy
        var id: Int64 = 0
        try query(
            """
            INSERT INTO items (item_id, state, visible, pinned, created_wall, created_counter, created_device, preview,
                               blob_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                state = excluded.state, visible = excluded.visible, pinned = excluded.pinned,
                created_wall = excluded.created_wall, created_counter = excluded.created_counter,
                created_device = excluded.created_device, preview = excluded.preview, blob_id = excluded.blob_id
            RETURNING id
            """,
            [
                .text(state.id.description), .blob(encoder.encode(state)),
                .int(state.isVisible ? 1 : 0), .int(state.pinned.value ? 1 : 0),
                created.map { SQLValue.int(Int64(bitPattern: $0.wallMillis)) } ?? SQLValue.null,
                created.map { SQLValue.int(Int64($0.counter)) } ?? SQLValue.null,
                created.map { SQLValue.text($0.device.description) } ?? SQLValue.null,
                state.content.map { SQLValue.text(String($0.text.prefix(200))) } ?? SQLValue.null,
                state.content?.blob.map { SQLValue.text($0.id.description) } ?? SQLValue.null,
            ]
        ) { id = sqlite3_column_int64($0, 0) }

        try run("DELETE FROM items_fts WHERE rowid = ?", [.int(id)])
        try indexForSearch(state, id: id)
    }

    /// Adds a visible item to items_fts under rowid `id` (= items.id). The caller removes any old row first.
    private func indexForSearch(_ state: ItemState, id: Int64) throws {
        guard state.isVisible, let content = state.content else { return }
        try run(
            "INSERT INTO items_fts (rowid, item_id, text, title, tags) VALUES (?, ?, ?, ?, ?)",
            [
                .int(id), .text(state.id.description), .text(content.text),
                .text(state.title.value ?? ""), .text(state.visibleTags.joined(separator: " ")),
            ]
        )
    }

    /// Rebuilds items_fts from the stored states (migration v2).
    private func reindexAllItems() throws {
        var rows: [(id: Int64, state: ItemState)] = []
        try query("SELECT id, state FROM items") { stmt in
            rows.append((sqlite3_column_int64(stmt, 0), try decoder.decode(ItemState.self, from: columnData(stmt, 1))))
        }
        try run("DELETE FROM items_fts")
        for row in rows { try indexForSearch(row.state, id: row.id) }
    }

    /// The query words that the search tokenizer turns into at least one token, in their original order.
    private func wordsWithTokens(_ words: [String]) throws -> [String] {
        try run("DELETE FROM temp.query_words")
        for (index, word) in words.enumerated() {
            try run("INSERT INTO temp.query_words (rowid, word) VALUES (?, ?)", [.int(Int64(index)), .text(word)])
        }
        var tokenized = Set<Int64>()
        try query("SELECT DISTINCT doc FROM temp.query_words_vocab") { tokenized.insert(sqlite3_column_int64($0, 0)) }
        return words.indices.filter { tokenized.contains(Int64($0)) }.map { words[$0] }
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
