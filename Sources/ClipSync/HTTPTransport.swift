import ClipStore
import ClipWire
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds the relay's HTTP requests and reads its status codes. Pure, so it's unit-tested without a network.
public struct RelayRequestBuilder: Sendable {
    public let baseURL: URL
    public let token: String?
    /// Extra seconds on top of the long-poll wait, so the client never times out before the server answers.
    public static let longPollGrace: TimeInterval = 10
    /// For every request that the relay answers at once: push, pairing, and pulls with wait=0. Short, so an
    /// unreachable relay (offline, or Tailscale down) shows as offline in seconds rather than after 30.
    public static let shortTimeout: TimeInterval = 5

    /// The request timeout for a pull: short for wait=0, the wait plus `longPollGrace` for a long-poll.
    public static func pullTimeout(wait: Int) -> TimeInterval {
        wait > 0 ? TimeInterval(wait) + longPollGrace : shortTimeout
    }

    public init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    public func push(_ body: PushRequest) throws -> URLRequest {
        var request = URLRequest(url: url("v1/ops"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    public func pull(after: Int64, limit: Int, wait: Int) -> URLRequest {
        let query = [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "wait", value: String(wait)),
        ]
        var request = URLRequest(url: url("v1/ops", query: query))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.pullTimeout(wait: wait)
        authorize(&request)
        return request
    }

    /// Sent by the existing device, which has the token; the relay refuses an unauthenticated PUT.
    public func putPairing(id: String, blob: Data) throws -> URLRequest {
        var request = URLRequest(url: url("v1/pairing/\(id)"))
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(PairingBlob(blob: blob))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    /// Sent by the new device, which has no token yet: the 128-bit pairing ID is the capability.
    public func takePairing(id: String) -> URLRequest {
        var request = URLRequest(url: url("v1/pairing/\(id)"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.shortTimeout
        return request
    }

    /// For blob chunk uploads and downloads: up to 1 MiB each way, so longer than `shortTimeout` for slow links.
    /// Not above the session's ceiling (`HTTPTransport`), which some platforms apply instead.
    public static let blobChunkTimeout: TimeInterval = TimeInterval(WireLimits.maxWaitSeconds) + longPollGrace

    public func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) -> URLRequest {
        var request = URLRequest(url: url(
            "v1/blobs/\(blobID)/chunks/\(index)", query: [URLQueryItem(name: "count", value: String(count))]))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.blobChunkTimeout
        authorize(&request)
        return request
    }

    public func blobStatus(blobID: String) -> URLRequest {
        var request = URLRequest(url: url("v1/blobs/\(blobID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    public func blobChunk(blobID: String, index: Int) -> URLRequest {
        var request = URLRequest(url: url("v1/blobs/\(blobID)/chunks/\(index)"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.blobChunkTimeout
        authorize(&request)
        return request
    }

    public func deleteBlob(blobID: String) -> URLRequest {
        var request = URLRequest(url: url("v1/blobs/\(blobID)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    /// Maps a pull response's status: 409 carries `CursorAheadResponse` and becomes `.cursorAhead`.
    public static func checkPull(status: Int, body: Data) throws {
        if status == 409 {
            guard let ahead = try? JSONDecoder().decode(CursorAheadResponse.self, from: body) else {
                throw TransportError.decoding
            }
            throw TransportError.cursorAhead(latestSeq: ahead.latestSeq)
        }
        try check(status: status, body: body)
    }

    /// Maps a non-2xx status to the matching error; returns for 2xx.
    public static func check(status: Int, body: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw TransportError.unauthorized
        case 404: throw TransportError.notFound
        case 409: throw TransportError.conflict
        case 413: throw TransportError.payloadTooLarge
        case 429: throw TransportError.rateLimited
        case 400..<500: throw TransportError.badRequest(String(decoding: body.prefix(512), as: UTF8.self))
        default: throw TransportError.server(status)
        }
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let joined = baseURL.appendingPathComponent(path)
        guard !query.isEmpty, var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else {
            return joined
        }
        components.queryItems = query
        return components.url ?? joined
    }

    private func authorize(_ request: inout URLRequest) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: WireHeaders.authorization)
        }
    }
}

/// Talks to the real relay over HTTP (tailnet only, see docs/design.md §1).
public struct HTTPTransport: SyncTransport {
    public let builder: RelayRequestBuilder
    private let session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession? = nil) {
        self.builder = RelayRequestBuilder(baseURL: baseURL, token: token)
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            // Every request sets its own timeout (short, or a long-poll's wait plus grace). The session value is
            // only a ceiling at the longest long-poll: on Windows the per-request value wins either way (measured),
            // and a 5 s session value could cut long-polls short on platforms that use the smaller of the two.
            configuration.timeoutIntervalForRequest =
                TimeInterval(WireLimits.maxWaitSeconds) + RelayRequestBuilder.longPollGrace
            return URLSession(configuration: configuration)
        }()
    }

    public func push(_ request: PushRequest) async throws -> PushResponse {
        let (data, status) = try await send(builder.push(request))
        try RelayRequestBuilder.check(status: status, body: data)
        return try decode(PushResponse.self, data)
    }

    public func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        let (data, status) = try await send(builder.pull(after: after, limit: limit, wait: wait))
        try RelayRequestBuilder.checkPull(status: status, body: data)
        return try decode(PullResponse.self, data)
    }

    public func putPairing(id: String, blob: Data) async throws {
        let (data, status) = try await send(builder.putPairing(id: id, blob: blob))
        try RelayRequestBuilder.check(status: status, body: data)
    }

    public func takePairing(id: String) async throws -> Data? {
        let (data, status) = try await send(builder.takePairing(id: id))
        if status == 404 { return nil }
        try RelayRequestBuilder.check(status: status, body: data)
        return try decode(PairingBlob.self, data).blob
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TransportError.decoding
        }
    }

    /// A data task wrapped by hand: FoundationNetworking's async API varies by version,
    /// and run() relies on cancellation to cut a long-poll short.
    fileprivate func send(_ request: URLRequest) async throws -> (Data, Int) {
        let box = DataTaskBox()
        let result: (Data, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), Error>) in
                // A pool around starting the task: bridging a 1 MiB body to NSURLRequest autoreleases a copy, and
                // a transfer's async context doesn't drain its pool between chunks (N6, see BlobCache.readChunk).
                withAutoreleasePool {
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: TransportError.network(error.localizedDescription))
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http.statusCode))
                    } else {
                        continuation.resume(throwing: TransportError.decoding)
                    }
                }
                box.start(task)
                }
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

extension HTTPTransport: BlobTransport {
    public func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {
        let (body, status) = try await send(builder.putBlobChunk(blobID: blobID, index: index, count: count, data: data))
        try RelayRequestBuilder.check(status: status, body: body)
    }

    public func blobStatus(blobID: String) async throws -> BlobStatus? {
        let (data, status) = try await send(builder.blobStatus(blobID: blobID))
        if status == 404 { return nil }
        try RelayRequestBuilder.check(status: status, body: data)
        do {
            return try JSONDecoder().decode(BlobStatus.self, from: data)
        } catch {
            throw TransportError.decoding
        }
    }

    public func blobChunk(blobID: String, index: Int) async throws -> Data? {
        let (data, status) = try await send(builder.blobChunk(blobID: blobID, index: index))
        if status == 404 { return nil }
        try RelayRequestBuilder.check(status: status, body: data)
        return data
    }

    public func deleteBlob(blobID: String) async throws {
        let (data, status) = try await send(builder.deleteBlob(blobID: blobID))
        try RelayRequestBuilder.check(status: status, body: data)
    }
}

/// Holds a data task so a cancellation that races its creation still cancels it.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
