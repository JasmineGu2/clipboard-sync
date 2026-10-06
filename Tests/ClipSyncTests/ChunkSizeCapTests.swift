import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A chunk response is checked against the chunk's exact sealed size while it's read: a declared length over it is
/// refused before any body arrives, and an undeclared body is cut off as soon as it passes the cap. So a hostile
/// relay can't make a device buffer more than one chunk (threat model, "A relay can send an oversized chunk").
final class ChunkSizeCapTests: XCTestCase {
    let blob = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let cap = WireLimits.maxBlobChunkBodyBytes

    override func tearDown() {
        StubRelayProtocol.scenario = nil
        super.tearDown()
    }

    func transport() throws -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelayProtocol.self]
        return HTTPTransport(
            baseURL: try XCTUnwrap(URL(string: "http://relay.test:8787")), token: "t",
            session: URLSession(configuration: configuration))
    }

    func expectTooLarge(_ body: () async throws -> Data?, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected responseTooLarge", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TransportError, .responseTooLarge(limit: cap), file: file, line: line)
        }
    }

    /// Declares 600 MB and would send 64 MiB: refused at the headers, so almost none of it is ever sent.
    func testDeclaredOversizedBodyIsRefusedBeforeReading() async throws {
        let scenario = StubScenario(status: 200, declaredLength: 600_000_000, total: 64 << 20)
        StubRelayProtocol.scenario = scenario
        let transport = try transport()
        await expectTooLarge { try await transport.blobChunk(blobID: blob, index: 0, maxBytes: cap) }
        let sent = scenario.waitUntilStopped()
        print("[N6] declared 600 MB chunk: refused after the stub sent \(sent) bytes")
        XCTAssertLessThan(sent, 4 << 20, "the client kept reading a body it had already refused")
    }

    /// No Content-Length, 64 MiB in 64 KiB pieces: cut off once past the cap, long before the end.
    func testUndeclaredOversizedBodyIsCutOffAtTheCap() async throws {
        let scenario = StubScenario(status: 200, declaredLength: nil, total: 64 << 20)
        StubRelayProtocol.scenario = scenario
        let transport = try transport()
        await expectTooLarge { try await transport.blobChunk(blobID: blob, index: 0, maxBytes: cap) }
        let sent = scenario.waitUntilStopped()
        print("[N6] undeclared 64 MiB chunk: cut off after the stub sent \(sent) bytes (cap \(cap))")
        XCTAssertLessThan(sent, 8 << 20, "the client read far past the cap")
    }

    /// The two-argument call (no expected size) still caps at the largest chunk the relay accepts.
    func testUncappedCallStillStopsAtTheRelaysChunkLimit() async throws {
        let scenario = StubScenario(status: 200, declaredLength: nil, total: 16 << 20)
        StubRelayProtocol.scenario = scenario
        let transport = try transport()
        await expectTooLarge { try await transport.blobChunk(blobID: blob, index: 0) }
        _ = scenario.waitUntilStopped()
    }

    func testBodyAtTheCapIsReturnedWhole() async throws {
        StubRelayProtocol.scenario = StubScenario(status: 200, declaredLength: 1_000, total: 1_000)
        let data = try await transport().blobChunk(blobID: blob, index: 0, maxBytes: 1_000)
        XCTAssertEqual(data, StubScenario.body(1_000))
    }

    func testMissingChunkIsNilAndErrorsKeepTheirMessage() async throws {
        StubRelayProtocol.scenario = StubScenario(status: 404, declaredLength: 0, total: 0)
        let missing = try await transport().blobChunk(blobID: blob, index: 0, maxBytes: 100)
        XCTAssertNil(missing)
        // A 401 under a tiny cap still maps to unauthorized (error bodies get some room of their own).
        StubRelayProtocol.scenario = StubScenario(status: 401, declaredLength: 200, total: 200)
        do {
            _ = try await transport().blobChunk(blobID: blob, index: 0, maxBytes: 100)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorized)
        }
    }

    // MARK: Through BlobTransferer, with fake transports

    func makeTransferer(_ transport: any BlobTransport) throws -> (BlobTransferer, BlobCache, BlobRef) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkSizeCap-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = try BlobCache(directory: dir)
        let ref = BlobRef(id: BlobID(), size: 3_000, sha256: Data(repeating: 1, count: 32), chunkSize: 1 << 20,
                          contentType: nil)
        return (BlobTransferer(cache: cache, transport: transport, vaultKey: VaultKey.generate()), cache, ref)
    }

    /// A relay fake that answers a 3 KB chunk with 8 MiB and knows nothing about caps (only the two-argument
    /// call): the default cap refuses it, and nothing reaches the partial file.
    func testOversizedChunkFromAFakeRelayIsRefusedAndNothingIsWritten() async throws {
        let relay = OversizedChunkRelay(reply: Data(count: 8 << 20))
        let (transferer, cache, ref) = try makeTransferer(relay)
        do {
            _ = try await transferer.download(ref, item: ItemID())
            XCTFail("expected corruptChunk")
        } catch {
            XCTAssertEqual(error as? BlobTransferError, .corruptChunk(index: 0))
        }
        XCTAssertEqual(cache.partialSize(of: ref.id), 0)
        XCTAssertFalse(cache.contains(ref.id))
    }

    /// The transferer asks for exactly the sealed size, and refuses anything else even from a transport that
    /// ignores the cap, or a short one.
    func testTransfererAsksForTheExactSealedSize() async throws {
        for reply in [Data(count: 3_000 + 29), Data(count: 3_000 + 27)] {
            let relay = CapRecordingRelay(reply: reply)
            let (transferer, cache, ref) = try makeTransferer(relay)
            do {
                _ = try await transferer.download(ref, item: ItemID())
                XCTFail("expected corruptChunk")
            } catch {
                XCTAssertEqual(error as? BlobTransferError, .corruptChunk(index: 0))
            }
            XCTAssertEqual(relay.caps, [3_000 + WireLimits.blobChunkOverheadBytes])
            XCTAssertEqual(cache.partialSize(of: ref.id), 0)
        }
    }
}

