import ClipWire
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import RelayCore

// MARK: - Harness

/// A clock tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_700_000_000
    var now: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(by seconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        value += seconds
    }
}

struct Relay {
    let storage: SQLiteRelayStorage
    let notifier = PushNotifier()
    let clock = TestClock()

    init() throws { storage = try .inMemory() }

    func run(_ body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        var config = RelayConfig()
        let clock = self.clock
        config.now = { clock.now }
        let app = Application(router: buildRelayRouter(storage: storage, notifier: notifier, config: config))
        try await app.test(.router) { client in try await body(client) }
    }
}

let token = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

func envelope(_ n: Int, bytes: Int = 40) -> Envelope {
    Envelope(opID: "op-\(n)", itemID: "item-\(n % 3)", deviceID: "dev-a", ciphertext: Data(repeating: UInt8(n & 0xff), count: bytes))
}

func json<T: Encodable>(_ value: T) throws -> ByteBuffer {
    ByteBuffer(bytes: try JSONEncoder().encode(value))
}

func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(response.body.readableBytesView))
}

func authHeaders(_ value: String = token) -> HTTPFields {
    [.authorization: "Bearer \(value)", .contentType: "application/json"]
}

extension TestClientProtocol {
    func push(_ envelopes: [Envelope], token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/ops", method: .post, headers: authHeaders(value),
                          body: try json(PushRequest(envelopes: envelopes))) { $0 }
    }

    func pull(_ query: String = "", token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/ops\(query)", method: .get, headers: authHeaders(value)) { $0 }
    }
}

let pairingID = "0123456789abcdef0123456789abcdef"

/// Polls `condition` every 10 ms for up to 5 s.
func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Ops

@Suite struct OpsTests {
    @Test func healthz() async throws {
        try await Relay().run { client in
            let response = try await client.execute(uri: "/healthz", method: .get) { $0 }
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "ok")
        }
    }

    @Test func pushPullRoundTrip() async throws {
        try await Relay().run { client in
            let sent = (1...3).map { envelope($0) }
            let pushed = try await client.push(sent)
            #expect(pushed.status == .ok)
            #expect(try decode(PushResponse.self, pushed).latestSeq == 3)

            let pulled = try await client.pull("?after=0")
            #expect(pulled.status == .ok)
            let page = try decode(PullResponse.self, pulled)
            #expect(page.latestSeq == 3)
            #expect(page.hasMore == false)
            #expect(page.envelopes.map(\.seq) == [1, 2, 3])
            #expect(page.envelopes.map(\.opID) == sent.map(\.opID))
            #expect(page.envelopes.map(\.itemID) == sent.map(\.itemID))
            #expect(page.envelopes.map(\.deviceID) == sent.map(\.deviceID))
            #expect(page.envelopes.map(\.ciphertext) == sent.map(\.ciphertext))

            let empty = try decode(PullResponse.self, try await client.pull("?after=3"))
            #expect(empty.envelopes.isEmpty)
            #expect(empty.latestSeq == 3)
        }
    }

    @Test func duplicateOpIDIsIgnored() async throws {
        try await Relay().run { client in
            #expect(try decode(PushResponse.self, try await client.push([envelope(1)])).latestSeq == 1)
            // A retry of the same op, plus a duplicate inside one push.
            var retry = envelope(1)
            retry.ciphertext = Data([9, 9, 9])
            let again = try await client.push([retry, envelope(2), envelope(2)])
            #expect(try decode(PushResponse.self, again).latestSeq == 2)

            let page = try decode(PullResponse.self, try await client.pull())
            #expect(page.envelopes.map(\.opID) == ["op-1", "op-2"])
            #expect(page.envelopes[0].ciphertext == envelope(1).ciphertext)  // first write wins
        }
    }

    @Test func paginationAndHasMore() async throws {
        try await Relay().run { client in
            _ = try await client.push((1...7).map { envelope($0) })

            var cursor: Int64 = 0
            var pages: [[Int64]] = []
            var flags: [Bool] = []
            while true {
                let page = try decode(PullResponse.self, try await client.pull("?after=\(cursor)&limit=3"))
                pages.append(page.envelopes.compactMap(\.seq))
                flags.append(page.hasMore)
                #expect(page.latestSeq == 7)
                guard let last = page.envelopes.last?.seq, page.hasMore else { break }
                cursor = last
            }
            #expect(pages == [[1, 2, 3], [4, 5, 6], [7]])
            #expect(flags == [true, true, false])

            // Exactly `limit` rows left: hasMore must be false.
            let exact = try decode(PullResponse.self, try await client.pull("?after=4&limit=3"))
            #expect(exact.envelopes.compactMap(\.seq) == [5, 6, 7])
            #expect(exact.hasMore == false)
        }
    }

    @Test func pullLimitIsClamped() async throws {
        try await Relay().run { client in
            _ = try await client.push((1...400).map { envelope($0, bytes: 8) })
            _ = try await client.push((401...650).map { envelope($0, bytes: 8) })

            let huge = try decode(PullResponse.self, try await client.pull("?limit=100000"))
            #expect(huge.envelopes.count == 500)
            #expect(huge.hasMore)
            let defaulted = try decode(PullResponse.self, try await client.pull())
            #expect(defaulted.envelopes.count == 500)
            let zero = try decode(PullResponse.self, try await client.pull("?limit=0"))
            #expect(zero.envelopes.count == 1)
        }
    }

    @Test func badQueryIs400() async throws {
        try await Relay().run { client in
            #expect(try await client.pull("?after=abc").status == .badRequest)
            #expect(try await client.pull("?after=-1").status == .badRequest)
            #expect(try await client.pull("?wait=soon").status == .badRequest)
        }
    }
}

