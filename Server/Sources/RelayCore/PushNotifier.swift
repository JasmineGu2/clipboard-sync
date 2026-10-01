/// Wakes long-polling pulls when a push lands.
///
/// Usage: read `generation`, query storage, and if nothing is new call `wait(since:timeout:)`
/// with the generation read *before* the query. A push that lands between the query and the wait
/// bumps the generation, so the wait returns at once instead of missing it.
///
/// Every continuation is resumed exactly once: by `notify()`, by the timeout, or by task
/// cancellation. None is left behind in `waiters`.
public actor PushNotifier {
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextID: UInt64 = 0
    /// Bumped on every notify.
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Number of suspended waiters (for tests and diagnostics).
    public var waiterCount: Int { waiters.count }

    /// Wakes every waiter.
    public func notify() {
        generation &+= 1
        let current = waiters
        waiters.removeAll()
        for continuation in current.values { continuation.resume() }
    }

    /// Suspends until `notify()` is called, `timeout` elapses, or the task is cancelled.
    /// Returns at once if a notify already happened after `observed` was read.
    public func wait(since observed: UInt64, timeout: Duration) async {
        guard observed == generation, timeout > .zero, !Task.isCancelled else { return }
        nextID &+= 1
        let id = nextID

        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            await self.resume(id)
        }
        // The continuation body runs synchronously on this actor, so the waiter is registered before
        // any resume(id) from the timer or the cancellation handler can run. If the task was already
        // cancelled we never register; a later resume(id) is a harmless no-op.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resume(id) }
        }
        timer.cancel()
    }

    private func resume(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
