import ClipCore
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

    func testSearchPerformanceOn10kItems() throws {
        let db = try ClipDatabase.inMemory()
        var rng = SplitMix64(seed: 7)
        let words = """
        alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec
        romeo sierra tango uniform victor whiskey xray yankee zulu meeting invoice password recipe address
        flight booking café résumé naïve garçon über straße 東京 kubernetes deploy swift kotlin react figma
        design portfolio interview tracking clipboard sync encrypt tailscale server latency budget quarterly
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        var insertSeconds = 0.0
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
