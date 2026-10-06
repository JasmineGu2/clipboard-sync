import ClipWire
import Foundation
import Hummingbird

/// Server-side knobs. Defaults follow WireLimits.
public struct RelayConfig: Sendable {
    /// Pull page size cap (and the size used when the client sends no limit). Never above WireLimits.maxPullLimit.
    public var maxPullLimit: Int = 500
    public var maxWaitSeconds: Int = WireLimits.maxWaitSeconds
    public var pairingTTLSeconds: Int64 = 10 * 60
    public var maxPairingBlobBytes: Int = WireLimits.maxPairingBlobBytes
    /// Most unexpired pairing blobs held at once (429 beyond it).
    public var maxLivePairings: Int = WireLimits.maxLivePairings
    public var maxIDLength: Int = WireLimits.maxIDBytes
    /// Cap on all stored blob chunks together; a chunk that would pass it gets 507.
    public var maxBlobStorageBytes: Int64 = 20 * 1024 * 1024 * 1024
    public var maxDevices: Int = WireLimits.maxDevices
    public var maxHandoffsPerDevice: Int = WireLimits.maxHandoffsPerDevice
    /// Operator-pinned SHA-256 of the bearer token (64 hex chars). Setting it turns off trust on first use.
    public var authTokenSHA256: String?
    /// Unix seconds. Injected so tests can move time forward.
    public var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    public init() {}
}

/// Request context. `maxUploadSize` is the largest body any route accepts (a full push); each route also
/// reads its body through `collectBody` with its own cap before decoding.
public struct RelayRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    public var maxUploadSize: Int { WireLimits.maxPushBodyBytes }
}

/// Body caps per route, enforced while reading the body and before any JSON decoding.
public enum RelayBodyLimits {
    public static let push = WireLimits.maxPushBodyBytes
    public static let pairing = WireLimits.maxPairingBodyBytes
    /// `{"newTokenSHA256":"<64 hex>"}` is under 100 bytes.
    public static let rotate = 1024
    /// One sealed chunk, raw bytes.
    public static let blobChunk = WireLimits.maxBlobChunkBodyBytes
    public static let device = WireLimits.maxDeviceBodyBytes
    public static let revoke = WireLimits.maxRevokeBodyBytes
}

