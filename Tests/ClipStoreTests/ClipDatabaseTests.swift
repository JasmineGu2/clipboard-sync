import ClipCore
import CSQLite
import Foundation
import XCTest
@testable import ClipStore

final class ClipDatabaseTests: XCTestCase {
    let deviceA = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    let deviceB = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

    // MARK: Helpers

    func ts(_ wall: UInt64, _ counter: UInt32 = 0, _ device: DeviceID? = nil) -> HLCTimestamp {
        HLCTimestamp(wallMillis: wall, counter: counter, device: device ?? deviceA)
    }

    /// Whole-second dates so states compare exactly after a JSON round trip.
    func create(_ text: String, item: ItemID = ItemID(), at timestamp: HLCTimestamp) -> Op {
        let content = ItemContent(
            text: text, sourceDevice: timestamp.device, sourceDeviceName: "Test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(timestamp.wallMillis / 1000))
        )
        return Op(itemID: item, timestamp: timestamp, kind: .create(content))
    }

    func op(_ item: ItemID, _ kind: OpKind, at timestamp: HLCTimestamp) -> Op {
        Op(itemID: item, timestamp: timestamp, kind: kind)
    }

    func texts(_ states: [ItemState]) -> [String] { states.map { $0.content?.text ?? "" } }

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Tests

    func testDuplicateInsertIsIgnored() throws {
        let db = try ClipDatabase.inMemory()
        let c = create("hello", at: ts(1))
        XCTAssertEqual(try db.insert([c, c], outbound: false), [c])
        XCTAssertEqual(try db.insert([c], outbound: false), [])
        let pin = op(c.itemID, .setPinned(true), at: ts(2))
        XCTAssertEqual(try db.insert([c, pin], outbound: false), [pin])
        XCTAssertEqual(try db.count(), 1)
        XCTAssertEqual(try db.item(c.itemID)?.pinned.value, true)
    }

    func testItemsAreNewestFirstWithTiebreaks() throws {
        let db = try ClipDatabase.inMemory()
        try db.insert([
            create("oldest", at: ts(1_000)),
            create("newest", at: ts(3_000)),
            create("middle-a", at: ts(2_000, 0, deviceA)),
            create("middle-b", at: ts(2_000, 0, deviceB)),
            create("middle-counter", at: ts(2_000, 1, deviceA)),
        ], outbound: false)
        XCTAssertEqual(texts(try db.items(limit: 10)), ["newest", "middle-counter", "middle-b", "middle-a", "oldest"])
        XCTAssertEqual(texts(try db.items(limit: 2, offset: 1)), ["middle-counter", "middle-b"])
        XCTAssertEqual(try db.count(), 5)
    }

    func testPinnedItemsReturnsOldPinnedBeyondAnyPage() throws {
        let db = try ClipDatabase.inMemory()
        let old = create("old pinned", at: ts(1))
        let oldDeleted = create("deleted pinned", at: ts(2))
        let mid = create("mid pinned", at: ts(3))
        var ops = [old, oldDeleted, mid,
                   op(old.itemID, .setPinned(true), at: ts(10)),
                   op(oldDeleted.itemID, .setPinned(true), at: ts(11)),
                   op(oldDeleted.itemID, .delete, at: ts(12)),
                   op(mid.itemID, .setPinned(true), at: ts(13))]
        for i in 0..<30 { ops.append(create("new \(i)", at: ts(1_000 + UInt64(i)))) }
        try db.insert(ops, outbound: false)

        XCTAssertFalse(texts(try db.items(limit: 20)).contains("old pinned"))
        XCTAssertEqual(texts(try db.pinnedItems()), ["mid pinned", "old pinned"])

        try db.insert([op(old.itemID, .setPinned(false), at: ts(20))], outbound: false)
        XCTAssertEqual(texts(try db.pinnedItems()), ["mid pinned"])
    }

    func testPinTitleTagAndDeleteAreReflected() throws {
        let db = try ClipDatabase.inMemory()
        let id = ItemID()

        // Field ops can arrive before the create: the item exists but is hidden.
        try db.insert([op(id, .setTitle("Recipe"), at: ts(5))], outbound: false)
        XCTAssertEqual(try db.count(), 0)
        XCTAssertEqual(try db.item(id)?.isVisible, false)

        try db.insert([create("flour and water", item: id, at: ts(1))], outbound: false)
        try db.insert([
            op(id, .setPinned(true), at: ts(6)),
            op(id, .setTitle("Old title"), at: ts(4)),  // older than "Recipe": loses
            op(id, .setTag("cooking", present: true), at: ts(7)),
            op(id, .setTag("draft", present: true), at: ts(7)),
            op(id, .setTag("draft", present: false), at: ts(8)),
        ], outbound: false)

        let state = try XCTUnwrap(db.item(id))
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.pinned.value)
        XCTAssertEqual(state.title.value, "Recipe")
        XCTAssertEqual(state.visibleTags, ["cooking"])
        XCTAssertEqual(try db.items().map(\.id), [id])

