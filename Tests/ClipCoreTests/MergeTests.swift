import Foundation
import XCTest
@testable import ClipCore

// MARK: - Helpers

/// Small seeded RNG so random tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uuid() -> UUID {
        let a = next(), b = next()
        func byte(_ x: UInt64, _ i: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: x >> (i * 8)) }
        return UUID(uuid: (
            byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
            byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)
        ))
    }
}

/// A settable wall clock for HybridClock tests.
final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ millis: UInt64) { value = millis }

    var millis: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

private func makeClock(_ device: DeviceID, _ time: ManualTime) -> HybridClock {
    HybridClock(device: device, resumingAfter: nil, now: { time.millis })
}

private func content(_ text: String, from device: DeviceID, seconds: Int = 0) -> ItemContent {
    ItemContent(
        text: text,
        sourceDevice: device,
        sourceDeviceName: "device-\(device.description.prefix(4))",
        createdAt: Date(timeIntervalSince1970: TimeInterval(seconds))
    )
}

/// Device IDs whose order is known: `low < high`.
private let low = DeviceID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
private let high = DeviceID(UUID(uuid: (0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))

private func ts(_ wall: UInt64, _ counter: UInt32 = 0, _ device: DeviceID = low) -> HLCTimestamp {
    HLCTimestamp(wallMillis: wall, counter: counter, device: device)
}

/// Applies ops to a fresh Replica in the given order.
private func fold(_ ops: [Op]) -> Replica {
    var replica = Replica()
    for op in ops { replica.apply(op) }
    return replica
}

/// Applies `ops` in every permutation (ops lists here are small) and asserts all results are equal.
private func assertOrderIndependent(_ ops: [Op], file: StaticString = #filePath, line: UInt = #line) -> Replica {
    let reference = fold(ops)
    for perm in permutations(ops) {
        XCTAssertEqual(fold(perm), reference, "order-dependent result", file: file, line: line)
    }
    return reference
}

private func permutations<T>(_ xs: [T]) -> [[T]] {
    guard let first = xs.first else { return [[]] }
    return permutations(Array(xs.dropFirst())).flatMap { rest in
        (0...rest.count).map { i in
            var p = rest
            p.insert(first, at: i)
            return p
        }
    }
}

// MARK: - Merge rules

final class MergeTests: XCTestCase {
    let item = ItemID()

    func testLWWLaterTimestampWinsInEitherOrder() {
        let ops = [
            Op(itemID: item, timestamp: ts(10), kind: .create(content("hi", from: low))),
            Op(itemID: item, timestamp: ts(20), kind: .setTitle("old")),
            Op(itemID: item, timestamp: ts(30), kind: .setTitle("new")),
            Op(itemID: item, timestamp: ts(25), kind: .setPinned(true)),
            Op(itemID: item, timestamp: ts(21), kind: .setPinned(false)),
        ]
        let state = assertOrderIndependent(ops).item(item)
        XCTAssertEqual(state?.title.value, "new")
        XCTAssertEqual(state?.title.timestamp, ts(30))
        XCTAssertEqual(state?.pinned.value, true)
    }

    func testLWWCanClearTitleBackToNil() {
        let ops = [
            Op(itemID: item, timestamp: ts(10), kind: .setTitle("named")),
            Op(itemID: item, timestamp: ts(11), kind: .setTitle(nil)),
        ]
        let state = assertOrderIndependent(ops).item(item)
        XCTAssertEqual(state?.title.value, .some(nil))
        XCTAssertEqual(state?.title.timestamp, ts(11))
    }

    func testEqualWallClocksBreakTiesByCounterThenDevice() {
        XCTAssertLessThan(ts(5, 0, high), ts(5, 1, low))
        XCTAssertLessThan(ts(5, 3, low), ts(5, 3, high))
        XCTAssertLessThan(ts(4, 99, high), ts(5, 0, low))

        let ops = [
            Op(itemID: item, timestamp: ts(5, 3, low), kind: .setTitle("from low")),
            Op(itemID: item, timestamp: ts(5, 3, high), kind: .setTitle("from high")),
        ]
        XCTAssertEqual(assertOrderIndependent(ops).item(item)?.title.value, "from high")
    }

    func testDeleteIsStickyAgainstLaterEdits() {
        let ops = [
            Op(itemID: item, timestamp: ts(10), kind: .create(content("secret", from: low))),
            Op(itemID: item, timestamp: ts(20), kind: .delete),
            Op(itemID: item, timestamp: ts(30), kind: .setPinned(true)),
            Op(itemID: item, timestamp: ts(31), kind: .setTitle("revived?")),
            Op(itemID: item, timestamp: ts(32), kind: .setTag("work", present: true)),
        ]
        let replica = assertOrderIndependent(ops)
        XCTAssertEqual(replica.item(item)?.deleted, true)
        XCTAssertEqual(replica.item(item)?.isVisible, false)
        XCTAssertTrue(replica.visibleItems.isEmpty)
    }

    func testDeleteBeforeCreateStaysDeleted() {
        let ops = [
            Op(itemID: item, timestamp: ts(20), kind: .delete),
            Op(itemID: item, timestamp: ts(10), kind: .create(content("x", from: low))),
        ]
        let replica = assertOrderIndependent(ops)
        XCTAssertNotNil(replica.item(item)?.content)
        XCTAssertEqual(replica.item(item)?.isVisible, false)
    }

    func testConcurrentTagAddAndRemoveHigherTimestampWins() {
        // Two devices race on the same tag at the same wall time; the device ID decides.
        let add = Op(itemID: item, timestamp: ts(50, 0, high), kind: .setTag("work", present: true))
        let remove = Op(itemID: item, timestamp: ts(50, 0, low), kind: .setTag("work", present: false))
        let create = Op(itemID: item, timestamp: ts(1), kind: .create(content("c", from: low)))
        XCTAssertEqual(assertOrderIndependent([create, add, remove]).item(item)?.visibleTags, ["work"])

        let laterRemove = Op(itemID: item, timestamp: ts(51, 0, low), kind: .setTag("work", present: false))
        XCTAssertEqual(assertOrderIndependent([create, add, laterRemove]).item(item)?.visibleTags, [])
    }

    func testTagsAreIndependentPerName() {
        let ops = [
            Op(itemID: item, timestamp: ts(1), kind: .create(content("c", from: low))),
            Op(itemID: item, timestamp: ts(2), kind: .setTag("b", present: true)),
            Op(itemID: item, timestamp: ts(3), kind: .setTag("a", present: true)),
            Op(itemID: item, timestamp: ts(4), kind: .setTag("b", present: false)),
            Op(itemID: item, timestamp: ts(5), kind: .setTag("c", present: true)),
        ]
        XCTAssertEqual(assertOrderIndependent(ops).item(item)?.visibleTags, ["a", "c"])
    }

    func testCreateArrivingAfterFieldOps() {
        let edits = [
            Op(itemID: item, timestamp: ts(20), kind: .setTitle("title")),
            Op(itemID: item, timestamp: ts(21), kind: .setPinned(true)),
            Op(itemID: item, timestamp: ts(22), kind: .setTag("t", present: true)),
        ]
        let create = Op(itemID: item, timestamp: ts(10), kind: .create(content("body", from: low)))

        var replica = Replica()
        for op in edits { replica.apply(op) }
        XCTAssertNotNil(replica.item(item), "field ops create a placeholder state")
        XCTAssertEqual(replica.item(item)?.isVisible, false, "hidden until the create arrives")
        XCTAssertTrue(replica.visibleItems.isEmpty)

        replica.apply(create)
        XCTAssertEqual(replica, fold([create] + edits))
        let state = replica.item(item)
        XCTAssertEqual(state?.isVisible, true)
        XCTAssertEqual(state?.content?.text, "body")
        XCTAssertEqual(state?.title.value, "title")
        XCTAssertEqual(state?.pinned.value, true)
        XCTAssertEqual(state?.visibleTags, ["t"])
    }

    func testDuplicateAndRacingCreatesKeepFirstWriter() {
        let first = Op(itemID: item, timestamp: ts(10, 0, high), kind: .create(content("first", from: high)))
        let second = Op(itemID: item, timestamp: ts(10, 1, low), kind: .create(content("second", from: low)))
        let replayed = Op(itemID: item, timestamp: first.timestamp, kind: first.kind) // same create, new OpID
        let state = assertOrderIndependent([first, second, replayed]).item(item)
        XCTAssertEqual(state?.content?.text, "first")
        XCTAssertEqual(state?.createdBy, first.timestamp)
    }

    func testItemStateApplyIsIdempotent() {
        var state = ItemState(id: item)
        let ops = [
            Op(itemID: item, timestamp: ts(1), kind: .create(content("c", from: low))),
            Op(itemID: item, timestamp: ts(2), kind: .setTitle("t")),
            Op(itemID: item, timestamp: ts(3), kind: .setTag("x", present: true)),
        ]
        for op in ops { state.apply(op) }
        let once = state
        for op in ops { state.apply(op) }
        XCTAssertEqual(state, once)
    }
}

// MARK: - Replica

final class ReplicaTests: XCTestCase {
    func testApplyReturnsFalseForSeenOp() {
        let id = ItemID()
        let op = Op(itemID: id, timestamp: ts(1), kind: .create(content("a", from: low)))
        var replica = Replica()
        XCTAssertTrue(replica.apply(op))
        let after = replica
        XCTAssertFalse(replica.apply(op))
        XCTAssertEqual(replica, after)
        XCTAssertEqual(replica.seenOps, [op.id])
    }

    func testVisibleItemsNewestFirstAndPinnedNotRegrouped() {
        let old = ItemID(), mid = ItemID(), new = ItemID(), deleted = ItemID(), orphan = ItemID()
        let ops = [
            Op(itemID: mid, timestamp: ts(20), kind: .create(content("mid", from: low))),
            Op(itemID: old, timestamp: ts(10), kind: .create(content("old", from: low))),
            Op(itemID: new, timestamp: ts(30), kind: .create(content("new", from: low))),
            Op(itemID: old, timestamp: ts(40), kind: .setPinned(true)),
            Op(itemID: deleted, timestamp: ts(35), kind: .create(content("gone", from: low))),
            Op(itemID: deleted, timestamp: ts(36), kind: .delete),
            Op(itemID: orphan, timestamp: ts(50), kind: .setTitle("no create yet")),
        ]
        let replica = fold(ops)
        XCTAssertEqual(replica.visibleItems.map(\.id), [new, mid, old])
        XCTAssertEqual(replica.items.count, 5)
        XCTAssertNil(replica.item(ItemID()))
        XCTAssertEqual(replica.item(orphan)?.title.value, "no create yet")
    }

    func testVisibleItemsOrderUsesFullTimestamp() {
        let a = ItemID(), b = ItemID(), c = ItemID()
        let replica = fold([
            Op(itemID: a, timestamp: ts(10, 0, high), kind: .create(content("a", from: high))),
            Op(itemID: b, timestamp: ts(10, 1, low), kind: .create(content("b", from: low))),
            Op(itemID: c, timestamp: ts(10, 0, low), kind: .create(content("c", from: low))),
        ])
        XCTAssertEqual(replica.visibleItems.map(\.id), [b, a, c])
    }

    func testCodableRoundTrip() throws {
        let id = ItemID()
        let replica = fold([
            Op(itemID: id, timestamp: ts(1), kind: .create(content("a", from: low, seconds: 1_700_000_000))),
            Op(itemID: id, timestamp: ts(2), kind: .setTag("k", present: true)),
            Op(itemID: id, timestamp: ts(3), kind: .setTitle(nil)),
        ])
        let data = try JSONEncoder().encode(replica)
        XCTAssertEqual(try JSONDecoder().decode(Replica.self, from: data), replica)
    }
}

// MARK: - Hybrid logical clock

final class HybridClockTests: XCTestCase {
    func testTickIsStrictlyIncreasingEvenWhenWallClockGoesBackwards() {
        let time = ManualTime(1_000)
        var clock = makeClock(low, time)
        var previous = clock.tick()
        for wall: UInt64 in [1_000, 1_000, 999, 500, 0, 1_001, 1_001, 2_000, 1_500, 1_500] {
            time.millis = wall
            let next = clock.tick()
            XCTAssertGreaterThan(next, previous, "wall \(wall)")
            XCTAssertGreaterThanOrEqual(next.wallMillis, previous.wallMillis, "HLC wall never moves backwards")
            previous = next
        }
    }

    func testTickFollowsPhysicalTimeWhenItAdvances() {
        let time = ManualTime(100)
        var clock = makeClock(low, time)
        _ = clock.tick()
        time.millis = 200
        XCTAssertEqual(clock.tick(), ts(200, 0, low))
    }

    func testObserveRemoteAheadMakesNextTickGreater() {
        let time = ManualTime(1_000)
        var clock = makeClock(low, time)
        _ = clock.tick()
        let remote = ts(5_000, 7, high)
        clock.observe(remote)
        XCTAssertGreaterThan(clock.tick(), remote)
    }

    func testObserveEqualWallHigherCounterMakesNextTickGreater() {
        let time = ManualTime(1_000)
        var clock = makeClock(low, time)
        _ = clock.tick()
        // The remote's device sorts higher, so only the counter can put the next tick ahead of it.
        let remote = ts(1_000, 9, high)
        clock.observe(remote)
        XCTAssertGreaterThan(clock.tick(), remote)
    }

    func testObserveRemoteBehindDoesNotMoveClockBack() {
        let time = ManualTime(10_000)
        var clock = makeClock(low, time)
        let before = clock.tick()
        clock.observe(ts(5, 3, high))
        time.millis = 0
        XCTAssertGreaterThan(clock.tick(), before)
    }

    func testObserveThenTickExceedsRemoteForRandomInputs() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<500 {
            let time = ManualTime(UInt64.random(in: 0...100, using: &rng))
            var clock = makeClock(DeviceID(rng.uuid()), time)
            for _ in 0..<Int.random(in: 0...3, using: &rng) { _ = clock.tick() }
            let remote = HLCTimestamp(
                wallMillis: UInt64.random(in: 0...100, using: &rng),
                counter: UInt32.random(in: 0...5, using: &rng),
                device: DeviceID(rng.uuid())
            )
            clock.observe(remote)
            time.millis = UInt64.random(in: 0...100, using: &rng)
            XCTAssertGreaterThan(clock.tick(), remote)
        }
    }

    func testCounterOverflowFromRemoteDoesNotTrap() {
        let time = ManualTime(1_000)
        var clock = makeClock(low, time)
        let remote = ts(1_000, .max, high)
        clock.observe(remote)
        let next = clock.tick()
        XCTAssertGreaterThan(next, remote)
        XCTAssertGreaterThan(clock.tick(), next)
    }
}

