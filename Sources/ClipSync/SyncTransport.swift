import ClipWire
import Foundation

/// How a device talks to the relay. `HTTPTransport` in production, `InMemoryRelay` in tests and the harness.
/// Semantics follow Server/Sources/RelayCore/RelayRouter.swift.
public protocol SyncTransport: Sendable {
    /// POST /v1/ops. The relay dedupes on opID, so retrying a push is safe.
    func push(_ request: PushRequest) async throws -> PushResponse
    /// GET /v1/ops. With `wait` > 0 and nothing new, holds up to `wait` seconds (long-poll).
    func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse
    /// PUT /v1/pairing/<id>. One blob per ID; a second put overwrites.
    func putPairing(id: String, blob: Data) async throws
    /// GET /v1/pairing/<id>. Returns the blob once, then it's gone; nil if missing or expired.
    func takePairing(id: String) async throws -> Data?
}

public enum TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 401/403: wrong or missing bearer token.
    case unauthorized
    case notFound
    /// 413: too many envelopes, a ciphertext over the cap, or a body over the cap.
    case payloadTooLarge
    /// Any other 4xx, with the server's message.
    case badRequest(String)
    /// 5xx or an unexpected status.
    case server(Int)
    /// The request never got a response (offline, timeout, connection reset).
    case network(String)
    /// The response body wasn't what the wire contract promises.
    case decoding

    public var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .notFound: "not found"
        case .payloadTooLarge: "payload too large"
        case .badRequest(let message): "bad request: \(message)"
        case .server(let status): "server error \(status)"
        case .network(let message): "network error: \(message)"
        case .decoding: "malformed response"
        }
    }
}
