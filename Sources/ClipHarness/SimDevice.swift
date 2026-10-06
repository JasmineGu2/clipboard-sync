import ClipCore
import Foundation

/// A device's settable wall clock. Shared with its HybridClock through a closure, so it must be a reference.
final class FakeWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ millis: UInt64) { value = millis }

    var millis: UInt64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What survives a crash. Mirrors the store's transactions (design §4): the outbox is written when an op is
/// recorded; the replica and cursor are written together when a pulled page is applied.
struct DeviceDisk {
    var store: MergeStore
    var cursor: Int64 = 0
    var outbox: [Op] = []
    /// Highest timestamp issued or observed, written alongside the outbox and the replica.
    var clockHighWater: HLCTimestamp?
    /// Items hidden by a local-only expiry sweep (`ExpiryMode.hideLocally`), persisted when hidden.
    var hidden: Set<ItemID> = []
    /// How many relay revokes this device has recovered from (F13). Written in the same step as the recovery.
    var relayGeneration = 0
    /// Every op this device holds, in the order it stored them: its local op log (ClipDatabase `ops.seq`).
    /// Append-only and written with each insert, like the database.
    var log: [Op] = []
    /// Per listening device: cursors into its log and into ours (F16), written with the ops they cover.
    var peerCursors: [Int: PeerSimCursor] = [:]
}

/// A dialer's position in one listener's log (`pulled`) and in its own log as sent to it (`pushed`), as indexes.
struct PeerSimCursor: Equatable {
    var pulled = 0
    var pushed = 0
}

/// One simulated device: a HybridClock on a skewed fake wall clock, a merge store, an outbox and a cursor.
struct SimDevice {
    let index: Int
    let id: DeviceID
    let name: String
    let wall: FakeWallClock
    /// Offset from simulated true time; clock jumps change it.
    var skew: Int64

    var clock: HybridClock
    var store: MergeStore
    var cursor: Int64 = 0
    var outbox: [Op] = []
    var online = true
    var clockHighWater: HLCTimestamp?
    /// Items learned from the latest applied pull, so actions sometimes target brand-new items.
    var recentItems: [ItemID] = []
    /// See `DeviceDisk.hidden`. Always empty unless expiry is `.hideLocally`.
    var hidden: Set<ItemID> = []
    /// Blobs in this device's blob cache: ones it created and ones it downloaded. Cache files are fsynced before
    /// they're published, so a crash keeps them (BlobCache).
    var heldBlobs: Set<BlobID> = []
    /// See `DeviceDisk.log` and `DeviceDisk.peerCursors`.
    var log: [Op] = []
    var peerCursors: [Int: PeerSimCursor] = [:]

    var disk: DeviceDisk

    init(index: Int, id: DeviceID, skew: Int64, mutation: MergeMutation) {
        self.index = index
        self.id = id
        self.name = "d\(index)"
        self.skew = skew
        let wall = FakeWallClock(0)
        self.wall = wall
        self.clock = HybridClock(device: id, resumingAfter: nil, now: { wall.millis })
        self.store = MergeStore(mutation: mutation)
        self.disk = DeviceDisk(store: MergeStore(mutation: mutation))
    }

    mutating func noteTimestamp(_ ts: HLCTimestamp) {
        if clockHighWater.map({ $0 < ts }) ?? true { clockHighWater = ts }
    }

    /// Creates an op locally: tick, apply, append to the outbox, persist the outbox.
    mutating func record(_ kind: OpKind, item: ItemID, opID: OpID) -> Op {
        let ts = clock.tick()
        noteTimestamp(ts)
        let op = Op(id: opID, itemID: item, timestamp: ts, kind: kind)
        store.apply(op)
        log.append(op)
        disk.log = log
        outbox.append(op)
        disk.outbox = outbox
        disk.clockHighWater = clockHighWater
        return op
    }

    /// What this device shows: visible items it hasn't hidden locally.
    var shownItems: Set<ItemID> {
        Set(store.items.values.filter { $0.isVisible && !hidden.contains($0.id) }.map(\.id))
    }

    /// Hides an item on this device only, and persists that.
    mutating func hideLocally(_ item: ItemID) {
        hidden.insert(item)
        disk.hidden = hidden
    }

    /// Applies a pulled page and persists replica + cursor atomically.
    mutating func applyPage(_ entries: [SimRelay.Entry]) {
        recentItems = []
        for entry in entries {
            if store.apply(entry.op) {
                recentItems.append(entry.op.itemID)
                log.append(entry.op)
            }
            clock.observe(entry.op.timestamp)
            noteTimestamp(entry.op.timestamp)
        }
        if let last = entries.last { cursor = last.seq }
        disk.store = store
        disk.cursor = cursor
        disk.clockHighWater = clockHighWater
        disk.log = log
    }

    /// F16: stores ops received directly, queues the new ones for the relay, and moves the cursors for `peer`
    /// (nil when this device answered), all persisted together. Returns how many were new.
    @discardableResult
    mutating func applyDirect(_ ops: [Op], peer: Int?, cursor: PeerSimCursor?) -> Int {
        var new = 0
        for op in ops where store.apply(op) {
            log.append(op)
            outbox.append(op)
            clock.observe(op.timestamp)
            noteTimestamp(op.timestamp)
            new += 1
        }
        if let peer, let cursor { peerCursors[peer] = cursor }
        disk.store = store
        disk.log = log
        disk.outbox = outbox
        disk.peerCursors = peerCursors
        disk.clockHighWater = clockHighWater
        return new
    }

    /// Successful push response: drop the acknowledged ops and persist the outbox.
    mutating func acknowledge(_ ids: Set<OpID>) {
        outbox.removeAll { ids.contains($0.id) }
        disk.outbox = outbox
    }

    /// Crash and restart: memory is gone, reload what was persisted.
    mutating func restart(recovery: ClockRecovery, fromLog: Bool = false) {
        store = disk.store
        log = disk.log
        peerCursors = disk.peerCursors
        if fromLog {
            // Like the database: the items are the fold of every stored op.
            store = MergeStore(mutation: store.mutation)
            for op in log { store.apply(op) }
        }
        cursor = disk.cursor
        outbox = disk.outbox
        recentItems = []
        hidden = disk.hidden
        // Local ops recorded after the last snapshot live only in the outbox; fold them back in.
        for op in outbox { store.apply(op) }
        let wall = self.wall
        clockHighWater = disk.clockHighWater
        // `.fresh` reproduces the restart bug the harness found (seed 488); production resumes from the high water.
        let resume = recovery == .persistedHighWater ? clockHighWater : nil
        clock = HybridClock(device: id, resumingAfter: resume, now: { wall.millis })
        online = true
    }
}