// MARK: - Long-poll

@Suite struct LongPollTests {
    @Test func longPollReturnsWhenPushArrives() async throws {
        let relay = try Relay()
        let notifier = relay.notifier
        try await relay.run { client in
            let started = ContinuousClock.now
            async let waiting = client.pull("?after=0&wait=20")

            // Wait until the pull is parked on the notifier.
            try await waitUntil { await notifier.waiterCount == 1 }
            #expect(await notifier.waiterCount == 1)

            _ = try await client.push([envelope(1)])
            let response = try await waiting
            let page = try decode(PullResponse.self, response)
            #expect(page.envelopes.map(\.opID) == ["op-1"])
            #expect(ContinuousClock.now - started < .seconds(10))
            #expect(await notifier.waiterCount == 0)
        }
    }

    @Test func longPollTimesOutEmpty() async throws {
        let relay = try Relay()
        let notifier = relay.notifier
        try await relay.run { client in
            let started = ContinuousClock.now
            let page = try decode(PullResponse.self, try await client.pull("?after=0&wait=1"))
            let elapsed = ContinuousClock.now - started
            #expect(page.envelopes.isEmpty)
            #expect(page.hasMore == false)
            #expect(elapsed >= .milliseconds(900))
            #expect(elapsed < .seconds(5))
            #expect(await notifier.waiterCount == 0)
        }
    }

    @Test func waitReturnsAtOnceWhenPushRacedAhead() async throws {
        let notifier = PushNotifier()
        let observed = await notifier.generation
        await notifier.notify()  // lands between "query" and "wait"
        let started = ContinuousClock.now
        await notifier.wait(since: observed, timeout: .seconds(10))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await notifier.waiterCount == 0)
    }

    @Test func cancelledWaitDoesNotLeak() async throws {
        let notifier = PushNotifier()
        let observed = await notifier.generation
        let task = Task { await notifier.wait(since: observed, timeout: .seconds(30)) }
        try await waitUntil { await notifier.waiterCount == 1 }
        #expect(await notifier.waiterCount == 1)
        let started = ContinuousClock.now
        task.cancel()
        await task.value
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await notifier.waiterCount == 0)

        // Already cancelled before waiting: returns at once, registers nothing.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await notifier.wait(since: observed, timeout: .seconds(30))
        }
        await early.value
        #expect(await notifier.waiterCount == 0)
    }

    @Test func manyWaitersAllWake() async throws {
        let notifier = PushNotifier()
        let observed = await notifier.generation
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await notifier.wait(since: observed, timeout: .seconds(30)) }
            }
            try? await waitUntil { await notifier.waiterCount == 20 }
            await notifier.notify()
        }
        #expect(await notifier.waiterCount == 0)
    }
}

