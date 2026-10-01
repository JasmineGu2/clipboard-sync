import Foundation

extension ItemState {
    /// Folds one op into this item. Commutative and idempotent: see docs/design.md §2.
    public mutating func apply(_ op: Op) {
        precondition(op.itemID == id, "op for a different item")
        switch op.kind {
        case .create(let content):
            // First writer (lowest timestamp) wins, so a duplicate or racing create can't change content.
            if createdBy == nil || op.timestamp < createdBy! {
                self.content = content
                self.createdBy = op.timestamp
            }
        case .setPinned(let value):
            pinned.merge(value, at: op.timestamp)
        case .setTitle(let value):
            title.merge(value, at: op.timestamp)
        case .setTag(let name, let present):
            tags[name, default: LWW(false)].merge(present, at: op.timestamp)
        case .delete:
            deleted = true
        }
    }
}

extension LWW {
    public mutating func merge(_ newValue: Value, at ts: HLCTimestamp) {
        if let current = timestamp, ts <= current { return }
        value = newValue
        timestamp = ts
    }
}

/// Hybrid logical clock. Not thread-safe; owners serialize access (SyncEngine is an actor).
public struct HybridClock: Sendable {
    public let device: DeviceID
    private var last: (wall: UInt64, counter: UInt32) = (0, 0)
    private let now: @Sendable () -> UInt64

    public init(device: DeviceID, now: @escaping @Sendable () -> UInt64 = HybridClock.systemMillis) {
        self.device = device
        self.now = now
    }

    public static let systemMillis: @Sendable () -> UInt64 = {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    public mutating func tick() -> HLCTimestamp {
        let physical = now()
        if physical > last.wall {
            last = (physical, 0)
        } else {
            last.counter += 1
        }
        return HLCTimestamp(wallMillis: last.wall, counter: last.counter, device: device)
    }

    /// Moves the clock past a remote timestamp so the next local tick sorts after it.
    public mutating func observe(_ remote: HLCTimestamp) {
        if remote.wallMillis > last.wall {
            last = (remote.wallMillis, remote.counter)
        } else if remote.wallMillis == last.wall, remote.counter > last.counter {
            last.counter = remote.counter
        }
    }
}
