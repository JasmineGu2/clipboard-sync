import Foundation
import Logging

/// Removes blob uploads that never finished (design §6, "Garbage collection"). Runs once at startup and then on a
/// timer from `ClipRelay`'s main.
///
/// Only incomplete blobs go, and only once no chunk of them has arrived for `maxAgeSeconds`. A device that comes
/// back after that just uploads the whole blob again: its resume query gets 404 and it starts from chunk 0.
/// Complete blobs stay however old they are, because the relay can't see which item a blob belongs to, so it
/// can't tell a dead one from one a new device will want tomorrow. Devices delete those (`blob_relay_gc`).
public struct BlobPurger: Sendable {
    /// Seven days: longer than a laptop stays shut over a long weekend or a trip, so a paused upload resumes rather
    /// than starting over, and short enough that abandoned chunks don't sit for months.
    public static let defaultMaxAgeSeconds: Int64 = 7 * 24 * 60 * 60
    /// Hourly. The purge is one indexed transaction; nothing needs it sooner.
    public static let defaultIntervalSeconds: Int64 = 60 * 60

    public let storage: any RelayStorage
    public var maxAgeSeconds: Int64
    public var now: @Sendable () -> Int64

    public init(
        storage: any RelayStorage, maxAgeSeconds: Int64 = BlobPurger.defaultMaxAgeSeconds,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.storage = storage
        self.maxAgeSeconds = maxAgeSeconds
        self.now = now
    }

    /// One pass: purges incomplete blobs untouched for longer than `maxAgeSeconds`.
    @discardableResult
    public func runOnce() async throws -> BlobPurgeResult {
        try await storage.purgeStaleBlobs(untouchedSince: now() - maxAgeSeconds)
    }

    /// Runs a pass now, then every `interval` until the task is cancelled. A failed pass is logged and retried at
    /// the next tick; it never stops the relay.
    public func run(every interval: Duration, logger: Logger) async {
        while !Task.isCancelled {
            do {
                let result = try await runOnce()
                if result.blobs > 0 {
                    logger.info("Purged stale blob uploads", metadata: [
                        "blobs": "\(result.blobs)", "bytes": "\(result.bytes)",
                    ])
                }
            } catch {
                logger.error("Stale blob purge failed", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: interval)
        }
    }
}