// MARK: - Auth

@Suite struct AuthTests {
    @Test func firstTokenIsAdoptedAndOthersRejected() async throws {
        try await Relay().run { client in
            #expect(try await client.push([envelope(1)]).status == .ok)  // adopts `token`
            #expect(try await client.pull().status == .ok)
            #expect(try await client.pull(token: "wrong-token").status == .unauthorized)
            #expect(try await client.push([envelope(2)], token: "wrong-token").status == .unauthorized)
            // The rejected push stored nothing.
            let page = try decode(PullResponse.self, try await client.pull())
            #expect(page.envelopes.map(\.opID) == ["op-1"])
        }
    }

    @Test func missingOrMalformedHeaderIs401() async throws {
        try await Relay().run { client in
            let none = try await client.execute(uri: "/v1/ops", method: .get) { $0 }
            #expect(none.status == .unauthorized)
            let basic = try await client.execute(uri: "/v1/ops", method: .get,
                                                 headers: [.authorization: "Basic abc"]) { $0 }
            #expect(basic.status == .unauthorized)
            let empty = try await client.execute(uri: "/v1/ops", method: .get,
                                                 headers: [.authorization: "Bearer "]) { $0 }
            #expect(empty.status == .unauthorized)
        }
        // A rejected header never adopts a token.
        let relay = try Relay()
        try await relay.run { client in
            _ = try await client.execute(uri: "/v1/ops", method: .get, headers: [.authorization: "Bearer "]) { $0 }
            #expect(try await client.pull(token: "second").status == .ok)
            #expect(try await client.pull(token: token).status == .unauthorized)
        }
    }

    @Test func storesOnlyTheHash() async throws {
        let relay = try Relay()
        try await relay.run { client in _ = try await client.pull() }
        let stored = try await relay.storage.adoptAuthTokenHash("ignored")
        #expect(stored == TokenAuthenticator.sha256Hex(token))
        #expect(stored != token)
        #expect(stored.count == 64)
    }

