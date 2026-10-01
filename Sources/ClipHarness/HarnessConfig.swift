import ClipCore
import Foundation

/// A deliberately broken merge rule, applied by simulated devices instead of ClipCore's.
/// Exists only to prove the harness notices broken merges (mutation testing). ClipCore itself is never changed.
public enum MergeMutation: String, CaseIterable, Sendable {
    /// The real ClipCore `Replica`. The only mode that should converge.
    case none
    /// LWW registers keep the older write: `ts <= current` swapped for `ts >= current`.
    case lwwReversed
    /// LWW registers ignore timestamps; whichever op arrives last wins.
    case lastArrivalWins
    /// `delete` ops are dropped.
    case ignoreTombstones
    /// A field edit clears the tombstone, so delete is no longer sticky.
    case editRevivesDeleted
}

/// How a simulated device rebuilds its HybridClock after a crash.
public enum ClockRecovery: String, CaseIterable, Sendable {
    /// The highest timestamp the device issued or observed is persisted with its outbox and replica,
    /// and fed to `HybridClock.observe` on restart.
    case persistedHighWater
    /// A fresh `HybridClock` with no memory of earlier ticks (what ClipCore's API offers on its own).
    case fresh
}

public struct HarnessConfig: Sendable {
    public var seed: UInt64
    /// Number of devices, 2...5. nil picks one from the seed.
    public var devices: Int?
    /// Scheduler steps before the network heals.
    public var steps: Int

    /// Push request lost before reaching the relay.
    public var pushRequestDropRate: Double = 0.15
    /// Push stored by the relay, but the response is lost, so the client retries a duplicate.
    public var pushResponseDropRate: Double = 0.15
    /// Pull response lost; the device applies nothing and keeps its cursor.
    public var pullResponseDropRate: Double = 0.15
    /// Per step: chance one device goes offline or comes back.
    public var offlineToggleRate: Double = 0.05
    /// Per step: chance one device crashes and restarts, losing unpersisted memory.
    public var crashRate: Double = 0.03
    /// Per step: chance one device's wall clock jumps (usually backwards).
    public var clockJumpRate: Double = 0.04

    public var mutation: MergeMutation = .none
    public var clockRecovery: ClockRecovery = .persistedHighWater
    /// Fail the run as soon as a device issues a timestamp not greater than its previous one.
    public var checkClockMonotonic: Bool = true

    public init(seed: UInt64, devices: Int? = nil, steps: Int = 400) {
        self.seed = seed
        self.devices = devices
        self.steps = steps
    }
}

public struct HarnessStats: Equatable, Sendable {
    public var ops = 0
    public var pushes = 0
    public var pulls = 0
    public var pushRequestDrops = 0
    public var pushResponseDrops = 0
    public var pullResponseDrops = 0
    /// Envelopes the relay ignored because it already had the op ID.
    public var duplicatePushes = 0
    public var restarts = 0
    public var offlineToggles = 0
    public var clockJumps = 0
    public var healRounds = 0

    public var drops: Int { pushRequestDrops + pushResponseDrops + pullResponseDrops }

    public init() {}

    public static func + (a: HarnessStats, b: HarnessStats) -> HarnessStats {
        var s = HarnessStats()
        s.ops = a.ops + b.ops
        s.pushes = a.pushes + b.pushes
        s.pulls = a.pulls + b.pulls
        s.pushRequestDrops = a.pushRequestDrops + b.pushRequestDrops
        s.pushResponseDrops = a.pushResponseDrops + b.pushResponseDrops
        s.pullResponseDrops = a.pullResponseDrops + b.pullResponseDrops
        s.duplicatePushes = a.duplicatePushes + b.duplicatePushes
        s.restarts = a.restarts + b.restarts
        s.offlineToggles = a.offlineToggles + b.offlineToggles
        s.clockJumps = a.clockJumps + b.clockJumps
        s.healRounds = a.healRounds + b.healRounds
        return s
    }
}

public struct HarnessResult: Equatable, Sendable {
    public var seed: UInt64
    public var devices: Int
    public var converged: Bool
    /// nil on success. On failure: the seed, what broke, and the last events.
    public var failure: String?
    /// The last ~50 scheduler events, oldest first.
    public var trace: [String]
    public var stats: HarnessStats
    /// Device 0's final items (equal on every device when converged). Used to check determinism.
    public var finalItems: [ItemID: ItemState]
}
