import Foundation

extension ItemState {
    /// Folds one op into this item. Commutative and idempotent: see docs/design.md §2.
    public mutating func apply(_ op: Op) {
        precondition(op.itemID == id, "op for a different item")
        switch op.kind {
        case .create(let content):
            // First writer (lowest timestamp) wins, so a duplicate or racing create can't change content.
            if createdBy.map({ op.timestamp < $0 }) ?? true {
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

    /// How far ahead of our wall clock a remote timestamp may pull us. A peer with a wildly wrong clock
    /// still merges correctly, but can't drag every device's clock (and LWW) into the far future.
    public static let maxForwardSkewMillis: UInt64 = 60 * 60 * 1000

    /// `resumingAfter` is the highest timestamp this device issued or observed before it last stopped.
    /// Required on purpose: a clock that forgets it can re-issue a timestamp after a restart, which breaks
    /// LWW convergence (found by the harness, seed 488; see docs/decisions.md). Pass nil only for a brand-new device.
    public init(device: DeviceID, resumingAfter: HLCTimestamp?, now: @escaping @Sendable () -> UInt64 = HybridClock.systemMillis) {
        self.device = device
        self.now = now
        if let resumingAfter { observe(resumingAfter) }
    }

    /// The highest timestamp issued or observed; persist it and pass it back as `resumingAfter`.
    public var highWater: HLCTimestamp {
        HLCTimestamp(wallMillis: last.wall, counter: last.counter, device: device)
    }

    public static let systemMillis: @Sendable () -> UInt64 = {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    public mutating func tick() -> HLCTimestamp {
        let physical = now()
        if physical > last.wall {
            last = (physical, 0)
        } else if last.counter == .max {
            // A peer can hand us counter == .max via observe(); `+= 1` would trap. Borrow a millisecond instead.
            last = (last.wall + 1, 0)
        } else {
            last.counter += 1
        }
        return HLCTimestamp(wallMillis: last.wall, counter: last.counter, device: device)
    }

    /// Moves the clock past a remote timestamp so the next local tick sorts after it.
    public mutating func observe(_ remote: HLCTimestamp) {
        let ceiling = now().addingReportingOverflow(Self.maxForwardSkewMillis)
        let limit = ceiling.overflow ? UInt64.max - 1 : ceiling.partialValue
        if remote.wallMillis > limit {
            // Far-future peer clock: advance only to the ceiling. Also keeps `last.wall + 1` in tick() from overflowing.
            if limit > last.wall { last = (limit, 0) }
            return
        }
        if remote.wallMillis > last.wall {
            last = (remote.wallMillis, remote.counter)
        } else if remote.wallMillis == last.wall, remote.counter > last.counter {
            last.counter = remote.counter
        }
    }
}