    @Test func helpers() {
        #expect(TokenAuthenticator.bearerToken(from: "bearer abc") == "abc")
        #expect(TokenAuthenticator.bearerToken(from: "Bearer  abc ") == "abc")
        #expect(TokenAuthenticator.bearerToken(from: "Token abc") == nil)
        #expect(TokenAuthenticator.constantTimeEquals("abc", "abc"))
        #expect(!TokenAuthenticator.constantTimeEquals("abc", "abd"))
        #expect(!TokenAuthenticator.constantTimeEquals("abc", "abcd"))
        // SHA-256("abc") known vector.
        #expect(TokenAuthenticator.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - Pairing

@Suite struct PairingTests {
    func put(_ client: any TestClientProtocol, _ id: String, _ blob: Data) async throws -> TestResponse {
        try await client.execute(uri: "/v1/pairing/\(id)", method: .put,
                                 headers: [.contentType: "application/json"],
                                 body: try json(PairingBlob(blob: blob))) { $0 }
    }

    func get(_ client: any TestClientProtocol, _ id: String) async throws -> TestResponse {
        try await client.execute(uri: "/v1/pairing/\(id)", method: .get) { $0 }
    }

    @Test func putThenGetOnce() async throws {
        try await Relay().run { client in
            let blob = Data((0..<60).map { UInt8($0) })
            #expect(try await put(client, pairingID, blob).status == .noContent)
            let first = try await get(client, pairingID)
            #expect(first.status == .ok)
            #expect(try decode(PairingBlob.self, first).blob == blob)
            #expect(try await get(client, pairingID).status == .notFound)
        }
    }

    @Test func overwriteAllowed() async throws {
        try await Relay().run { client in
            _ = try await put(client, pairingID, Data([1]))
            #expect(try await put(client, pairingID, Data([2])).status == .noContent)
            #expect(try decode(PairingBlob.self, try await get(client, pairingID)).blob == Data([2]))
        }
    }

    @Test func expiresAfterTenMinutes() async throws {
        let relay = try Relay()
        try await relay.run { client in
            _ = try await put(client, pairingID, Data([1]))
            relay.clock.advance(by: 9 * 60)
            #expect(try await get(client, pairingID).status == .ok)

            _ = try await put(client, pairingID, Data([2]))
            relay.clock.advance(by: 10 * 60)
            #expect(try await get(client, pairingID).status == .notFound)
        }
    }

    @Test func badIDIs400() async throws {
        try await Relay().run { client in
            for id in ["0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef", "0123456789abcdef0123456789abcdeg",
                       "0123456789abcdef0123456789abcdef0"] {
                #expect(try await put(client, id, Data([1])).status == .badRequest)
                #expect(try await get(client, id).status == .badRequest)
            }
        }
    }

    @Test func needsNoToken() async throws {
        // Pairing must not adopt or require a token.
        try await Relay().run { client in
            _ = try await put(client, pairingID, Data([1]))
            #expect(try await client.pull(token: "later-token").status == .ok)
        }
    }
}

// MARK: - Limits

@Suite struct LimitTests {
    @Test func tooManyEnvelopesIs413() async throws {
        try await Relay().run { client in
            let response = try await client.push((0...WireLimits.maxEnvelopesPerPush).map { envelope($0, bytes: 4) })
            #expect(response.status == .contentTooLarge)
            #expect(try await client.push((1...WireLimits.maxEnvelopesPerPush).map { envelope($0, bytes: 4) }).status == .ok)
        }
    }

    @Test func oversizedCiphertextIs413() async throws {
        try await Relay().run { client in
            let big = envelope(1, bytes: WireLimits.maxCiphertextBytes + 1)
            #expect(try await client.push([big]).status == .contentTooLarge)
            let max = envelope(2, bytes: WireLimits.maxCiphertextBytes)
            #expect(try await client.push([max]).status == .ok)
            let page = try decode(PullResponse.self, try await client.pull())
            #expect(page.envelopes.map(\.opID) == ["op-2"])
        }
    }

    @Test func invalidEnvelopesAre400() async throws {
        try await Relay().run { client in
            var noOp = envelope(1); noOp.opID = ""
            #expect(try await client.push([noOp]).status == .badRequest)
            var empty = envelope(2); empty.ciphertext = Data()
            #expect(try await client.push([empty]).status == .badRequest)
            var longID = envelope(3); longID.itemID = String(repeating: "x", count: 129)
            #expect(try await client.push([longID]).status == .badRequest)
            let garbage = try await client.execute(uri: "/v1/ops", method: .post, headers: authHeaders(),
                                                   body: ByteBuffer(string: "{not json")) { $0 }
            #expect(garbage.status == .badRequest)
        }
    }

    @Test func oversizedPairingBlobIs413() async throws {
        try await Relay().run { client in
            let response = try await client.execute(
                uri: "/v1/pairing/\(pairingID)", method: .put, headers: [.contentType: "application/json"],
                body: try json(PairingBlob(blob: Data(count: 64 * 1024 + 1)))) { $0 }
            #expect(response.status == .contentTooLarge)
        }
    }
}

// MARK: - Storage

@Suite struct StorageTests {
    @Test func fileDatabaseUsesWALAndPersists() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString).sqlite3").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        do {
            let storage = try SQLiteRelayStorage(path: path)
            #expect(try await storage.journalMode() == "wal")
            _ = try await storage.append([envelope(1), envelope(2)])
        }
        let reopened = try SQLiteRelayStorage(path: path)
        #expect(try await reopened.latestSeq() == 2)
        // seq keeps growing after reopen.
        #expect(try await reopened.append([envelope(3)]).latestSeq == 3)
    }

    @Test func emptyAppendReportsLatestSeq() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await storage.append([envelope(1)])
        #expect(try await storage.append([]) == AppendResult(inserted: 0, latestSeq: 1))
    }
}
