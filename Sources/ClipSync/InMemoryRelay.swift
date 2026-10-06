import ClipWire
import Foundation

/// The relay's behavior without HTTP, for tests and the harness. Mirrors RelayRouter: dedupe by opID,
/// server-assigned seq, paging with `hasMore`, long-poll that wakes on push, `cursorAhead` when a cursor is past
/// the log, an epoch on every push and pull response, one-time pairing blobs (no overwrite, at most `WireLimits.maxLivePairings`), and the same limits
/// (mapped to `TransportError` the way HTTPTransport maps status codes). It has no token, so it doesn't model auth.
public actor InMemoryRelay: SyncTransport, BlobTransport {
    public let maxPullLimit: Int
    public let pairingTTL: TimeInterval
    private let now: @Sendable () -> Date

    /// Sent on every push and pull response, like the real relay's database epoch. Changed by `simulateReset()`.
    public private(set) var epoch: String
    /// False models a relay from before epochs existed: responses carry no epoch.
    public private(set) var sendsEpoch: Bool
    private var log: [Envelope] = []
    private var seenOpIDs: Set<String> = []
    private var pairings: [String: (blob: Data, expires: Date)] = [:]
    private var blobs: [String: (count: Int, chunks: [Int: Data])] = [:]
    private var blobPutsBeforeFailure: Int?
    private var blobGetsBeforeFailure: Int?
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
        now: @escaping @Sendable () -> Date = { Date() },
        epoch: String = UUID().uuidString.lowercased(),
        sendsEpoch: Bool = true
    ) {
        self.epoch = epoch
        self.sendsEpoch = sendsEpoch
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
    /// After `count` more successful chunk uploads, every upload fails (a dropped connection mid-transfer)
    /// until `healBlobTransfers()`.
    public func failBlobUploads(after count: Int) { blobPutsBeforeFailure = count }
    /// The same for chunk downloads.
    public func failBlobDownloads(after count: Int) { blobGetsBeforeFailure = count }
    public func healBlobTransfers() {
        blobPutsBeforeFailure = nil
        blobGetsBeforeFailure = nil
    }
    /// Chunk uploads and downloads that reached the relay, for resume checks.
    public private(set) var blobPutCount = 0
    public private(set) var blobGetCount = 0
    /// Replaces a stored chunk's bytes, to test tampering.
    public func tamperBlobChunk(blobID: String, index: Int, with data: Data) { blobs[blobID]?.chunks[index] = data }
    public var blobIDs: Set<String> { Set(blobs.keys) }

    /// The relay loses its log and starts over with a new epoch, as when its database is deleted or replaced.
    /// Pending pairings go too; a long-poll in progress sees the new state on its next wakeup.
    public func simulateReset(epoch: String = UUID().uuidString.lowercased()) {
        self.epoch = epoch
        log = []
        seenOpIDs = []
        pairings = [:]
        blobs = [:]
    }

    public func setSendsEpoch(_ value: Bool) { sendsEpoch = value }

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
        return PushResponse(latestSeq: latestSeq, epoch: sentEpoch)
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
            // A fresh relay (or one restored from an old backup) and a client that remembers more. Checked on
            // every wakeup, like RelayRouter, because a reset can land while a long-poll waits.
            guard after <= latestSeq else { throw TransportError.cursorAhead(latestSeq: latestSeq) }
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
        let current = now()
        pairings = pairings.filter { $0.value.expires > current }
        guard pairings[id] == nil else { throw TransportError.conflict }
        guard pairings.count < WireLimits.maxLivePairings else { throw TransportError.rateLimited }
        pairings[id] = (blob, current.addingTimeInterval(pairingTTL))
    }

    public func takePairing(id: String) async throws -> Data? {
        try validatePairingID(id)
        guard let entry = pairings.removeValue(forKey: id), entry.expires > now() else { return nil }
        return entry.blob
    }

    // MARK: BlobTransport (mirrors the relay's blob routes)

    public func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {
        if let remaining = blobPutsBeforeFailure {
            guard remaining > 0 else { throw TransportError.network("simulated dropped upload") }
            blobPutsBeforeFailure = remaining - 1
        }
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        guard (1...WireLimits.maxBlobChunks).contains(count), (0..<count).contains(index) else {
            throw TransportError.badRequest("bad index or count")
        }
        guard data.count <= WireLimits.maxBlobChunkBodyBytes else { throw TransportError.payloadTooLarge }
        guard data.count >= WireLimits.blobChunkOverheadBytes else { throw TransportError.badRequest("chunk too short") }
        var blob = blobs[blobID] ?? (count, [:])
        guard blob.count == count else { throw TransportError.conflict }
        blobPutCount += 1
        if blob.chunks[index] == nil { blob.chunks[index] = data }
        blobs[blobID] = blob
    }

    public func blobStatus(blobID: String) async throws -> BlobStatus? {
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        guard let blob = blobs[blobID] else { return nil }
        return BlobStatus(blobID: blobID, chunkCount: blob.count, received: blob.chunks.keys.sorted())
    }

    public func blobChunk(blobID: String, index: Int) async throws -> Data? {
        if let remaining = blobGetsBeforeFailure {
            guard remaining > 0 else { throw TransportError.network("simulated dropped download") }
            blobGetsBeforeFailure = remaining - 1
        }
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        blobGetCount += 1
        return blobs[blobID]?.chunks[index]
    }

    public func deleteBlob(blobID: String) async throws {
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        blobs[blobID] = nil
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
        return PullResponse(
            envelopes: Array(log[start..<end]), latestSeq: latestSeq, hasMore: end < log.count, epoch: sentEpoch)
    }

    private var sentEpoch: String? { sendsEpoch ? epoch : nil }

    private func validate(_ request: PushRequest) throws {
        guard request.envelopes.count <= WireLimits.maxEnvelopesPerPush else { throw TransportError.payloadTooLarge }
        for envelope in request.envelopes {
            guard envelope.ciphertext.count <= WireLimits.maxCiphertextBytes else { throw TransportError.payloadTooLarge }
            guard !envelope.ciphertext.isEmpty else { throw TransportError.badRequest("empty ciphertext") }
            for field in [envelope.opID, envelope.itemID, envelope.deviceID] where !WireLimits.isValidID(field) {
                throw TransportError.badRequest(
                    "opID, itemID and deviceID must be 1...\(WireLimits.maxIDBytes) bytes with no control characters")
            }
        }
        // Same cap the real relay enforces on the raw body.
        let bodyBytes = (try? JSONEncoder().encode(request).count) ?? 0
        guard bodyBytes <= WireLimits.maxPushBodyBytes else { throw TransportError.payloadTooLarge }
    }

    private func validatePairingID(_ id: String) throws {
        guard WireLimits.isValidPairingID(id) else {
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