/// Builds the relay's routes:
/// - `GET  /healthz`
/// - `POST /v1/ops`, `GET /v1/ops?after=&limit=&wait=` (bearer auth)
/// - `PUT  /v1/pairing/{id}` (bearer auth), `GET /v1/pairing/{id}` (no auth: the new device has no token yet)
/// - `POST /v1/auth/rotate` (bearer auth with the current token)
/// - `PUT|GET /v1/blobs/{id}/chunks/{index}`, `GET|DELETE /v1/blobs/{id}` (bearer auth; see ClipWire)
/// - `PUT /v1/devices/{id}`, `GET /v1/devices` (bearer auth), `POST /v1/auth/revoke` (bearer auth with the current
///   token), `GET /v1/rekey/{id}` (no auth: a remaining device's old token stopped working). F13, design §3.
public func buildRelayRouter(
    storage: any RelayStorage,
    notifier: PushNotifier,
    config: RelayConfig = RelayConfig()
) -> Router<RelayRequestContext> {
    let router = Router(context: RelayRequestContext.self)
    let auth = TokenAuthenticator(storage: storage, pinnedHash: config.authTokenSHA256)
    let pullCap = max(1, min(config.maxPullLimit, WireLimits.maxPullLimit))
    let waitCap = max(0, min(config.maxWaitSeconds, WireLimits.maxWaitSeconds))

    router.get("healthz") { _, _ in "ok" }

    router.post("v1/ops") { request, _ -> Response in
        let tokenHash = try await auth.authorize(request)
        let push = try await decodeBody(PushRequest.self, request, limit: RelayBodyLimits.push)
        try validate(push, maxIDLength: config.maxIDLength)
        let result: AppendResult
        do {
            // Re-checked inside the write's transaction: a revoke may have landed since the check above.
            result = try await storage.append(push.envelopes, requiringTokenHash: tokenHash)
        } catch is AuthChanged {
            throw HTTPError(.unauthorized)
        }
        if result.inserted > 0 { await notifier.notify() }
        return try jsonResponse(PushResponse(latestSeq: result.latestSeq, epoch: try await storage.epoch()))
    }

    router.get("v1/ops") { request, _ -> Response in
        try await auth.authorize(request)
        let after = try queryInt(request, "after", default: Int64(0))
        let limit = try queryInt(request, "limit", default: pullCap)
        let wait = try queryInt(request, "wait", default: 0)
        guard after >= 0, limit >= 0, wait >= 0 else {
            throw HTTPError(.badRequest, message: "after, limit and wait must not be negative")
        }
        let pageSize = max(1, min(limit, pullCap))
        let deadline = ContinuousClock.now + .seconds(min(wait, waitCap))

        while true {
            // Read the generation before querying, so a push between the query and the wait isn't missed.
            let generation = await notifier.generation
            let page = try await storage.page(after: after, limit: pageSize)
            // The client's cursor is past the end of our log, so we lost data (reset or restored backup).
            // Say so instead of long-polling for seqs that will be reused by different ops.
            if after > page.latestSeq {
                return try jsonResponse(CursorAheadResponse(latestSeq: page.latestSeq), status: .conflict)
            }
            let remaining = deadline - ContinuousClock.now
            if !page.envelopes.isEmpty || remaining <= .zero || Task.isCancelled {
                // A revoke may have landed since the first check; don't hand a revoked token the new log.
                try await auth.authorize(request)
                return try jsonResponse(PullResponse(
                    envelopes: page.envelopes, latestSeq: page.latestSeq, hasMore: page.hasMore,
                    epoch: try await storage.epoch()))
            }
            await notifier.wait(since: generation, timeout: remaining)
            // A revoke may have landed while this request waited; a revoked token must not see what comes next.
            try await auth.authorize(request)
        }
    }

    router.put("v1/pairing/:id") { request, context -> Response in
        // Only a device already in the vault parks a key, so a stranger on the tailnet can't fill the table.
        try await auth.authorize(request)
        let id = try pairingID(context)
        let body = try await decodeBody(PairingBlob.self, request, limit: RelayBodyLimits.pairing)
        guard !body.blob.isEmpty else { throw HTTPError(.badRequest, message: "empty pairing blob") }
        guard body.blob.count <= config.maxPairingBlobBytes else { throw HTTPError(.contentTooLarge) }
        let now = config.now()
        let result = try await storage.putPairing(
            id: id, blob: body.blob, expiresAt: now + config.pairingTTLSeconds, now: now,
            maxLive: config.maxLivePairings)
        switch result {
        case .stored: return Response(status: .noContent)
        case .idTaken: throw HTTPError(.conflict, message: "pairing id already in use")
        case .full: throw HTTPError(.tooManyRequests, message: "too many pending pairings; try again later")
        }
    }

    router.get("v1/pairing/:id") { _, context -> Response in
        let id = try pairingID(context)
        guard let blob = try await storage.takePairing(id: id, now: config.now()) else {
            throw HTTPError(.notFound)
        }
        return try jsonResponse(PairingBlob(blob: blob))
    }

    router.post("v1/auth/rotate") { request, _ -> Response in
        try await auth.authorize(request)
        let body = try await decodeBody(RotateTokenRequest.self, request, limit: RelayBodyLimits.rotate)
        guard WireLimits.isValidSHA256Hex(body.newTokenSHA256) else {
            throw HTTPError(.badRequest, message: "newTokenSHA256 must be 64 hex characters")
        }
        try await auth.rotate(to: body.newTokenSHA256)
        return Response(status: .noContent)
    }

    // MARK: Blobs (F11, F12). The relay stores sealed chunks as sent and never learns which item they belong to.

    router.put("v1/blobs/:id/chunks/:index") { request, context -> Response in
        try await auth.authorize(request)
        let id = try blobID(context)
        let index = try chunkIndex(context)
        guard let raw = request.uri.queryParameters.get("count"), let count = Int(raw),
              (1...WireLimits.maxBlobChunks).contains(count)
        else {
            throw HTTPError(.badRequest, message: "count must be 1...\(WireLimits.maxBlobChunks)")
        }
        guard index < count else { throw HTTPError(.badRequest, message: "index must be below count") }
        let body = try await collectBody(request, limit: RelayBodyLimits.blobChunk)
        guard body.readableBytes >= WireLimits.blobChunkOverheadBytes else {
            throw HTTPError(.badRequest, message: "a chunk is at least \(WireLimits.blobChunkOverheadBytes) bytes")
        }
        let result = try await storage.putBlobChunk(
            blobID: id, index: index, count: count, data: Data(body.readableBytesView), now: config.now(),
            maxTotalBytes: config.maxBlobStorageBytes)
        switch result {
        case .stored, .alreadyStored: return Response(status: .noContent)
        case .countMismatch(let existing):
            throw HTTPError(.conflict, message: "blob already has \(existing) chunks")
        case .full: throw HTTPError(.init(code: 507, reasonPhrase: "Insufficient Storage"), message: "the relay's blob storage is full")
        }
    }

    router.get("v1/blobs/:id") { request, context -> Response in
        try await auth.authorize(request)
        let id = try blobID(context)
        guard let status = try await storage.blobStatus(blobID: id) else { throw HTTPError(.notFound) }
        return try jsonResponse(BlobStatus(blobID: id, chunkCount: status.chunkCount, received: status.received))
    }

    router.get("v1/blobs/:id/chunks/:index") { request, context -> Response in
        try await auth.authorize(request)
        let id = try blobID(context)
        let index = try chunkIndex(context)
        guard let data = try await storage.blobChunk(blobID: id, index: index) else { throw HTTPError(.notFound) }
        return Response(
            status: .ok,
            headers: [.contentType: "application/octet-stream"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    router.delete("v1/blobs/:id") { request, context -> Response in
        try await auth.authorize(request)
        try await storage.deleteBlob(blobID: try blobID(context))
        return Response(status: .noContent)
    }

    // MARK: Devices and revoke (F13).

    router.put("v1/devices/:id") { request, context -> Response in
        try await auth.authorize(request)
        let id = try deviceID(context, maxLength: config.maxIDLength)
        let record = try await decodeBody(DeviceRecord.self, request, limit: RelayBodyLimits.device)
        guard record.deviceID == id else { throw HTTPError(.badRequest, message: "deviceID must match the path") }
        try validate(record, maxIDLength: config.maxIDLength)
        switch try await storage.putDevice(record, maxDevices: config.maxDevices) {
        case .stored: return Response(status: .noContent)
        case .keyMismatch: throw HTTPError(.conflict, message: "this device ID is registered with another key")
        case .full: throw HTTPError(.tooManyRequests, message: "too many devices")
        }
    }

    router.get("v1/devices") { request, _ -> Response in
        try await auth.authorize(request)
        return try jsonResponse(DeviceListResponse(devices: try await storage.devices()))
    }

    router.post("v1/auth/revoke") { request, _ -> Response in
        try await auth.authorize(request)
        let body = try await decodeBody(RevokeRequest.self, request, limit: RelayBodyLimits.revoke)
        guard WireLimits.isValidSHA256Hex(body.newTokenSHA256) else {
            throw HTTPError(.badRequest, message: "newTokenSHA256 must be 64 hex characters")
        }
        guard !body.devices.isEmpty, body.devices.count <= config.maxDevices,
              body.handoffs.count <= config.maxDevices
        else {
            throw HTTPError(.badRequest, message: "1...\(config.maxDevices) devices and at most as many handoffs")
        }
        var listed = Set<String>()
        for record in body.devices {
            try validate(record, maxIDLength: config.maxIDLength)
            guard listed.insert(record.deviceID).inserted else {
                throw HTTPError(.badRequest, message: "a device is listed twice")
            }
        }
        for handoff in body.handoffs {
            guard listed.contains(handoff.deviceID) else {
                throw HTTPError(.badRequest, message: "every handoff must be for a listed device")
            }
            guard !handoff.blob.isEmpty, handoff.blob.count <= WireLimits.maxHandoffBytes else {
                throw HTTPError(.badRequest, message: "handoff blobs must be 1...\(WireLimits.maxHandoffBytes) bytes")
            }
        }
        let epoch: String
        do {
            epoch = try await auth.revoke(
                newHash: body.newTokenSHA256, devices: body.devices, handoffs: body.handoffs,
                maxHandoffsPerDevice: config.maxHandoffsPerDevice, expectedDeviceIDs: body.expectedDeviceIDs)
        } catch is DeviceListChanged {
            throw HTTPError(.conflict, message: "the device list changed; read it again")
        }
        // Wake long-polls: they re-check the token, so the revoked device's waiting pull ends in 401.
        await notifier.notify()
        return try jsonResponse(RevokeResponse(epoch: epoch))
    }

    router.get("v1/rekey/:id") { _, context -> Response in
        let id = try deviceID(context, maxLength: config.maxIDLength)
        return try jsonResponse(HandoffsResponse(handoffs: try await storage.handoffs(deviceID: id)))
    }

    return router
}

// MARK: - Helpers

/// Blob IDs are canonical UUID strings, compared as sent (clients send upper case).
private func blobID(_ context: RelayRequestContext) throws -> String {
    guard let id = context.parameters.get("id"), WireLimits.isValidBlobID(id) else {
        throw HTTPError(.badRequest, message: "blob id must be a UUID")
    }
    return id
}

private func chunkIndex(_ context: RelayRequestContext) throws -> Int {
    guard let raw = context.parameters.get("index"), let index = Int(raw), index >= 0,
          index < WireLimits.maxBlobChunks
    else {
        throw HTTPError(.badRequest, message: "chunk index must be 0...\(WireLimits.maxBlobChunks - 1)")
    }
    return index
}

func validate(_ push: PushRequest, maxIDLength: Int) throws {
    guard push.envelopes.count <= WireLimits.maxEnvelopesPerPush else {
        throw HTTPError(.contentTooLarge, message: "at most \(WireLimits.maxEnvelopesPerPush) envelopes per push")
    }
    for envelope in push.envelopes {
        guard envelope.ciphertext.count <= WireLimits.maxCiphertextBytes else {
            throw HTTPError(.contentTooLarge, message: "ciphertext over \(WireLimits.maxCiphertextBytes) bytes")
        }
        guard !envelope.ciphertext.isEmpty else {
            throw HTTPError(.badRequest, message: "empty ciphertext")
        }
        for field in [envelope.opID, envelope.itemID, envelope.deviceID] {
            guard WireLimits.isValidID(field), field.utf8.count <= maxIDLength else {
                throw HTTPError(
                    .badRequest,
                    message: "opID, itemID and deviceID must be 1...\(maxIDLength) bytes with no control characters")
            }
        }
    }
}

func validate(_ record: DeviceRecord, maxIDLength: Int) throws {
    guard WireLimits.isValidID(record.deviceID), record.deviceID.utf8.count <= maxIDLength else {
        throw HTTPError(.badRequest, message: "deviceID must be 1...\(maxIDLength) bytes with no control characters")
    }
    guard record.publicKey.count == WireLimits.devicePublicKeyBytes else {
        throw HTTPError(.badRequest, message: "publicKey must be \(WireLimits.devicePublicKeyBytes) bytes")
    }
    guard !record.sealed.isEmpty, record.sealed.count <= WireLimits.maxSealedDeviceBytes else {
        throw HTTPError(.badRequest, message: "sealed must be 1...\(WireLimits.maxSealedDeviceBytes) bytes")
    }
}

private func deviceID(_ context: RelayRequestContext, maxLength: Int) throws -> String {
    guard let id = context.parameters.get("id"), WireLimits.isValidID(id), id.utf8.count <= maxLength else {
        throw HTTPError(.badRequest, message: "device id must be 1...\(maxLength) bytes with no control characters")
    }
    return id
}

private func pairingID(_ context: RelayRequestContext) throws -> String {
    guard let id = context.parameters.get("id"), WireLimits.isValidPairingID(id) else {
        throw HTTPError(.badRequest, message: "pairing id must be 32 lowercase hex characters")
    }
    return id
}

/// Reads the body, refusing with 413 as soon as it passes `limit` bytes. A declared Content-Length over the
/// limit is refused before reading anything. Nothing is decoded until the whole body is known to fit.
func collectBody(_ request: Request, limit: Int) async throws -> ByteBuffer {
    if let declared = request.headers[.contentLength].flatMap({ Int($0) }), declared > limit {
        throw HTTPError(.contentTooLarge, message: "body over \(limit) bytes")
    }
    var collected = ByteBuffer()
    for try await chunk in request.body {
        guard chunk.readableBytes <= limit - collected.readableBytes else {
            throw HTTPError(.contentTooLarge, message: "body over \(limit) bytes")
        }
        var chunk = chunk
        collected.writeBuffer(&chunk)
    }
    return collected
}

/// `collectBody`, then JSON-decodes it. Malformed JSON is a 400.
private func decodeBody<T: Decodable>(_ type: T.Type, _ request: Request, limit: Int) async throws -> T {
    let body = try await collectBody(request, limit: limit)
    do {
        return try JSONDecoder().decode(T.self, from: Data(body.readableBytesView))
    } catch {
        throw HTTPError(.badRequest, message: "malformed JSON body")
    }
}

private func queryInt<T: FixedWidthInteger & LosslessStringConvertible>(
    _ request: Request, _ name: String, default fallback: T
) throws -> T {
    guard let raw = request.uri.queryParameters.get(name) else { return fallback }
    guard let value = T(raw) else { throw HTTPError(.badRequest, message: "\(name) must be an integer") }
    return value
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
}
