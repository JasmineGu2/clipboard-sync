import ClipCore
import XCTest
@testable import ClipHarness

final class ConvergenceHarnessTests: XCTestCase {
    func testFiftySeedsConverge() {
        var total = HarnessStats()
        for seed in UInt64(1)...50 {
            let result = runSimulation(HarnessConfig(seed: seed))
            total = total + result.stats
            XCTAssertTrue(result.converged, result.failure ?? "seed \(seed)")
            XCTAssertFalse(result.finalItems.isEmpty, "seed \(seed) created nothing")
        }
        // The run must actually exercise every fault, or "converged" proves little.
        XCTAssertGreaterThan(total.pushRequestDrops, 0)
        XCTAssertGreaterThan(total.pushResponseDrops, 0)
        XCTAssertGreaterThan(total.pullResponseDrops, 0)
        XCTAssertGreaterThan(total.duplicatePushes, 0, "lost responses should cause duplicate pushes")
        XCTAssertGreaterThan(total.restarts, 0)
        XCTAssertGreaterThan(total.offlineToggles, 0)
        XCTAssertGreaterThan(total.clockJumps, 0)
    }

    func testEveryDeviceCountConverges() {
        for devices in 2...5 {
            for seed in UInt64(100)...104 {
                let result = runSimulation(HarnessConfig(seed: seed, devices: devices))
                XCTAssertEqual(result.devices, devices)
                XCTAssertTrue(result.converged, result.failure ?? "")
            }
        }
    }

    func testSameSeedGivesIdenticalResult() {
        let a = runSimulation(HarnessConfig(seed: 42))
        let b = runSimulation(HarnessConfig(seed: 42))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.trace, b.trace)

        let other = runSimulation(HarnessConfig(seed: 43))
        XCTAssertNotEqual(a.finalItems, other.finalItems, "different seeds should explore different histories")
    }

    func testSameFailingSeedGivesIdenticalFailure() {
        var config = HarnessConfig(seed: 5)
        config.mutation = .lastArrivalWins
        let a = runSimulation(config)
        let b = runSimulation(config)
        XCTAssertFalse(a.converged)
        XCTAssertEqual(a, b)
    }

    /// Mutation testing: each deliberately broken merge (implemented in ClipHarness, ClipCore untouched)
    /// must be caught. This proves the harness has teeth.
    func testHarnessDetectsBrokenMerges() {
        for mutation in MergeMutation.allCases where mutation != .none {
            var caught = 0
            var example: String?
            for seed in UInt64(1)...20 {
                var config = HarnessConfig(seed: seed)
                config.mutation = mutation
                let result = runSimulation(config)
                if !result.converged {
                    caught += 1
                    example = example ?? result.failure
                }
            }
            XCTAssertGreaterThanOrEqual(caught, 15, "\(mutation): only \(caught)/20 seeds caught the broken merge")
            XCTAssertTrue(example?.contains("seed ") ?? false, "failure should name its seed")
            XCTAssertTrue(example?.contains("last ") ?? false, "failure should carry an event trace")
        }
    }

    /// Real bug found by this harness: HybridClock keeps its state only in memory. A device that restarts with a
    /// fresh clock while its wall clock is behind re-issues timestamps it already used. The strict-tick
    /// invariant catches the backwards tick on most seeds.
    func testFreshClockAfterCrashIsCaught() {
        var caught = 0
        for seed in UInt64(1)...20 {
            var config = HarnessConfig(seed: seed)
            config.clockRecovery = .fresh
            if !runSimulation(config).converged { caught += 1 }
        }
        XCTAssertGreaterThanOrEqual(caught, 10)
    }

    /// The same bug turned into real divergence: with the clock check off, seed 488 makes d0 issue
    /// (195,2,d0) twice, before and after a crash, for `tag +blue` and `tag -blue` on the same item.
    /// LWW keeps whichever arrives first, so the result depends on delivery order.
    /// Pinned to the current scheduler; if the scheduler changes, find a new seed with
    /// `swift run ConvergenceHarness --clock-recovery fresh --no-clock-check`.
    func testFreshClockReusedTimestampDiverges() {
        var config = HarnessConfig(seed: 488)
        config.clockRecovery = .fresh
        config.checkClockMonotonic = false
        let result = runSimulation(config)
        XCTAssertFalse(result.converged)
        XCTAssertTrue(result.failure?.contains("timestamp reused") ?? false, result.failure ?? "")

        config.clockRecovery = .persistedHighWater
        XCTAssertTrue(runSimulation(config).converged, "persisting the clock's high-water mark fixes it")
    }

    func testFailureReportCarriesSeedAndBoundedTrace() {
        var config = HarnessConfig(seed: 9)
        config.mutation = .ignoreTombstones
        let result = runSimulation(config)
        XCTAssertFalse(result.converged)
        XCTAssertTrue(result.failure?.hasPrefix("seed 9 ") ?? false, result.failure ?? "")
        XCTAssertLessThanOrEqual(result.trace.count, 50)
        XCTAssertFalse(result.trace.isEmpty)
    }

    // MARK: - Simulated relay

    func testRelayDedupesAndPages() {
        let device = DeviceID(UUID())
        let ops = (0..<5).map { i in
            Op(itemID: ItemID(), timestamp: HLCTimestamp(wallMillis: UInt64(i), counter: 0, device: device), kind: .delete)
        }
        var relay = SimRelay()
        XCTAssertEqual(relay.append(Array(ops.prefix(3))), 3)
        XCTAssertEqual(relay.append(ops), 2, "already-stored op IDs are ignored")
        XCTAssertEqual(relay.log.map(\.seq), [1, 2, 3, 4, 5])

        let first = relay.page(after: 0, limit: 2)
        XCTAssertEqual(first.entries.map(\.seq), [1, 2])
        XCTAssertTrue(first.hasMore)
        let last = relay.page(after: 4, limit: 2)
        XCTAssertEqual(last.entries.map(\.seq), [5])
        XCTAssertFalse(last.hasMore)
        XCTAssertTrue(relay.page(after: 5, limit: 2).entries.isEmpty)
        XCTAssertEqual(relay.page(after: 0, limit: 0).entries.count, 1, "limit is clamped to at least 1")
    }
}
