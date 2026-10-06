import ClipCrypto
import ClipWire
import Foundation

/// The relay's behavior without HTTP, for tests and the harness. Mirrors RelayRouter: dedupe by opID,
/// server-assigned seq, paging with `hasMore`, long-poll that wakes on push, `cursorAhead` when a cursor is past
/// the log, an epoch on every push and pull response, one-time pairing blobs (no overwrite, at most `WireLimits.maxLivePairings`), and the same limits
/// (mapped to `TransportError` the way HTTPTransport maps status codes).
///
/// Auth is off until `pin(tokenSHA256:)` or a revoke sets a token hash; then only `client(token:)` views carrying
/// that token get through (the relay's own `SyncTransport` methods send no token). Device records, revocation and
/// handoffs (F13) follow the real relay too, and so do blob routes: a revoke wipes the blobs with the log.
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
    private var tokenHash: String?
    private var devices: [String: DeviceRecord] = [:]
    private var handoffs: [(deviceID: String, blob: Data)] = []
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

    /// F16: false makes every request fail with a network error, like a relay VM that's down. The log is kept.
    public func setReachable(_ value: Bool) { reachable = value }
    private var reachable = true

    /// Appends envelopes as-is, bypassing validation. For planting poisoned envelopes in tests.
    public func inject(_ envelopes: [Envelope]) { _ = append(envelopes) }

    /// Turns auth on: from now on only requests carrying a token with this SHA-256 get through.
    public func pin(tokenSHA256: String) { tokenHash = tokenSHA256.lowercased() }

    /// A transport that sends `token` with every request, like `HTTPTransport(baseURL:token:)`.
    public nonisolated func client(token: String?) -> InMemoryRelayClient {
        InMemoryRelayClient(relay: self, token: token)
    }

    public var deviceRecords: [DeviceRecord] { devices.values.sorted { $0.deviceID < $1.deviceID } }
    public var envelopes: [Envelope] { log }
    public var latestSeq: Int64 { log.last?.seq ?? 0 }

    // MARK: SyncTransport

    public func push(_ request: PushRequest) async throws -> PushResponse {
        try await push(request, token: nil)
    }

    public func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        try await pull(after: after, limit: limit, wait: wait, token: nil)
    }

    public func putPairing(id: String, blob: Data) async throws {
        try await putPairing(id: id, blob: blob, token: nil)
    }

    public func putDevice(_ record: DeviceRecord) async throws {
        try await putDevice(record, token: nil)
    }

    public func listDevices() async throws -> [DeviceRecord] {
        try await listDevices(token: nil)
    }

    public func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        try await revoke(request, token: nil)
    }

    public func handoffs(deviceID: String) async throws -> [Data] {
        handoffs.filter { $0.deviceID == deviceID }.map(\.blob)
    }

    // MARK: Requests with a token

    func push(_ request: PushRequest, token: String?) async throws -> PushResponse {
        try authorize(token)
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

    func pull(after: Int64, limit: Int, wait: Int, token: String?) async throws -> PullResponse {
        try authorize(token)
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
            try authorize(token)  // a revoke may have landed while this pull waited
        }
    }

    func putPairing(id: String, blob: Data, token: String?) async throws {
        try authorize(token)
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
        try await putBlobChunk(blobID: blobID, index: index, count: count, data: data, token: nil)
    }

    public func blobStatus(blobID: String) async throws -> BlobStatus? {
        try await blobStatus(blobID: blobID, token: nil)
    }

    public func blobChunk(blobID: String, index: Int) async throws -> Data? {
        try await blobChunk(blobID: blobID, index: index, token: nil)
    }

    public func deleteBlob(blobID: String) async throws {
        try await deleteBlob(blobID: blobID, token: nil)
    }

    // Blob routes with a token. Each call is one step on this actor, so the token check and the read or write are
    // atomic with a revoke, like the relay's re-check inside the storage call.

    func putBlobChunk(blobID: String, index: Int, count: Int, data: Data, token: String?) async throws {
        try authorize(token)
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

    func blobStatus(blobID: String, token: String?) async throws -> BlobStatus? {
        try authorize(token)
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        guard let blob = blobs[blobID] else { return nil }
        return BlobStatus(blobID: blobID, chunkCount: blob.count, received: blob.chunks.keys.sorted())
    }

    func blobChunk(blobID: String, index: Int, token: String?) async throws -> Data? {
        try authorize(token)
        if let remaining = blobGetsBeforeFailure {
            guard remaining > 0 else { throw TransportError.network("simulated dropped download") }
            blobGetsBeforeFailure = remaining - 1
        }
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        blobGetCount += 1
        return blobs[blobID]?.chunks[index]
    }

    func deleteBlob(blobID: String, token: String?) async throws {
        try authorize(token)
        guard WireLimits.isValidBlobID(blobID) else { throw TransportError.badRequest("blob id must be a UUID") }
        blobs[blobID] = nil
    }

    func putDevice(_ record: DeviceRecord, token: String?) async throws {
        try authorize(token)
        try validate(record)
        if let existing = devices[record.deviceID] {
            guard existing.publicKey == record.publicKey else { throw TransportError.conflict }
        } else {
            guard devices.count < WireLimits.maxDevices else { throw TransportError.rateLimited }
        }
        devices[record.deviceID] = record
    }

    func listDevices(token: String?) async throws -> [DeviceRecord] {
        try authorize(token)
        return deviceRecords
    }

    func revoke(_ request: RevokeRequest, token: String?) async throws -> RevokeResponse {
        try authorize(token)
        guard WireLimits.isValidSHA256Hex(request.newTokenSHA256) else {
            throw TransportError.badRequest("newTokenSHA256 must be 64 hex characters")
        }
        guard !request.devices.isEmpty, request.devices.count <= WireLimits.maxDevices else {
            throw TransportError.badRequest("1...\(WireLimits.maxDevices) devices")
        }
        var listed = Set<String>()
        for record in request.devices {
            try validate(record)
            guard listed.insert(record.deviceID).inserted else { throw TransportError.badRequest("listed twice") }
        }
        guard request.handoffs.count <= WireLimits.maxDevices else { throw TransportError.badRequest("too many handoffs") }
        if let expected = request.expectedDeviceIDs, Set(devices.keys) != Set(expected) {
            throw TransportError.conflict
        }
        for handoff in request.handoffs {
            guard listed.contains(handoff.deviceID), !handoff.blob.isEmpty,
                  handoff.blob.count <= WireLimits.maxHandoffBytes
            else { throw TransportError.badRequest("bad handoff") }
        }
        // One step, like the relay's transaction.
        tokenHash = request.newTokenSHA256.lowercased()
        epoch = UUID().uuidString.lowercased()
        log = []
        seenOpIDs = []
        pairings = [:]
        blobs = [:]  // sealed under the old vault key; remaining devices re-upload what they hold
        devices = Dictionary(uniqueKeysWithValues: request.devices.map { ($0.deviceID, $0) })
        handoffs = handoffs.filter { listed.contains($0.deviceID) }
            + request.handoffs.map { (deviceID: $0.deviceID, blob: $0.blob) }
        var kept: [String: Int] = [:]
        handoffs = handoffs.reversed().filter { entry in
            kept[entry.deviceID, default: 0] += 1
            return kept[entry.deviceID]! <= WireLimits.maxHandoffsPerDevice
        }.reversed()
        wakeAll()
        return RevokeResponse(epoch: epoch)
    }

    // MARK: Internals

    private func authorize(_ token: String?) throws {
        guard reachable else { throw TransportError.network("relay unreachable (simulated)") }
        guard let tokenHash else { return }
        guard let token, VaultKey.tokenSHA256(token) == tokenHash else { throw TransportError.unauthorized }
    }

    private func validate(_ record: DeviceRecord) throws {
        guard WireLimits.isValidID(record.deviceID), record.publicKey.count == WireLimits.devicePublicKeyBytes,
              !record.sealed.isEmpty, record.sealed.count <= WireLimits.maxSealedDeviceBytes
        else { throw TransportError.badRequest("invalid device record") }
    }

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

/// One device's view of an `InMemoryRelay`: every request carries `token`, like `HTTPTransport`.
public struct InMemoryRelayClient: SyncTransport, BlobTransport {
    public let relay: InMemoryRelay
    public let token: String?

    public func push(_ request: PushRequest) async throws -> PushResponse {
        try await relay.push(request, token: token)
    }

    public func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        try await relay.pull(after: after, limit: limit, wait: wait, token: token)
    }

    public func putPairing(id: String, blob: Data) async throws {
        try await relay.putPairing(id: id, blob: blob, token: token)
    }

    public func takePairing(id: String) async throws -> Data? {
        try await relay.takePairing(id: id)
    }

    public func putDevice(_ record: DeviceRecord) async throws {
        try await relay.putDevice(record, token: token)
    }

    public func listDevices() async throws -> [DeviceRecord] {
        try await relay.listDevices(token: token)
    }

    public func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        try await relay.revoke(request, token: token)
    }

    public func handoffs(deviceID: String) async throws -> [Data] {
        try await relay.handoffs(deviceID: deviceID)
    }

    public func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {
        try await relay.putBlobChunk(blobID: blobID, index: index, count: count, data: data, token: token)
    }

    public func blobStatus(blobID: String) async throws -> BlobStatus? {
        try await relay.blobStatus(blobID: blobID, token: token)
    }

    public func blobChunk(blobID: String, index: Int) async throws -> Data? {
        try await relay.blobChunk(blobID: blobID, index: index, token: token)
    }

    public func deleteBlob(blobID: String) async throws {
        try await relay.deleteBlob(blobID: blobID, token: token)
    }
}
