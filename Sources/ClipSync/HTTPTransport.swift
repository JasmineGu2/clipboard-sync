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

    public func putDevice(_ record: DeviceRecord) throws -> URLRequest {
        var request = URLRequest(url: url("v1/devices/\(record.deviceID)"))
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(record)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    public func listDevices() -> URLRequest {
        var request = URLRequest(url: url("v1/devices"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    public func revoke(_ body: RevokeRequest) throws -> URLRequest {
        var request = URLRequest(url: url("v1/auth/revoke"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.shortTimeout
        authorize(&request)
        return request
    }

    /// No token: the device asking has just been told its token no longer works.
    public func handoffs(deviceID: String) -> URLRequest {
        var request = URLRequest(url: url("v1/rekey/\(deviceID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.shortTimeout
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
    /// For responses read with a size cap (blob chunks): a session whose delegate sees the body as it arrives.
    private let capped: CappedSession

    public init(baseURL: URL, token: String?, session: URLSession? = nil) {
        self.builder = RelayRequestBuilder(baseURL: baseURL, token: token)
        let session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            // Every request sets its own timeout (short, or a long-poll's wait plus grace). The session value is
            // only a ceiling at the longest long-poll: on Windows the per-request value wins either way (measured),
            // and a 5 s session value could cut long-polls short on platforms that use the smaller of the two.
            configuration.timeoutIntervalForRequest =
                TimeInterval(WireLimits.maxWaitSeconds) + RelayRequestBuilder.longPollGrace
            return URLSession(configuration: configuration)
        }()
        self.session = session
        self.capped = CappedSession(configuration: session.configuration)
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

    public func putDevice(_ record: DeviceRecord) async throws {
        let (data, status) = try await send(builder.putDevice(record))
        try RelayRequestBuilder.check(status: status, body: data)
    }

    public func listDevices() async throws -> [DeviceRecord] {
        let (data, status) = try await send(builder.listDevices())
        try RelayRequestBuilder.check(status: status, body: data)
        return try decode(DeviceListResponse.self, data).devices
    }

    public func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        let (data, status) = try await send(builder.revoke(request))
        try RelayRequestBuilder.check(status: status, body: data)
        return try decode(RevokeResponse.self, data)
    }

    public func handoffs(deviceID: String) async throws -> [Data] {
        let (data, status) = try await send(builder.handoffs(deviceID: deviceID))
        try RelayRequestBuilder.check(status: status, body: data)
        return try decode(HandoffsResponse.self, data).handoffs
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

    /// Without a cap from the caller, still never more than the largest chunk the relay accepts.
    public func blobChunk(blobID: String, index: Int) async throws -> Data? {
        try await blobChunk(blobID: blobID, index: index, maxBytes: WireLimits.maxBlobChunkBodyBytes)
    }

    public func blobChunk(blobID: String, index: Int, maxBytes: Int) async throws -> Data? {
        let (data, status) = try await capped.send(builder.blobChunk(blobID: blobID, index: index), maxBytes: maxBytes)
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

/// A URLSession whose delegate reads each response as it arrives, so a body can be refused at its declared length
/// (Content-Length over the cap) or the moment it passes the cap, instead of after it's all in memory.
/// Shared by copies of one `HTTPTransport`; the session is invalidated (which releases its delegate) when the last
/// copy goes.
private final class CappedSession: Sendable {
    let session: URLSession
    let delegate: CappedResponseDelegate

    init(configuration: URLSessionConfiguration) {
        delegate = CappedResponseDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, Int) {
        let box = DataTaskBox()
        let result: (Data, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), Error>) in
                withAutoreleasePool {
                    let task = session.dataTask(with: request)
                    delegate.register(task, CappedResponse(maxBytes: maxBytes, continuation: continuation))
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

/// One response being read under a cap.
final class CappedResponse: @unchecked Sendable {
    /// Error bodies (a 4xx message) get at least this much room, even under a small cap.
    static let minimumErrorRoom = 4096
    let maxBytes: Int
    var status = 0
    var data = Data()
    var tooLarge = false
    private var continuation: CheckedContinuation<(Data, Int), Error>?

    init(maxBytes: Int, continuation: CheckedContinuation<(Data, Int), Error>) {
        self.maxBytes = maxBytes
        self.continuation = continuation
    }

    var limit: Int { (200..<300).contains(status) ? maxBytes : max(maxBytes, Self.minimumErrorRoom) }

    /// False when the declared length is already over the cap.
    func receive(_ response: URLResponse) -> Bool {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > Int64(limit) {
            tooLarge = true
            return false
        }
        return true
    }

    /// False (and nothing kept) when this piece would take the body past the cap.
    func append(_ piece: Data) -> Bool {
        guard piece.count <= limit - data.count else {
            tooLarge = true
            data = Data()
            return false
        }
        data.append(piece)
        return true
    }

    func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if tooLarge {
            continuation.resume(throwing: TransportError.responseTooLarge(limit: maxBytes))
        } else if let error {
            continuation.resume(throwing: TransportError.network(error.localizedDescription))
        } else if status == 0 {
            continuation.resume(throwing: TransportError.decoding)
        } else {
            continuation.resume(returning: (data, status))
        }
    }
}

/// Routes each task's callbacks to its `CappedResponse`. Callbacks for one task arrive in order on the session's
/// delegate queue; the lock covers the table, which `register` touches from other threads.
final class CappedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Int: CappedResponse] = [:]

    func register(_ task: URLSessionTask, _ response: CappedResponse) {
        lock.withLock { responses[task.taskIdentifier] = response }
    }

    private func response(for task: URLSessionTask) -> CappedResponse? {
        lock.withLock { responses[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let capped = self.response(for: dataTask) else { return completionHandler(.cancel) }
        completionHandler(capped.receive(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let capped = response(for: dataTask) else { return }
        if !capped.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let capped = lock.withLock { responses.removeValue(forKey: task.taskIdentifier) }
        capped?.finish(error)
    }
}
