import ClipCore
import ClipStore
import Foundation

// Test helper for the crash-injection test (Tests/ClipStoreTests/CrashInjectionTests.swift, PRD N12).
// Opens a ClipDatabase and writes to it in a loop until the test kills the process.
//
// Usage: ClipStoreCrashWriter <db path> <seed> <first remote cursor>
//
// Protocol on stdout, one line per event, written unbuffered:
//   READY                        the database is open
//   P <kind> <cursor> <op ids>   about to start this transaction (ids comma-separated, "-" for none)
//   C                            the transaction announced by the last P line has committed
// kind is "local" (insert), "remote" (insertRemote, moves the cursor to <cursor>), "refold" or "sent".

struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

func emit(_ line: String) {
    // FileHandle writes go straight to the descriptor, so a line is out before the next transaction starts.
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let args = CommandLine.arguments
guard args.count == 4, let seed = UInt64(args[2]), var cursor = Int64(args[3]) else {
    FileHandle.standardError.write(Data("usage: ClipStoreCrashWriter <db path> <seed> <first remote cursor>\n".utf8))
    exit(2)
}

let db: ClipDatabase
do {
    db = try ClipDatabase(path: args[1])
} catch {
    FileHandle.standardError.write(Data("open failed: \(error)\n".utf8))
    exit(1)
}

var rng = Rng(state: seed)
let device = DeviceID()
let words = ["alpha", "bravo", "invoice", "password", "café", "東京", "deploy", "swift", "meeting", "über", "kube", "port"]
// Wall times only need to increase within a run; each run starts from its seed so runs don't collide much.
var wall = 1_000_000 + (seed % 1_000_000) * 1_000
var known: [ItemID] = (try? db.items(limit: 300).map(\.id)) ?? []
var pendingSent: [OpID] = (try? db.pendingOutbound(limit: 200).map(\.id)) ?? []

@MainActor func timestamp() -> HLCTimestamp {
    wall += 1
    return HLCTimestamp(wallMillis: wall, counter: 0, device: device)
}

@MainActor func createOp() -> Op {
    // The first word is unique, so the test can search for this item. Some texts span several pages.
    let token = "k" + String(rng.next(), radix: 36)
    let count = rng.below(10) == 0 ? 400 + rng.below(3_000) : 3 + rng.below(20)
    let body = (0..<count).map { _ in words[rng.below(words.count)] }.joined(separator: " ")
    let content = ItemContent(text: token + " " + body, sourceDevice: device, sourceDeviceName: "crash", createdAt: Date())
    let op = Op(itemID: ItemID(), timestamp: timestamp(), kind: .create(content))
    known.append(op.itemID)
    return op
}

@MainActor func editOp() -> Op {
    guard !known.isEmpty else { return createOp() }
    let item = known[rng.below(known.count)]
    let kind: OpKind
    switch rng.below(5) {
    case 0: kind = .setPinned(rng.below(2) == 0)
    case 1: kind = .setTitle(rng.below(3) == 0 ? nil : "title \(rng.below(1_000))")
    case 2, 3: kind = .setTag(words[rng.below(words.count)], present: rng.below(3) != 0)
    default: kind = .delete
    }
    return Op(itemID: item, timestamp: timestamp(), kind: kind)
}

func ids(_ ops: [Op]) -> String {
    ops.isEmpty ? "-" : ops.map(\.id.description).joined(separator: ",")
}

emit("READY")
while true {
    do {
        switch rng.below(100) {
        case 0..<45:
            let ops = (0..<(1 + rng.below(8))).map { _ in createOp() }
            emit("P local 0 \(ids(ops))")
            try db.insert(ops, outbound: true)
            pendingSent += ops.map(\.id)
        case 45..<65:
            let ops = (0..<(1 + rng.below(5))).map { _ in editOp() }
            emit("P local 0 \(ids(ops))")
            try db.insert(ops, outbound: true)
            pendingSent += ops.map(\.id)
        case 65..<82:
            let ops = (0..<(1 + rng.below(6))).map { _ in rng.below(2) == 0 ? createOp() : editOp() }
            cursor += 1
            emit("P remote \(cursor) \(ids(ops))")
            try db.insertRemote(ops, newCursor: cursor)
        case 82..<90:
            let ops = (0..<50).map { _ in createOp() }
            emit("P local 0 \(ids(ops))")
            try db.insert(ops, outbound: true)
            pendingSent += ops.map(\.id)
        case 90..<96:
            let sent = Array(pendingSent.prefix(20))
            pendingSent.removeFirst(sent.count)
            emit("P sent 0 -")
            try db.markSent(sent)
        default:
            // Rewrites every item and the whole FTS index in one transaction.
            emit("P refold 0 -")
            try db.refoldAll()
        }
        emit("C")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}
