import ClipWire
import Foundation
import Hummingbird

/// Server-side knobs. Defaults follow WireLimits.
public struct RelayConfig: Sendable {
    /// Pull page size cap (and the size used when the client sends no limit). Never above WireLimits.maxPullLimit.
    public var maxPullLimit: Int = 500
    public var maxWaitSeconds: Int = WireLimits.maxWaitSeconds
    public var pairingTTLSeconds: Int64 = 10 * 60
    public var maxPairingBlobBytes: Int = 64 * 1024
    public var maxIDLength: Int = 128
    /// Unix seconds. Injected so tests can move time forward.
    public var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    public init() {}
}

/// Request context with a body limit big enough for a full push (500 envelopes of 256 KiB, base64).
public struct RelayRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    public var maxUploadSize: Int { Self.maxRequestBodyBytes }

    /// base64 grows bytes by 4/3; allow 1 KiB of JSON per envelope for IDs and keys.
    public static let maxRequestBodyBytes =
        WireLimits.maxEnvelopesPerPush * ((WireLimits.maxCiphertextBytes + 2) / 3 * 4 + 1024) + 1024
}

/// Builds the relay's routes:
/// - `GET  /healthz`
/// - `POST /v1/ops`, `GET /v1/ops?after=&limit=&wait=` (bearer auth)
/// - `PUT  /v1/pairing/{id}`, `GET /v1/pairing/{id}` (no auth)
public func buildRelayRouter(
    storage: any RelayStorage,
    notifier: PushNotifier,
    config: RelayConfig = RelayConfig()
) -> Router<RelayRequestContext> {
    let router = Router(context: RelayRequestContext.self)
    let auth = TokenAuthenticator(storage: storage)
    let pullCap = max(1, min(config.maxPullLimit, WireLimits.maxPullLimit))
    let waitCap = max(0, min(config.maxWaitSeconds, WireLimits.maxWaitSeconds))

    router.get("healthz") { _, _ in "ok" }

    router.post("v1/ops") { request, context -> Response in
        try await auth.authorize(request)
        let push = try await request.decode(as: PushRequest.self, context: context)
        try validate(push, maxIDLength: config.maxIDLength)
        let result = try await storage.append(push.envelopes)
        if result.inserted > 0 { await notifier.notify() }
        return try jsonResponse(PushResponse(latestSeq: result.latestSeq))
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
            let remaining = deadline - ContinuousClock.now
            if !page.envelopes.isEmpty || remaining <= .zero || Task.isCancelled {
                return try jsonResponse(PullResponse(
                    envelopes: page.envelopes, latestSeq: page.latestSeq, hasMore: page.hasMore))
            }
            await notifier.wait(since: generation, timeout: remaining)
        }
    }

    router.put("v1/pairing/:id") { request, context -> Response in
        let id = try pairingID(context)
        let body = try await request.decode(as: PairingBlob.self, context: context)
        guard !body.blob.isEmpty else { throw HTTPError(.badRequest, message: "empty pairing blob") }
        guard body.blob.count <= config.maxPairingBlobBytes else { throw HTTPError(.contentTooLarge) }
        let now = config.now()
        try await storage.putPairing(id: id, blob: body.blob, expiresAt: now + config.pairingTTLSeconds, now: now)
        return Response(status: .noContent)
    }

    router.get("v1/pairing/:id") { _, context -> Response in
        let id = try pairingID(context)
        guard let blob = try await storage.takePairing(id: id, now: config.now()) else {
            throw HTTPError(.notFound)
        }
        return try jsonResponse(PairingBlob(blob: blob))
    }

    return router
}

// MARK: - Helpers

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
            guard !field.isEmpty, field.utf8.count <= maxIDLength else {
                throw HTTPError(.badRequest, message: "opID, itemID and deviceID must be 1...\(maxIDLength) bytes")
            }
        }
    }
}

/// Pairing IDs are exactly 32 lowercase hex characters (see design §3).
func isValidPairingID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
}

private func pairingID(_ context: RelayRequestContext) throws -> String {
    guard let id = context.parameters.get("id"), isValidPairingID(id) else {
        throw HTTPError(.badRequest, message: "pairing id must be 32 lowercase hex characters")
    }
    return id
}

private func queryInt<T: FixedWidthInteger & LosslessStringConvertible>(
    _ request: Request, _ name: String, default fallback: T
) throws -> T {
    guard let raw = request.uri.queryParameters.get(name) else { return fallback }
    guard let value = T(raw) else { throw HTTPError(.badRequest, message: "\(name) must be an integer") }
    return value
}

private func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
}