        try db.insert([op(id, .delete, at: ts(9)), op(id, .setPinned(false), at: ts(10))], outbound: false)
        XCTAssertEqual(try db.count(), 0)
        XCTAssertEqual(try db.items(), [])
        XCTAssertEqual(try db.item(id)?.deleted, true)
    }

    func testSearchByTextTitleTagAndPrefix() throws {
        let db = try ClipDatabase.inMemory()
        let a = create("The quick brown fox jumps", at: ts(1))
        let b = create("lorem ipsum", at: ts(2))
        let c = create("meeting notes", at: ts(3))
        try db.insert([a, b, c,
                       op(b.itemID, .setTitle("Wireframe copy"), at: ts(4)),
                       op(c.itemID, .setTag("standup", present: true), at: ts(5))], outbound: false)

        XCTAssertEqual(try db.search("fox", limit: 10).map(\.id), [a.itemID])
        XCTAssertEqual(try db.search("wireframe", limit: 10).map(\.id), [b.itemID])
        XCTAssertEqual(try db.search("standup", limit: 10).map(\.id), [c.itemID])
        XCTAssertEqual(try db.search("qui", limit: 10).map(\.id), [a.itemID], "prefix")
        XCTAssertEqual(try db.search("QUICK  Bro", limit: 10).map(\.id), [a.itemID], "case-insensitive, multi-word")
        XCTAssertEqual(try db.search("quick lorem", limit: 10), [], "all words must match")
        XCTAssertEqual(try db.search("   ", limit: 10).count, 3, "empty query lists items")
        XCTAssertEqual(try db.search("", limit: 2).map(\.id), [c.itemID, b.itemID])
    }

    func testSearchRanksByRelevanceThenRecency() throws {
        let db = try ClipDatabase.inMemory()
        let weak = create("apple pie recipe with lots of other words around it here", at: ts(1))
        let strong = create("apple apple apple", at: ts(2))
        let newerWeak = create("apple pie recipe with lots of other words around it here", at: ts(3))
        try db.insert([weak, strong, newerWeak], outbound: false)
        XCTAssertEqual(try db.search("apple", limit: 10).map(\.id), [strong.itemID, newerWeak.itemID, weak.itemID])
    }

    func testSearchHandlesQuotesSpecialCharactersAndUnicode() throws {
        let db = try ClipDatabase.inMemory()
        let cafe = create("Meet at the Café Zoë", at: ts(1))
        let quote = create("she said \"hello\" to O'Brien", at: ts(2))
        let code = create("C++ and foo-bar(baz): x AND y NEAR z", at: ts(3))
        let cjk = create("日本語テキスト", at: ts(4))
        let accents = create("naïve résumé", at: ts(5))
        try db.insert([cafe, quote, code, cjk, accents], outbound: false)

        XCTAssertEqual(try db.search("cafe zoe", limit: 10).map(\.id), [cafe.itemID], "diacritics folded in query")
        XCTAssertEqual(try db.search("CAFÉ", limit: 10).map(\.id), [cafe.itemID])
        XCTAssertEqual(try db.search("resume", limit: 10).map(\.id), [accents.itemID])
        XCTAssertEqual(try db.search("naïve", limit: 10).map(\.id), [accents.itemID])
        XCTAssertEqual(try db.search("\"hello\"", limit: 10).map(\.id), [quote.itemID])
        XCTAssertEqual(try db.search("o'brien", limit: 10).map(\.id), [quote.itemID])
        XCTAssertEqual(try db.search("foo-bar", limit: 10).map(\.id), [code.itemID])
        XCTAssertTrue(try db.search("C++", limit: 10).map(\.id).contains(code.itemID), "C++ is the prefix c*")
        XCTAssertEqual(try db.search("C++ baz", limit: 10).map(\.id), [code.itemID])
        XCTAssertEqual(try db.search("AND", limit: 10).map(\.id), [code.itemID], "FTS keywords are plain words")
        XCTAssertEqual(try db.search("near", limit: 10).map(\.id), [code.itemID])
        XCTAssertEqual(try db.search("日本", limit: 10).map(\.id), [cjk.itemID])

        // Hostile input must never throw an FTS5 syntax error.
        for query in ["\"", "\"\"", "'", "*", "(", ")", "-", "^", ":", "a\"b", "x OR", "NOT", "{col}:x", "🎉", "\\", "%_"] {
            XCTAssertNoThrow(try db.search(query, limit: 10), "query \(query)")
        }
        XCTAssertEqual(try db.search("🎉", limit: 10), [])
    }

    func testSearchIgnoresWordsTheTokenizerReducesToNothing() throws {
        let db = try ClipDatabase.inMemory()
        let fox = create("The quick brown fox", at: ts(1))
        let cafe = create("Café Zoë", at: ts(2))
        try db.insert([fox, cafe], outbound: false)

        // Lone combining marks, joiners and format characters: no token survives unicode61.
        let empties = ["\u{0301}", "\u{0301}\u{0308}", "\u{05B0}", "\u{093C}", "\u{200D}", "\u{200B}", "\u{FE0F}"]
        for empty in empties {
            let label = empty.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+")
            XCTAssertEqual(try db.search(empty, limit: 10), [], "alone: \(label)")
            XCTAssertEqual(try db.search("fox \(empty)", limit: 10).map(\.id), [fox.itemID], "after a word: \(label)")
            XCTAssertEqual(try db.search("\(empty) quick  \(empty) bro", limit: 10).map(\.id), [fox.itemID], "mixed: \(label)")
        }
        // Tatweel never throws; it matches nothing here (no stored text contains it).
        for query in ["\u{0640}", "\u{0640}\u{0640}", "fox \u{0640}"] {
            XCTAssertNoThrow(try db.search(query, limit: 10), "tatweel query")
        }
        // A combining mark attached to a real letter is still a real word.
        XCTAssertEqual(try db.search("cafe\u{0301}", limit: 10).map(\.id), [cafe.itemID])
        XCTAssertEqual(try db.search("\u{0301}zoe", limit: 10).map(\.id), [cafe.itemID])
    }

    func testDeletedAndUntaggedItemsAreNotSearchable() throws {
        let db = try ClipDatabase.inMemory()
        let a = create("secret token value", at: ts(1))
        let b = create("other", at: ts(2))
        try db.insert([a, b, op(b.itemID, .setTag("work", present: true), at: ts(3))], outbound: false)
        XCTAssertEqual(try db.search("secret", limit: 10).count, 1)
        XCTAssertEqual(try db.search("work", limit: 10).count, 1)

        try db.insert([op(a.itemID, .delete, at: ts(4)), op(b.itemID, .setTag("work", present: false), at: ts(5))], outbound: false)
        XCTAssertEqual(try db.search("secret", limit: 10), [])
        XCTAssertEqual(try db.search("work", limit: 10), [])
        XCTAssertEqual(try db.search("other", limit: 10).count, 1)
    }

    func testOutboundQueueFlow() throws {
        let db = try ClipDatabase.inMemory()
        let local = (1...3).map { create("local \($0)", at: ts(UInt64($0))) }
        let remote = (4...5).map { create("remote \($0)", at: ts(UInt64($0), 0, deviceB)) }
        try db.insert([local[0]], outbound: true)
        try db.insert(remote, outbound: false)
        try db.insert([local[1], local[2]], outbound: true)

        XCTAssertEqual(try db.pendingOutbound(limit: 10), local, "oldest first, remote ops excluded")
        XCTAssertEqual(try db.pendingOutbound(limit: 2), Array(local.prefix(2)))

        try db.markSent([local[0].id, local[1].id])
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [local[2]])

        // Re-inserting an op that was already sent must not queue it again.
        XCTAssertEqual(try db.insert([local[0]], outbound: true), [])
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [local[2]])

        try db.markSent([local[2].id])
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [])
    }

    func testMarkAllOutboundQueuesEveryOpAndResetsCursor() throws {
        let db = try ClipDatabase.inMemory()
        let local = create("local", at: ts(1))
        let remote = (2...3).map { create("remote \($0)", at: ts(UInt64($0), 0, deviceB)) }
        try db.insert([local], outbound: true)
        try db.insertRemote(remote, newCursor: 12)
        let late = create("late local", at: ts(4))
        try db.insert([late], outbound: true)
        try db.markSent([local.id])

        try db.markAllOutbound()
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [local] + remote + [late], "every op, in insertion order")
        XCTAssertEqual(try db.syncCursor(), 0)

        try db.markSent((remote + [local, late]).map(\.id))
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [])
    }

    func testInsertRemoteMovesCursorAtomically() throws {
        let db = try ClipDatabase.inMemory()
        XCTAssertEqual(try db.syncCursor(), 0)

        let first = create("first", at: ts(1, 0, deviceB))
        XCTAssertEqual(try db.insertRemote([first], newCursor: 10), [first])
        XCTAssertEqual(try db.syncCursor(), 10)
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [], "remote ops are never queued for push")

        // A failure before commit rolls back both the ops and the cursor.
        struct Boom: Error {}
        db.beforeCommitHook = { throw Boom() }
        let second = create("second", at: ts(2, 0, deviceB))
        XCTAssertThrowsError(try db.insertRemote([second], newCursor: 20))
        db.beforeCommitHook = nil
        XCTAssertEqual(try db.syncCursor(), 10)
        XCTAssertNil(try db.item(second.itemID))
        XCTAssertEqual(try db.count(), 1)

        // Duplicates still move the cursor.
        XCTAssertEqual(try db.insertRemote([first, second], newCursor: 20), [second])
        XCTAssertEqual(try db.syncCursor(), 20)
        try db.setSyncCursor(25)
        XCTAssertEqual(try db.syncCursor(), 25)
    }

    func testMeta() throws {
        let db = try ClipDatabase.inMemory()
        XCTAssertNil(try db.meta("device_name"))
        try db.setMeta("device_name", "Jazz's PC")
        XCTAssertEqual(try db.meta("device_name"), "Jazz's PC")
        try db.setMeta("device_name", "Laptop")
        XCTAssertEqual(try db.meta("device_name"), "Laptop")
        try db.setMeta("device_name", nil)
        XCTAssertNil(try db.meta("device_name"))
    }

    func testReopenFileDatabaseKeepsData() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("clips.sqlite")
        let c = create("persist me", at: ts(1))
        let tag = op(c.itemID, .setTag("keep", present: true), at: ts(2))
        do {
            let db = try ClipDatabase(url: url)
            try db.insert([c, tag], outbound: true)
            try db.insertRemote([create("from afar", at: ts(3, 0, deviceB))], newCursor: 7)
            try db.setMeta("k", "v")
            db.close()
            XCTAssertThrowsError(try db.count(), "closed database throws")
        }
        let db = try ClipDatabase(url: url)
        defer { db.close() }
        XCTAssertEqual(try db.count(), 2)
        XCTAssertEqual(texts(try db.items()), ["from afar", "persist me"])
        XCTAssertEqual(try db.search("keep", limit: 10).map(\.id), [c.itemID])
        XCTAssertEqual(try db.pendingOutbound(limit: 10), [c, tag])
        XCTAssertEqual(try db.syncCursor(), 7)
        XCTAssertEqual(try db.meta("k"), "v")
    }

    func testFileDatabaseIsDurable() throws {
        let db = try ClipDatabase(url: try tempDirectory().appendingPathComponent("durable.sqlite"))
        defer { db.close() }
        XCTAssertEqual(try db.pragma("synchronous"), 2, "synchronous = FULL: a commit is fsynced before insert returns")
        XCTAssertEqual(try db.pragma("user_version"), 3)
    }

    func testV1DatabaseMigratesInPlace() throws {
        let url = try tempDirectory().appendingPathComponent("v1.sqlite")
        let fox = create("the quick brown fox", at: ts(1))
        let hidden = create("deleted secret", at: ts(2))
        let tagged = create("meeting notes", at: ts(3, 0, deviceB))
        let titleOnly = op(ItemID(), .setTitle("orphan"), at: ts(4))
        var states: [ItemID: ItemState] = [:]
        let allOps = [fox, hidden, tagged, titleOnly,
                      op(hidden.itemID, .delete, at: ts(5)),
                      op(tagged.itemID, .setTag("standup", present: true), at: ts(6)),
                      op(tagged.itemID, .setTitle("Weekly sync"), at: ts(7))]
        for op in allOps { states[op.itemID, default: ItemState(id: op.itemID)].apply(op) }

        // Build a v1 database by hand, exactly as the v1 code laid it out, with rowid gaps (as after VACUUM
        // renumbering or manual surgery) so the old rowid pairing can't be relied on by the migration.
        let raw = try RawSQLite(path: url.path)
        try raw.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE ops (op_id TEXT PRIMARY KEY, item_id TEXT NOT NULL, ts_wall INTEGER, ts_counter INTEGER,
                ts_device TEXT, body BLOB NOT NULL, outbound_pending INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX ops_item ON ops(item_id);
            CREATE INDEX ops_outbound ON ops(outbound_pending) WHERE outbound_pending = 1;
            CREATE TABLE items (item_id TEXT PRIMARY KEY, state BLOB NOT NULL, visible INTEGER, pinned INTEGER,
                created_wall INTEGER, created_counter INTEGER, created_device TEXT, preview TEXT);
            CREATE INDEX items_newest ON items(created_wall DESC, created_counter DESC, created_device DESC)
                WHERE visible = 1;
            CREATE VIRTUAL TABLE items_fts USING fts5(item_id UNINDEXED, text, title, tags,
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('sync_cursor', '42');
            PRAGMA user_version = 1;
            """)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (index, op) in allOps.enumerated() {
            try raw.exec("""
                INSERT INTO ops VALUES ('\(op.id)', '\(op.itemID)', \(op.timestamp.wallMillis), \(op.timestamp.counter),
                    '\(op.timestamp.device)', CAST(\(RawSQLite.quote(try encoder.encode(op))) AS BLOB), \(index % 2))
                """)
        }
        for (index, state) in states.values.sorted(by: { $0.id.description < $1.id.description }).enumerated() {
            let rowid = (index + 1) * 10
            let created = state.createdBy
            try raw.exec("""
                INSERT INTO items (rowid, item_id, state, visible, pinned, created_wall, created_counter, created_device, preview)
                VALUES (\(rowid), '\(state.id)', CAST(\(RawSQLite.quote(try encoder.encode(state))) AS BLOB),
                    \(state.isVisible ? 1 : 0), 0, \(created.map { "\($0.wallMillis)" } ?? "NULL"),
                    \(created.map { "\($0.counter)" } ?? "NULL"), \(created.map { "'\($0.device)'" } ?? "NULL"), NULL)
                """)
            if state.isVisible, let content = state.content {
                // Deliberately keyed off by one: a v1 index already broken by VACUUM must be repaired.
                try raw.exec("""
                    INSERT INTO items_fts (rowid, item_id, text, title, tags) VALUES (\(rowid + 1), '\(state.id)',
                        '\(content.text)', '\(state.title.value ?? "")', '\(state.visibleTags.joined(separator: " "))')
                    """)
            }
        }
        raw.close()

        let db = try ClipDatabase(url: url)
        XCTAssertEqual(try db.pragma("user_version"), 3)
        XCTAssertEqual(try db.count(), 2)
        XCTAssertEqual(try db.items().map(\.id), [tagged.itemID, fox.itemID])
        for (id, state) in states { XCTAssertEqual(try db.item(id), state) }
        XCTAssertEqual(try db.search("fox", limit: 10).map(\.id), [fox.itemID])
        XCTAssertEqual(try db.search("standup", limit: 10).map(\.id), [tagged.itemID])
        XCTAssertEqual(try db.search("weekly", limit: 10).map(\.id), [tagged.itemID])
        XCTAssertEqual(try db.search("secret", limit: 10), [])
        XCTAssertEqual(try db.syncCursor(), 42)
        XCTAssertEqual(try db.pendingOutbound(limit: 10), allOps.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        XCTAssertEqual(try db.maxOpTimestamp(), ts(7))

        // Writes keep working on the migrated table, and a reopen doesn't migrate again.
        let late = create("late arrival fox", at: ts(8))
        try db.insert([late], outbound: false)
        db.close()
        let reopened = try ClipDatabase(url: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.search("fox", limit: 10).map(\.id), [late.itemID, fox.itemID])
        XCTAssertEqual(try reopened.count(), 3)
    }

    func testV2DatabaseMigratesOpsKeepingOrderAndPendingFlags() throws {
        let url = try tempDirectory().appendingPathComponent("v2.sqlite")
        let item = ItemID()
        // Timestamps run backwards against insertion order, so only the stored order can explain the result.
        var ops: [Op] = [create("first stored", item: item, at: ts(60))]
        for n in 0..<5 {
            let device: DeviceID = n % 2 == 0 ? deviceA : deviceB
            let wall = UInt64(50 - n * 10)
            ops.append(op(item, .setTag("tag\(n)", present: true), at: ts(wall, 0, device)))
        }
        let rowids: [Int64] = [3, 10, 11, 40, 41, 100]  // gaps, as after deletes or VACUUM renumbering
        let pending = [true, false, true, true, false, true]

        // Build a v2 database by hand, exactly as the v2 code laid it out.
        let raw = try RawSQLite(path: url.path)
        try raw.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE ops (op_id TEXT PRIMARY KEY, item_id TEXT NOT NULL, ts_wall INTEGER, ts_counter INTEGER,
                ts_device TEXT, body BLOB NOT NULL, outbound_pending INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX ops_item ON ops(item_id);
            CREATE INDEX ops_outbound ON ops(outbound_pending) WHERE outbound_pending = 1;
            CREATE TABLE items (id INTEGER PRIMARY KEY, item_id TEXT UNIQUE NOT NULL, state BLOB NOT NULL,
                visible INTEGER, pinned INTEGER, created_wall INTEGER, created_counter INTEGER, created_device TEXT,
                preview TEXT);
            CREATE INDEX items_newest ON items(created_wall DESC, created_counter DESC, created_device DESC)
                WHERE visible = 1;
            CREATE VIRTUAL TABLE items_fts USING fts5(item_id UNINDEXED, text, title, tags,
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO meta VALUES ('sync_cursor', '42');
            PRAGMA user_version = 2;
            """)
        let encoder = ClipCoding.makeEncoder()
        // Insert in reverse rowid order, so the table's physical order differs from rowid order too.
        for index in ops.indices.reversed() {
            let op = ops[index]
            try raw.exec("""
                INSERT INTO ops (rowid, op_id, item_id, ts_wall, ts_counter, ts_device, body, outbound_pending)
                VALUES (\(rowids[index]), '\(op.id)', '\(op.itemID)', \(op.timestamp.wallMillis),
                    \(op.timestamp.counter), '\(op.timestamp.device)',
                    CAST(\(RawSQLite.quote(try encoder.encode(op))) AS BLOB), \(pending[index] ? 1 : 0))
                """)
        }
        raw.close()

        let pendingInOrder = ops.indices.filter { pending[$0] }.map { ops[$0] }
        let late = op(item, .setTitle("late"), at: ts(1))
        do {
            let db = try ClipDatabase(url: url)
            XCTAssertEqual(try db.pragma("user_version"), 3)
            XCTAssertEqual(try db.pendingOutbound(limit: 10), pendingInOrder)
            XCTAssertEqual(try db.syncCursor(), 42)
            try db.refoldAll()
            var expected = ItemState(id: item)
            for op in ops { expected.apply(op) }
            XCTAssertEqual(try db.item(item), expected)
            // New ops land after the migrated ones, and duplicates are still ignored.
            XCTAssertEqual(try db.insert([late, ops[0]], outbound: true), [late])
            XCTAssertEqual(try db.pendingOutbound(limit: 10), pendingInOrder + [late])
            db.close()
        }

        let check = try RawSQLite(path: url.path)
        XCTAssertEqual(try check.ints("SELECT seq FROM ops ORDER BY seq"), rowids + [101], "seq keeps the old rowids")
        XCTAssertEqual(try check.ints("""
            SELECT count(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ops'
                AND ((name = 'ops_item' AND sql LIKE '%(item_id)%')
                  OR (name = 'ops_outbound' AND sql LIKE '%WHERE outbound_pending = 1%'))
            """), [2], "both ops indexes exist, the outbound one still partial")
        // VACUUM may renumber implicit rowids, but not an INTEGER PRIMARY KEY.
        try check.exec("VACUUM")
        XCTAssertEqual(try check.ints("SELECT seq FROM ops ORDER BY seq"), rowids + [101])
        check.close()

        let reopened = try ClipDatabase(url: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.pragma("user_version"), 3)
        XCTAssertEqual(try reopened.pendingOutbound(limit: 10), pendingInOrder + [late], "order survives VACUUM")
        try reopened.markAllOutbound()
        XCTAssertEqual(try reopened.pendingOutbound(limit: 10), ops + [late])
    }

    func testSearchStaysCorrectAfterVacuum() throws {
        let url = try tempDirectory().appendingPathComponent("vacuum.sqlite")
        let words = ["apple", "banana", "cherry", "damson", "elder", "fig", "grape", "honeydew"]
        let ops = words.enumerated().map { create("\($1) fruit", at: ts(UInt64($0 + 1))) }
        do {
            let db = try ClipDatabase(url: url)
            try db.insert(ops, outbound: false)
            db.close()
        }
        // Punch rowid gaps (as a future purge would), then VACUUM. Without an INTEGER PRIMARY KEY,
        // VACUUM is free to renumber items and the FTS join would return the wrong rows.
        let raw = try RawSQLite(path: url.path)
        for gone in [ops[0], ops[3], ops[5]] {
            try raw.exec("DELETE FROM items_fts WHERE item_id = '\(gone.itemID)'; DELETE FROM items WHERE item_id = '\(gone.itemID)';")
        }
        let idsBefore = try raw.ints("SELECT id FROM items ORDER BY id")
        try raw.exec("VACUUM")
        XCTAssertEqual(try raw.ints("SELECT id FROM items ORDER BY id"), idsBefore, "ids survive VACUUM")
        raw.close()

        let db = try ClipDatabase(url: url)
        defer { db.close() }
        for (index, word) in words.enumerated() where ![0, 3, 5].contains(index) {
            XCTAssertEqual(try db.search(word, limit: 10).map(\.id), [ops[index].itemID], word)
        }
        XCTAssertEqual(try db.search("fruit", limit: 10).count, 5)
        // Updates after VACUUM still replace the right FTS row.
        try db.insert([op(ops[1].itemID, .setTag("yellow", present: true), at: ts(20))], outbound: false)
        XCTAssertEqual(try db.search("yellow", limit: 10).map(\.id), [ops[1].itemID])
        XCTAssertEqual(try db.search("cherry", limit: 10).map(\.id), [ops[2].itemID])
    }

    func testMaxOpTimestamp() throws {
        let db = try ClipDatabase.inMemory()
        XCTAssertNil(try db.maxOpTimestamp())
        let item = ItemID()
        try db.insert([create("a", item: item, at: ts(5, 0, deviceB))], outbound: true)
        XCTAssertEqual(try db.maxOpTimestamp(), ts(5, 0, deviceB))
        // Lower wall time loses even with a higher counter; remote ops count too.
        try db.insertRemote([op(item, .setPinned(true), at: ts(4, 9, deviceB))], newCursor: 1)
        XCTAssertEqual(try db.maxOpTimestamp(), ts(5, 0, deviceB))
        // Same wall: counter decides, then device.
        try db.insert([op(item, .setTitle("x"), at: ts(5, 1, deviceA))], outbound: false)
        XCTAssertEqual(try db.maxOpTimestamp(), ts(5, 1, deviceA))
        try db.insert([op(item, .setTitle("y"), at: ts(5, 1, deviceB))], outbound: false)
        XCTAssertEqual(try db.maxOpTimestamp(), ts(5, 1, deviceB))
        // Wall times past Int64.max are stored as negative bit patterns but still compare as the largest.
        let huge = ts(UInt64(Int64.max) + 10)
        try db.insert([op(item, .setTitle("z"), at: huge), op(item, .setTitle("w"), at: ts(UInt64(Int64.max)))], outbound: false)
        XCTAssertEqual(try db.maxOpTimestamp(), huge)
        // It reads the op log, not the dedupe result: a sent op still counts.
        try db.markSent(try db.pendingOutbound().map(\.id))
        XCTAssertEqual(try db.maxOpTimestamp(), huge)
    }

    func testRefoldAllEqualsIncrementalAndInMemoryFold() throws {
        var rng = SplitMix64(seed: 42)
        let devices = [deviceA, deviceB, DeviceID()]
        let ids = (0..<40).map { _ in ItemID() }
        var ops: [Op] = []
        for _ in 0..<600 {
            let item = ids[Int(rng.next() % UInt64(ids.count))]
            let stamp = ts(rng.next() % 50_000, UInt32(rng.next() % 3), devices[Int(rng.next() % 3)])
            let kind: OpKind
            switch rng.next() % 10 {
            case 0, 1: kind = .create(ItemContent(text: "item \(rng.next() % 100) café", sourceDevice: stamp.device,
                                                  sourceDeviceName: "d", createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
            case 2, 3: kind = .setPinned(rng.next() % 2 == 0)
            case 4, 5: kind = .setTitle(rng.next() % 3 == 0 ? nil : "title \(rng.next() % 5)")
            case 6, 7, 8: kind = .setTag("tag\(rng.next() % 4)", present: rng.next() % 2 == 0)
            default: kind = rng.next() % 3 == 0 ? .delete : .setPinned(true)
            }
            ops.append(Op(itemID: item, timestamp: stamp, kind: kind))
        }

        // Incremental: shuffled batches with duplicates.
        let db = try ClipDatabase.inMemory()
        var shuffled = ops + ops.prefix(100)
        shuffled.shuffle(using: &rng)
        var index = 0
        while index < shuffled.count {
            let size = Int(rng.next() % 40) + 1
            try db.insert(Array(shuffled[index..<min(index + size, shuffled.count)]), outbound: false)
            index += size
        }

        // Expected: ClipCore's fold in memory.
        var expected: [ItemID: ItemState] = [:]
        for op in ops { expected[op.itemID, default: ItemState(id: op.itemID)].apply(op) }

        let incremental = try ids.map { try db.item($0) }
        let incrementalList = try db.items(limit: 1000)
        let incrementalSearch = try db.search("caf", limit: 1000)
        for (id, state) in zip(ids, incremental) { XCTAssertEqual(state, expected[id]) }

        try db.refoldAll()
        XCTAssertEqual(try ids.map { try db.item($0) }, incremental)
        XCTAssertEqual(try db.items(limit: 1000), incrementalList)
        XCTAssertEqual(try db.search("caf", limit: 1000), incrementalSearch)
        XCTAssertEqual(incrementalList.count, expected.values.filter(\.isVisible).count)
    }

    static let perfWords = """
        alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec
        romeo sierra tango uniform victor whiskey xray yankee zulu meeting invoice password recipe address
        flight booking café résumé naïve garçon über straße 東京 kubernetes deploy swift kotlin react figma
        design portfolio interview tracking clipboard sync encrypt tailscale server latency budget quarterly
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    /// 10,000 creates (plus a tag on every tenth) in 20 batches of 500, deterministic.
    func perfBatches() -> [[Op]] {
        var rng = SplitMix64(seed: 7)
        let words = Self.perfWords
        var batches: [[Op]] = []
        var wall: UInt64 = 1
        for _ in 0..<20 {
            var batch: [Op] = []
            for n in 0..<500 {
                let count = Int(rng.next() % 30) + 3
                var text = (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
                text += " #\(wall) \(n)"
                let op = create(text, at: ts(wall))
                batch.append(op)
                if n % 10 == 0 { batch.append(self.op(op.itemID, .setTag(words[Int(rng.next() % 20)], present: true), at: ts(wall + 1))) }
                wall += 2
            }
            batches.append(batch)
        }
        return batches
    }

    /// Durability cost: the same 10k inserts against a real file (WAL + synchronous = FULL).
    func testInsertPerformanceOn10kItemsFileBacked() throws {
        let url = try tempDirectory().appendingPathComponent("perf.sqlite")
        let db = try ClipDatabase(url: url)
        defer { db.close() }
        let batches = perfBatches()
        var batchSeconds = 0.0
        for batch in batches {
            let start = Date()
            try db.insert(batch, outbound: true)
            batchSeconds += Date().timeIntervalSince(start)
        }
        // Single-op transactions: one commit (and fsync) per copied clip, the interactive path.
        let singles = (0..<200).map { create("single \($0)", at: ts(1_000_000 + UInt64($0))) }
        let start = Date()
        for op in singles { try db.insert([op], outbound: true) }
        let singleMillis = Date().timeIntervalSince(start) * 1000 / Double(singles.count)
        XCTAssertEqual(try db.count(), 10_200)
        print(String(format: "ClipStore file perf: 10,000 items in 20 batches %.2f s; single-op insert %.2f ms avg (200)",
                     batchSeconds, singleMillis))
    }

    func testSearchPerformanceOn10kItems() throws {
        let db = try ClipDatabase.inMemory()
        var insertSeconds = 0.0
        for batch in perfBatches() {
            let start = Date()
            try db.insert(batch, outbound: true)
            insertSeconds += Date().timeIntervalSince(start)
        }
        XCTAssertEqual(try db.count(), 10_000)

        let queries = ["alpha", "invoice password", "caf", "resume", "東京", "kube", "deploy swift", "zulu yankee xray",
                       "interview", "tracking clip", "über", "strasse", "garcon", "fig", "q", "server latency budget",
                       "meeting", "nothingmatches", "hotel india", "port"]
        var timings: [Double] = []
        for query in queries {
            let start = Date()
            let results = try db.search(query, limit: 50)
            timings.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertLessThanOrEqual(results.count, 50)
        }
        timings.sort()
        let median = (timings[9] + timings[10]) / 2
        print(String(format: "ClipStore perf: inserted 10,000 items in %.2f s; search median %.2f ms, max %.2f ms (20 queries)",
                     insertSeconds, median, timings.last!))
        XCTAssertLessThan(median, 50, "PRD N2: search median under 50 ms")
    }
}

/// Small deterministic RNG so test data is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A bare SQLite connection for building legacy-shaped databases and running maintenance (VACUUM) in tests.
final class RawSQLite {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError(code: sqlite3_errcode(db), message: "open") }
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw StoreError(code: rc, message: message)
        }
    }

    func ints(_ sql: String) throws -> [Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(sqlite3_column_int64(stmt, 0)) }
        return result
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    /// A SQL string literal for UTF-8 data.
    static func quote(_ data: Data) -> String {
        "'" + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''") + "'"
    }
}
