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

/// How simulated devices expire unpinned items older than `expiryAfterMillis` (F14).
public enum ExpiryMode: String, CaseIterable, Sendable {
    /// No sweeps. The default, so seeds without expiry replay exactly as before it existed.
    case off
    /// A sweep records a `delete` op per expired item, like SyncEngine.expireItems. Should converge.
    case deleteOps
    /// Broken on purpose: a sweep hides expired items on that device only and sends nothing.
    /// Proves the harness catches devices that disagree about what's visible.
    case hideLocally
}

/// Image and file items, and how simulated devices garbage-collect their blobs on the relay (F11, F12).
/// A create op's blob lands on the relay with the op itself (the real client uploads it right after).
public enum BlobGCMode: String, CaseIterable, Sendable {
    /// No blobs. The default, so seeds without blobs replay exactly as before they existed.
    case off
    /// Creates carry a blob. A sweep deletes from the relay only blobs of items its replica shows as deleted,
    /// like SyncEngine.collectGarbage. Deletes are sticky, so those can never be needed again. Should pass.
    case deadItemsOnly
    /// Broken on purpose: a sweep deletes every relay blob that no visible item in its replica points at, so it
    /// also deletes blobs of items it hasn't pulled yet. Proves the harness catches unsafe collection.
    case unreferencedOnRelay
}

/// What happens when one device is revoked mid-run (F13). The relay wipes its log and starts a new epoch, the
/// revoked device can no longer push or pull, and each remaining device notices on its next request.
public enum RevokeMode: String, CaseIterable, Sendable {
    /// No revoke. The default, so seeds without it replay exactly as before it existed.
    case off
    /// What SyncEngine does: a remaining device queues every op it holds for push again and pulls from 0
    /// (`markAllOutbound` on the epoch change). Should converge.
    case repushAll
    /// Broken on purpose: remaining devices only reset their cursor and push what was still queued, so ops that
    /// lived only on the wiped relay never come back. Proves the harness catches a lossy revoke.
    case resetCursorOnly
}

/// Images and files across a revoke (F13 x F11/F12). Only matters with both `--revoke` and `--blob-gc` on: then
/// each device holds the blobs it created or downloaded, a push uploads a create op's blob only if the pusher holds
/// it, each blob on the relay remembers which vault key sealed it, and the final check asks that every visible item
/// whose blob a remaining device holds is on the relay under the current key, and that nothing on the relay is
/// still under the old one.
public enum RevokeBlobMode: String, CaseIterable, Sendable {
    /// What the relay and SyncEngine do: the revoke wipes relay blobs with the log, and a recovering device
    /// re-uploads every blob it holds (`markAllOutbound` queues them) under the new key. Should pass.
    case reuploadHeld
    /// Broken on purpose: the revoke keeps relay blobs. Chunks are never overwritten, so re-uploads under the new
    /// key are ignored and remaining devices can't open what's there (and a leaked backup still opens with the
    /// old key).
    case keepRelayBlobs
    /// Broken on purpose: the relay wipes blobs but devices re-push only ops, so blobs they hold are lost.
    case opsOnly
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

    public var expiry: ExpiryMode = .off
    /// Per step, when expiry is on: chance one device runs an expiry sweep.
    public var expirySweepRate: Double = 0.03
    /// Unpinned items created more than this long ago (by the sweeping device's wall clock) expire.
    /// Simulated time moves 0–2 ms per step, so this is a few hundred steps.
    public var expiryAfterMillis: UInt64 = 100

    public var blobGC: BlobGCMode = .off
    /// Per step, when blobs are on: chance one online device runs a blob garbage-collection sweep.
    public var blobGCSweepRate: Double = 0.03
    public var revoke: RevokeMode = .off
    /// Used only when `revoke` and `blobGC` are both on.
    public var revokeBlobs: RevokeBlobMode = .reuploadHeld
    /// Per pulled image or file item, when `revokeBlobs` applies: chance the device downloads its blob.
    public var blobFetchRate: Double = 0.3

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
    public var expirySweeps = 0
    public var expiredItems = 0
    public var blobGCSweeps = 0
    public var blobsCollected = 0
    public var revokes = 0
    /// Remaining devices that noticed the revoke and recovered.
    public var revokeRecoveries = 0
    /// With `revokeBlobs`: blobs devices downloaded, and blobs uploaded after the revoke (re-uploads and new ones).
    public var blobFetches = 0
    public var blobReuploads = 0

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
        s.expirySweeps = a.expirySweeps + b.expirySweeps
        s.expiredItems = a.expiredItems + b.expiredItems
        s.blobGCSweeps = a.blobGCSweeps + b.blobGCSweeps
        s.blobsCollected = a.blobsCollected + b.blobsCollected
        s.revokes = a.revokes + b.revokes
        s.revokeRecoveries = a.revokeRecoveries + b.revokeRecoveries
        s.blobFetches = a.blobFetches + b.blobFetches
        s.blobReuploads = a.blobReuploads + b.blobReuploads
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