// MARK: - Fakes

/// Only the two-argument call, so the protocol's default cap applies.
final class OversizedChunkRelay: BlobTransport, @unchecked Sendable {
    let reply: Data
    init(reply: Data) { self.reply = reply }
    func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {}
    func blobStatus(blobID: String) async throws -> BlobStatus? { nil }
    func blobChunk(blobID: String, index: Int) async throws -> Data? { reply }
    func deleteBlob(blobID: String) async throws {}
}

/// Records the cap it was asked for and ignores it.
final class CapRecordingRelay: BlobTransport, @unchecked Sendable {
    let reply: Data
    private let lock = NSLock()
    private var recorded: [Int] = []
    var caps: [Int] { lock.withLock { recorded } }
    init(reply: Data) { self.reply = reply }
    func putBlobChunk(blobID: String, index: Int, count: Int, data: Data) async throws {}
    func blobStatus(blobID: String) async throws -> BlobStatus? { nil }
    func blobChunk(blobID: String, index: Int) async throws -> Data? { reply }
    func blobChunk(blobID: String, index: Int, maxBytes: Int) async throws -> Data? {
        lock.withLock { recorded.append(maxBytes) }
        return reply
    }
    func deleteBlob(blobID: String) async throws {}
}

/// What the stub relay answers, and how much of it it managed to send before the client hung up.
final class StubScenario: @unchecked Sendable {
    static let piece = 64 << 10
    let status: Int
    let declaredLength: Int?
    let total: Int
    private let lock = NSLock()
    private var sentBytes = 0
    private var isStopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(status: Int, declaredLength: Int?, total: Int) {
        self.status = status
        self.declaredLength = declaredLength
        self.total = total
    }

    static func body(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }

    var stopped: Bool { lock.withLock { isStopped } }
    func stop() { lock.withLock { isStopped = true } }
    func sent(_ count: Int) { lock.withLock { sentBytes += count } }
    func done() { finished.signal() }

    /// Waits for the sending thread to notice the stop (or finish), then returns what it sent.
    func waitUntilStopped() -> Int {
        _ = finished.wait(timeout: .now() + 30)
        return lock.withLock { sentBytes }
    }
}

/// Plays a relay inside URLSession, sending the body piece by piece on its own thread until stopped.
final class StubRelayProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scenario: StubScenario?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var current: StubScenario?

    override func startLoading() {
        guard let scenario = Self.scenario, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        current = scenario
        var headers = ["Content-Type": "application/octet-stream"]
        if let declared = scenario.declaredLength { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: url, statusCode: scenario.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let client = self.client
        Thread.detachNewThread { [self] in
            defer { scenario.done() }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < scenario.total, !scenario.stopped {
                let count = min(StubScenario.piece, scenario.total - offset)
                let piece = scenario.total <= StubScenario.piece
                    ? StubScenario.body(count) : Data(repeating: 0xAB, count: count)
                client?.urlProtocol(self, didLoad: piece)
                scenario.sent(count)
                offset += count
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !scenario.stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        current?.stop()
    }
}
