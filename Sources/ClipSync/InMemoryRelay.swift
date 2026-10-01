import ClipWire
import Foundation

/// The relay's behavior without HTTP, for tests and the harness. Mirrors RelayRouter: dedupe by opID,
/// server-assigned seq, paging with `hasMore`, long-poll that wakes on push, one-time pairing blobs,
/// and the same limits (mapped to `TransportError` the way HTTPTransport maps status codes).
public actor InMemoryRelay: SyncTransport {
    public let maxPullLimit: Int
    public let pairingTTL: TimeInterval
    private let now: @Sendable () -> Date

    private var log: [Envelope] = []
    private var seenOpIDs: Set<String> = []
    private var pairings: [String: (blob: Data, expires: Date)] = [:]
    private var waiters: [UUID: (continuation: CheckedContinuation<Void, Never>, timeout: Task<Void, Never>)] = [:]

    // Fault knobs.
    private var pushFailures = 0
    private var lostPushResponses = 0
    private var pullFailures = 0

    /// Successful push calls (whatever their size). Lets tests check batching.
    public private(set) var pushCount = 0
    /// Envelope counts of each accepted push, in order.
    public private(set) var pushSizes: [Int] = []

    public init(
        maxPullLimit: Int = WireLimits.defaultPullLimit,
        pairingTTL: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxPullLimit = max(1, min(maxPullLimit, WireLimits.maxPullLimit))
        self.pairingTTL = pairingTTL
        self.now = now
    }

    // MARK: Fault knobs

    /// The next `count` pushes fail before reaching the log.
    public func failNextPushes(_ count: Int) { pushFailures = count }
    /// The next `count` pushes are stored, then the response is lost (the caller sees a network error).
    public func loseNextPushResponses(_ count: Int) { lostPushResponses = count }
    public func failNextPulls(_ count: Int) { pullFailures = count }

    /// Appends envelopes as-is, bypassing validation. For planting poisoned envelopes in tests.
    public func inject(_ envelopes: [Envelope]) { _ = append(envelopes) }

    public var envelopes: [Envelope] { log }
    public var latestSeq: Int64 { log.last?.seq ?? 0 }

    // MARK: SyncTransport

    public func push(_ request: PushRequest) async throws -> PushResponse {
        if pushFailures > 0 {
            pushFailures -= 1
            throw TransportError.network("simulated push failure")
        }
        try validate(request)
        let inserted = append(request.envelopes)
        pushCount += 1
        pushSizes.append(request.envelopes.count)
        if inserted > 0 { wakeAll() }
        if lostPushResponses > 0 {
            lostPushResponses -= 1
            throw TransportError.network("simulated lost response")
        }
        return PushResponse(latestSeq: latestSeq)
    }

    public func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        if pullFailures > 0 {
            pullFailures -= 1
            throw TransportError.network("simulated pull failure")
        }
        guard after >= 0, limit >= 0, wait >= 0 else {
            throw TransportError.badRequest("after, limit and wait must not be negative")
        }
        let pageSize = max(1, min(limit, maxPullLimit))
        let deadline = ContinuousClock.now + .seconds(min(wait, WireLimits.maxWaitSeconds))
        while true {
            let page = page(after: after, limit: pageSize)
            let remaining = deadline - ContinuousClock.now
            if !page.envelopes.isEmpty || remaining <= .zero || Task.isCancelled {
                return page
            }
            await waitForPush(timeout: remaining)
        }
    }

    public func putPairing(id: String, blob: Data) async throws {
        try validatePairingID(id)
        guard !blob.isEmpty else { throw TransportError.badRequest("empty pairing blob") }
        guard blob.count <= WireLimits.maxPairingBlobBytes else { throw TransportError.payloadTooLarge }
        pairings[id] = (blob, now().addingTimeInterval(pairingTTL))
    }

    public func takePairing(id: String) async throws -> Data? {
        try validatePairingID(id)
        guard let entry = pairings.removeValue(forKey: id), entry.expires > now() else { return nil }
        return entry.blob
    }

    // MARK: Internals

    private func append(_ envelopes: [Envelope]) -> Int {
        var inserted = 0
        for var envelope in envelopes where seenOpIDs.insert(envelope.opID).inserted {
            envelope.seq = latestSeq + 1
            log.append(envelope)
            inserted += 1
        }
        return inserted
    }

    private func page(after: Int64, limit: Int) -> PullResponse {
        // seq == index + 1, so the page starts at index `after`.
        let start = Int(min(after, Int64(log.count)))
        let end = min(start + limit, log.count)
        return PullResponse(envelopes: Array(log[start..<end]), latestSeq: latestSeq, hasMore: end < log.count)
    }

    private func validate(_ request: PushRequest) throws {
        guard request.envelopes.count <= WireLimits.maxEnvelopesPerPush else { throw TransportError.payloadTooLarge }
        for envelope in request.envelopes {
            guard envelope.ciphertext.count <= WireLimits.maxCiphertextBytes else { throw TransportError.payloadTooLarge }
            guard !envelope.ciphertext.isEmpty else { throw TransportError.badRequest("empty ciphertext") }
            for field in [envelope.opID, envelope.itemID, envelope.deviceID] {
                guard !field.isEmpty, field.utf8.count <= WireLimits.maxIDBytes else {
                    throw TransportError.badRequest("opID, itemID and deviceID must be 1...\(WireLimits.maxIDBytes) bytes")
                }
            }
        }
        // The real relay's body cap is larger; enforcing the client-side cap here catches batching bugs.
        let bodyBytes = (try? JSONEncoder().encode(request).count) ?? 0
        guard bodyBytes <= WireLimits.maxPushBodyBytes else { throw TransportError.payloadTooLarge }
    }

    private func validatePairingID(_ id: String) throws {
        let isHex = id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        guard id.utf8.count == 32, isHex else {
            throw TransportError.badRequest("pairing id must be 32 lowercase hex characters")
        }
    }

    /// Suspends until a push, the timeout, or cancellation, whichever comes first.
    private func waitForPush(timeout: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Checked on the actor, so a cancel that landed before this point isn't lost.
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.wake(id)
                }
                waiters[id] = (continuation, timer)
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    private func wakeAll() {
        for id in Array(waiters.keys) { wake(id) }
    }
}
