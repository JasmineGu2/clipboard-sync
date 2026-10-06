import ClipHarness
import Foundation

// Thin CLI over ClipHarness.runSimulation. Exits 1 if any seed fails to converge.

struct Options {
    var seeds = 500
    var start: UInt64 = 1
    var steps = 400
    var devices: Int?
    var verbose = false
    var mutation = MergeMutation.none
    var clockRecovery = ClockRecovery.persistedHighWater
    var clockCheck = true
    var expiry = ExpiryMode.off
    var blobGC = BlobGCMode.off
    var revoke = RevokeMode.off
    var revokeBlobs = RevokeBlobMode.reuploadHeld

    func config(seed: UInt64) -> HarnessConfig {
        var c = HarnessConfig(seed: seed, devices: devices, steps: steps)
        c.mutation = mutation
        c.clockRecovery = clockRecovery
        c.checkClockMonotonic = clockCheck
        c.expiry = expiry
        c.blobGC = blobGC
        c.revoke = revoke
        c.revokeBlobs = revokeBlobs
        return c
    }

    /// Flags other than --seeds/--start/--verbose, for the repro line.
    var extraFlags: String {
        var s = " --steps \(steps)"
        if let devices { s += " --devices \(devices)" }
        if mutation != .none { s += " --mutation \(mutation.rawValue)" }
        if clockRecovery != .persistedHighWater { s += " --clock-recovery \(clockRecovery.rawValue)" }
        if !clockCheck { s += " --no-clock-check" }
        if expiry != .off { s += " --expiry \(expiry.rawValue)" }
        if blobGC != .off { s += " --blob-gc \(blobGC.rawValue)" }
        if revoke != .off { s += " --revoke \(revoke.rawValue)" }
        if revokeBlobs != .reuploadHeld { s += " --revoke-blobs \(revokeBlobs.rawValue)" }
        return s
    }
}

func usage() -> Never {
    print("""
        usage: ConvergenceHarness [--seeds N] [--start S] [--steps K] [--devices 2...5] [--verbose]
               [--mutation \(MergeMutation.allCases.map(\.rawValue).joined(separator: "|"))]
               [--clock-recovery \(ClockRecovery.allCases.map(\.rawValue).joined(separator: "|"))] [--no-clock-check]
               [--expiry \(ExpiryMode.allCases.map(\.rawValue).joined(separator: "|"))]
               [--blob-gc \(BlobGCMode.allCases.map(\.rawValue).joined(separator: "|"))]
               [--revoke \(RevokeMode.allCases.map(\.rawValue).joined(separator: "|"))]
               [--revoke-blobs \(RevokeBlobMode.allCases.map(\.rawValue).joined(separator: "|"))]
                 (images and files across the revoke; needs --revoke and --blob-gc)
        """)
    exit(2)
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var it = args.makeIterator()
    func value<T: LosslessStringConvertible>(_ flag: String) -> T {
        guard let raw = it.next(), let v = T(raw) else {
            print("\(flag) needs a number")
            usage()
        }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--seeds": options.seeds = value(arg)
        case "--start": options.start = value(arg)
        case "--steps": options.steps = value(arg)
        case "--devices":
            let n: Int = value(arg)
            guard (2...5).contains(n) else { print("--devices must be 2...5"); usage() }
            options.devices = n
        case "--verbose", "-v": options.verbose = true
        case "--mutation":
            guard let raw = it.next(), let m = MergeMutation(rawValue: raw) else { usage() }
            options.mutation = m
        case "--clock-recovery":
            guard let raw = it.next(), let r = ClockRecovery(rawValue: raw) else { usage() }
            options.clockRecovery = r
        case "--no-clock-check": options.clockCheck = false
        case "--expiry":
            guard let raw = it.next(), let e = ExpiryMode(rawValue: raw) else { usage() }
            options.expiry = e
        case "--blob-gc":
            guard let raw = it.next(), let b = BlobGCMode(rawValue: raw) else { usage() }
            options.blobGC = b
        case "--revoke":
            guard let raw = it.next(), let r = RevokeMode(rawValue: raw) else { usage() }
            options.revoke = r
        case "--revoke-blobs":
            guard let raw = it.next(), let r = RevokeBlobMode(rawValue: raw) else { usage() }
            options.revokeBlobs = r
        case "--help", "-h": usage()
        default:
            print("unknown argument \(arg)")
            usage()
        }
    }
    guard options.seeds > 0, options.steps >= 0 else { usage() }
    if options.revokeBlobs != .reuploadHeld, options.revoke == .off || options.blobGC == .off {
        print("--revoke-blobs needs --revoke and --blob-gc")
        usage()
    }
    return options
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let clock = ContinuousClock()
let started = clock.now
var total = HarnessStats()
var failures: [HarnessResult] = []
let progressEvery = max(1, options.seeds / 10)

for i in 0..<options.seeds {
    let seed = options.start + UInt64(i)
    let result = runSimulation(options.config(seed: seed))
    total = total + result.stats
    if !result.converged { failures.append(result) }
    if options.verbose {
        let s = result.stats
        print("seed \(seed): \(result.converged ? "ok" : "FAILED") devices=\(result.devices) ops=\(s.ops) pushes=\(s.pushes)"
            + " pulls=\(s.pulls) drops=\(s.drops) dupes=\(s.duplicatePushes) restarts=\(s.restarts) items=\(result.finalItems.count)")
        if let failure = result.failure { print(failure) }
    } else if (i + 1) % progressEvery == 0 || i + 1 == options.seeds {
        print("[\(i + 1)/\(options.seeds)] \(i + 1 - failures.count) converged")
    }
}

let elapsed = clock.now - started
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
let converged = options.seeds - failures.count
print("\(converged)/\(options.seeds) seeds converged (ops=\(total.ops), pushes=\(total.pushes), drops=\(total.drops),"
    + " duplicate pushes=\(total.duplicatePushes), restarts=\(total.restarts)"
    + (options.expiry == .off ? "" : ", expiry sweeps=\(total.expirySweeps), expired=\(total.expiredItems)")
    + (options.blobGC == .off ? "" : ", blob GC sweeps=\(total.blobGCSweeps), blobs collected=\(total.blobsCollected)")
    + (options.revoke == .off ? "" : ", revokes=\(total.revokes), recoveries=\(total.revokeRecoveries)")
    + (options.revoke == .off || options.blobGC == .off ? ""
        : ", blob fetches=\(total.blobFetches), uploads after revoke=\(total.blobReuploads)")
    + ") in \(String(format: "%.1f", seconds))s")

if let first = failures.first, let failure = first.failure {
    print("\nFAILED: \(failures.count) seed(s): \(failures.prefix(20).map { String($0.seed) }.joined(separator: ", "))")
    if !options.verbose { print(failure) }
    print("\nrepro: swift run ConvergenceHarness --start \(first.seed) --seeds 1\(options.extraFlags) --verbose")
    exit(1)
}