// MARK: - Property test

final class ConvergenceTests: XCTestCase {
    /// 200 seeded random op sets. Each is applied in shuffled orders with duplicates; every result must be equal.
    func testRandomOpSetsConvergeInAnyOrderWithDuplicates() {
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            let ops = randomOps(using: &rng)
            let reference = fold(ops)

            for _ in 0..<5 {
                var delivery = ops
                for _ in 0..<Int.random(in: 0...ops.count, using: &rng) {
                    if let dup = ops.randomElement(using: &rng) { delivery.append(dup) }
                }
                delivery.shuffle(using: &rng)

                var replica = Replica()
                var accepted = 0
                for op in delivery {
                    if replica.apply(op) { accepted += 1 }
                }

                XCTAssertEqual(accepted, ops.count, "seed \(seed): each op applies exactly once")
                XCTAssertEqual(replica, reference, "seed \(seed): replicas diverged")
                XCTAssertEqual(replica.visibleItems, reference.visibleItems, "seed \(seed)")
            }
        }
    }

    /// Ops from 3 devices on 4 items, with skewed and backward-jumping clocks, partial syncing, racing creates,
    /// and frequent equal wall times so tiebreaks get exercised.
    private func randomOps(using rng: inout SplitMix64) -> [Op] {
        let devices = (0..<3).map { _ in DeviceID(rng.uuid()) }
        let times = devices.map { _ in ManualTime(UInt64.random(in: 0...20, using: &rng)) }
        var clocks = zip(devices, times).map { makeClock($0, $1) }
        let items = (0..<4).map { _ in ItemID(rng.uuid()) }
        let titles: [String?] = [nil, "a", "b", "c"]
        let tags = ["red", "green", "blue"]

        var ops: [Op] = []
        for _ in 0..<Int.random(in: 5...40, using: &rng) {
            let d = Int.random(in: 0..<devices.count, using: &rng)
            let step = Int64.random(in: -3...4, using: &rng)
            times[d].millis = UInt64(max(0, Int64(times[d].millis) + step))

            // Sometimes this device has synced another device's latest op first.
            if Bool.random(using: &rng), let seen = ops.randomElement(using: &rng) {
                clocks[d].observe(seen.timestamp)
            }

            let kind: OpKind
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2:
                kind = .create(content("t\(rng.next() % 1000)", from: devices[d], seconds: Int(rng.next() % 1000)))
            case 3:
                kind = .setPinned(Bool.random(using: &rng))
            case 4, 5:
                kind = .setTitle(titles.randomElement(using: &rng) ?? nil)
            case 6...8:
                kind = .setTag(tags.randomElement(using: &rng) ?? "red", present: Bool.random(using: &rng))
            default:
                kind = .delete
            }
            let item = items.randomElement(using: &rng) ?? items[0]
            ops.append(Op(id: OpID(rng.uuid()), itemID: item, timestamp: clocks[d].tick(), kind: kind))
        }
        return ops
    }
}

final class ClockSafetyTests: XCTestCase {
    func testResumingAfterKeepsTicksAboveStoredHighWater() {
        let device = DeviceID()
        let stored = HLCTimestamp(wallMillis: 5_000, counter: 7, device: device)
        // Wall clock is behind the stored high water, as after a restart with a clock that jumped back.
        var clock = HybridClock(device: device, resumingAfter: stored, now: { 1_000 })
        XCTAssertGreaterThan(clock.tick(), stored)
    }

    func testFarFutureRemoteIsClampedAndCannotOverflow() {
        let device = DeviceID()
        var clock = HybridClock(device: device, resumingAfter: nil, now: { 10_000 })
        clock.observe(HLCTimestamp(wallMillis: .max, counter: .max, device: DeviceID()))
        let ts = clock.tick()  // must not trap
        XCTAssertLessThanOrEqual(ts.wallMillis, 10_000 + HybridClock.maxForwardSkewMillis)
        XCTAssertGreaterThan(clock.tick(), ts)
    }

    func testModestRemoteSkewIsStillObserved() {
        let device = DeviceID()
        var clock = HybridClock(device: device, resumingAfter: nil, now: { 10_000 })
        let remote = HLCTimestamp(wallMillis: 70_000, counter: 3, device: DeviceID())
        clock.observe(remote)
        XCTAssertGreaterThan(clock.tick(), remote)
    }
}
