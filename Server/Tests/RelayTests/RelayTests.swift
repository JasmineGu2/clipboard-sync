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
    var pinnedHash: String?
    var maxBlobStorageBytes = RelayConfig().maxBlobStorageBytes

    init(pinnedHash: String? = nil) throws {
        storage = try .inMemory()
        self.pinnedHash = pinnedHash
    }

    func run(_ body: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        var config = RelayConfig()
        config.authTokenSHA256 = pinnedHash
        config.maxBlobStorageBytes = maxBlobStorageBytes
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
        try await Relay().run { client async throws in
            let response = try await client.execute(uri: "/healthz", method: .get) { $0 }
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "ok")
        }
    }

    @Test func pushPullRoundTrip() async throws {
        try await Relay().run { client async throws in
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

    @Test func everyPushAndPullCarriesTheEpoch() async throws {
        let relay = try Relay()
        let epoch = try await relay.storage.epoch()
        #expect(UUID(uuidString: epoch) != nil)
        try await relay.run { client async throws in
            #expect(try decode(PushResponse.self, try await client.push([envelope(1)])).epoch == epoch)
            #expect(try decode(PushResponse.self, try await client.push([])).epoch == epoch)
            #expect(try decode(PullResponse.self, try await client.pull("?after=0")).epoch == epoch)
            #expect(try decode(PullResponse.self, try await client.pull("?after=1&wait=1")).epoch == epoch)
        }
    }

    @Test func duplicateOpIDIsIgnored() async throws {
        try await Relay().run { client async throws in
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
        try await Relay().run { client async throws in
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
        try await Relay().run { client async throws in
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

    @Test func cursorAheadOfLogIs409() async throws {
        try await Relay().run { client async throws in
            // Empty log: any positive cursor is ahead.
            let empty = try await client.pull("?after=1")
            #expect(empty.status == .conflict)
            #expect(try decode(CursorAheadResponse.self, empty) == CursorAheadResponse(latestSeq: 0))

            _ = try await client.push([envelope(1), envelope(2)])
            #expect(try await client.pull("?after=2").status == .ok)  // caught up is fine
            let ahead = try await client.pull("?after=5&wait=20")     // answers at once, no long-poll
            #expect(ahead.status == .conflict)
            #expect(try decode(CursorAheadResponse.self, ahead).latestSeq == 2)
        }
    }

    @Test func badQueryIs400() async throws {
        try await Relay().run { client async throws in
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
        try await relay.run { client async throws in
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
        try await relay.run { client async throws in
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
        try await Relay().run { client async throws in
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
        try await Relay().run { client async throws in
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
        try await relay.run { client async throws in
            _ = try await client.execute(uri: "/v1/ops", method: .get, headers: [.authorization: "Bearer "]) { $0 }
            #expect(try await client.pull(token: "second").status == .ok)
            #expect(try await client.pull(token: token).status == .unauthorized)
        }
    }

    @Test func storesOnlyTheHash() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in _ = try await client.pull() }
        let stored = try await relay.storage.adoptAuthTokenHash("ignored")
        #expect(stored == TokenAuthenticator.sha256Hex(token))
        #expect(stored != token)
        #expect(stored.count == 64)
    }

    @Test func pinnedHashDisablesTrustOnFirstUse() async throws {
        try await Relay(pinnedHash: TokenAuthenticator.sha256Hex(token).uppercased()).run { client async throws in
            // A stranger arriving first is not adopted.
            #expect(try await client.pull(token: "stranger").status == .unauthorized)
            #expect(try await client.pull().status == .ok)
            #expect(try await client.pull(token: "stranger").status == .unauthorized)
        }
    }

    @Test func rotateReplacesTheToken() async throws {
        let relay = try Relay()
        let newToken = "new-token-after-revocation"
        let newHash = TokenAuthenticator.sha256Hex(newToken)
        try await relay.run { client async throws in
            #expect(try await client.pull().status == .ok)  // adopts `token`
            func rotate(_ hash: String, with value: String) async throws -> TestResponse {
                try await client.execute(uri: "/v1/auth/rotate", method: .post, headers: authHeaders(value),
                                         body: try json(RotateTokenRequest(newTokenSHA256: hash))) { $0 }
            }
            #expect(try await rotate(newHash, with: "wrong").status == .unauthorized)
            #expect(try await rotate("not-hex", with: token).status == .badRequest)
            #expect(try await rotate(newHash, with: token).status == .noContent)
            #expect(try await client.pull().status == .unauthorized)
            #expect(try await client.pull(token: newToken).status == .ok)
            // Rotating needs the current token, so the old one can't rotate back.
            #expect(try await rotate(TokenAuthenticator.sha256Hex(token), with: token).status == .unauthorized)
        }
        #expect(try await relay.storage.authTokenHash() == newHash)
    }

    @Test func adoptedHashIsCached() async throws {
        let relay = try Relay()
        let storage = relay.storage
        try await relay.run { client async throws in
            #expect(try await client.pull().status == .ok)
            // Changing the row behind the authenticator's back shows requests no longer read storage.
            try await storage.setAuthTokenHash(TokenAuthenticator.sha256Hex("other"))
            #expect(try await client.pull().status == .ok)
            #expect(try await client.pull(token: "other").status == .unauthorized)
        }
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
    func put(_ client: any TestClientProtocol, _ id: String, _ blob: Data,
             token value: String? = token) async throws -> TestResponse {
        let headers: HTTPFields = value.map(authHeaders) ?? [.contentType: "application/json"]
        return try await client.execute(uri: "/v1/pairing/\(id)", method: .put, headers: headers,
                                        body: try json(PairingBlob(blob: blob))) { $0 }
    }

    func get(_ client: any TestClientProtocol, _ id: String) async throws -> TestResponse {
        try await client.execute(uri: "/v1/pairing/\(id)", method: .get) { $0 }
    }

    @Test func putThenGetOnce() async throws {
        try await Relay().run { client async throws in
            let blob = Data((0..<60).map { UInt8($0) })
            #expect(try await put(client, pairingID, blob).status == .noContent)
            let first = try await get(client, pairingID)
            #expect(first.status == .ok)
            #expect(try decode(PairingBlob.self, first).blob == blob)
            #expect(try await get(client, pairingID).status == .notFound)
        }
    }

    @Test func liveIDCannotBeOverwritten() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            #expect(try await put(client, pairingID, Data([1])).status == .noContent)
            #expect(try await put(client, pairingID, Data([2])).status == .conflict)
            #expect(try decode(PairingBlob.self, try await get(client, pairingID)).blob == Data([1]))
            // Once taken, or once expired, the ID is free again.
            #expect(try await put(client, pairingID, Data([3])).status == .noContent)
            relay.clock.advance(by: 10 * 60)
            #expect(try await put(client, pairingID, Data([4])).status == .noContent)
        }
    }

    @Test func tableIsCappedAt100Live() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            for n in 0..<WireLimits.maxLivePairings {
                #expect(try await put(client, String(format: "%032x", n), Data([1])).status == .noContent)
            }
            let extra = String(repeating: "f", count: 32)
            #expect(try await put(client, extra, Data([1])).status == .tooManyRequests)
            // Taking one frees a slot.
            #expect(try await get(client, String(format: "%032x", 0)).status == .ok)
            #expect(try await put(client, extra, Data([1])).status == .noContent)
            #expect(try await put(client, String(repeating: "e", count: 32), Data([1])).status == .tooManyRequests)
            // Expired rows are purged before counting.
            relay.clock.advance(by: 10 * 60)
            #expect(try await put(client, String(repeating: "e", count: 32), Data([1])).status == .noContent)
        }
    }

    @Test func expiresAfterTenMinutes() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            _ = try await put(client, pairingID, Data([1]))
            relay.clock.advance(by: 9 * 60)
            #expect(try await get(client, pairingID).status == .ok)

            _ = try await put(client, pairingID, Data([2]))
            relay.clock.advance(by: 10 * 60)
            #expect(try await get(client, pairingID).status == .notFound)
        }
    }

    @Test func badIDIs400() async throws {
        try await Relay().run { client async throws in
            for id in ["0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef", "0123456789abcdef0123456789abcdeg",
                       "0123456789abcdef0123456789abcdef0"] {
                #expect(try await put(client, id, Data([1])).status == .badRequest)
                #expect(try await get(client, id).status == .badRequest)
            }
        }
    }

    @Test func putNeedsTokenGetDoesNot() async throws {
        try await Relay().run { client async throws in
            #expect(try await put(client, pairingID, Data([1]), token: nil).status == .unauthorized)
            #expect(try await put(client, pairingID, Data([1]), token: token).status == .noContent)  // adopts
            #expect(try await put(client, pairingID, Data([1]), token: "wrong").status == .unauthorized)
            // The new device has no token yet.
            #expect(try await get(client, pairingID).status == .ok)
        }
    }
}

// MARK: - Limits

@Suite struct LimitTests {
    @Test func tooManyEnvelopesIs413() async throws {
        try await Relay().run { client async throws in
            let response = try await client.push((0...WireLimits.maxEnvelopesPerPush).map { envelope($0, bytes: 4) })
            #expect(response.status == .contentTooLarge)
            #expect(try await client.push((1...WireLimits.maxEnvelopesPerPush).map { envelope($0, bytes: 4) }).status == .ok)
        }
    }

    @Test func oversizedCiphertextIs413() async throws {
        try await Relay().run { client async throws in
            let big = envelope(1, bytes: WireLimits.maxCiphertextBytes + 1)
            #expect(try await client.push([big]).status == .contentTooLarge)
            let max = envelope(2, bytes: WireLimits.maxCiphertextBytes)
            #expect(try await client.push([max]).status == .ok)
            let page = try decode(PullResponse.self, try await client.pull())
            #expect(page.envelopes.map(\.opID) == ["op-2"])
        }
    }

    @Test func invalidEnvelopesAre400() async throws {
        try await Relay().run { client async throws in
            var noOp = envelope(1); noOp.opID = ""
            #expect(try await client.push([noOp]).status == .badRequest)
            var empty = envelope(2); empty.ciphertext = Data()
            #expect(try await client.push([empty]).status == .badRequest)
            var longID = envelope(3); longID.itemID = String(repeating: "x", count: 129)
            #expect(try await client.push([longID]).status == .badRequest)
            let garbage = try await client.execute(uri: "/v1/ops", method: .post, headers: authHeaders(),
                                                   body: ByteBuffer(string: "{not json")) { $0 }
            #expect(garbage.status == .badRequest)
            for bad in ["op\u{0}4", "op\n4", "op\u{1b}4", "op\u{85}4"] {
                var control = envelope(4); control.opID = bad
                #expect(try await client.push([control]).status == .badRequest)
            }
            #expect(try decode(PullResponse.self, try await client.pull()).envelopes.isEmpty)
        }
    }

    @Test func pushBodyOverFourMiBIs413BeforeDecoding() async throws {
        try await Relay().run { client async throws in
            // Each envelope is within its own caps, but together they're ~7 MB of JSON.
            let big = (1...20).map { envelope($0, bytes: WireLimits.maxCiphertextBytes) }
            #expect(try await client.push(big).status == .contentTooLarge)
            // Not JSON at all, but over the cap: 413, not 400, so the cap applies before decoding.
            let junk = ByteBuffer(repeating: UInt8(ascii: "x"), count: WireLimits.maxPushBodyBytes + 1)
            let response = try await client.execute(uri: "/v1/ops", method: .post, headers: authHeaders(),
                                                    body: junk) { $0 }
            #expect(response.status == .contentTooLarge)
            // ~3.5 MB is fine.
            let fits = (1...10).map { envelope($0, bytes: WireLimits.maxCiphertextBytes) }
            #expect(try await client.push(fits).status == .ok)
        }
    }

    @Test func idsRoundTripByteForByte() async throws {
        try await Relay().run { client async throws in
            var unicode = envelope(1)
            unicode.opID = "op-é-日本-🙂"
            unicode.itemID = "item-ü"
            #expect(try await client.push([unicode]).status == .ok)
            let page = try decode(PullResponse.self, try await client.pull())
            #expect(page.envelopes.map(\.opID) == ["op-é-日本-🙂"])
            #expect(page.envelopes.map(\.itemID) == ["item-ü"])
        }
    }

    @Test func oversizedPairingBlobIs413() async throws {
        try await Relay().run { client async throws in
            // Body under the 100 KB cap, blob over 64 KiB.
            let response = try await client.execute(
                uri: "/v1/pairing/\(pairingID)", method: .put, headers: authHeaders(),
                body: try json(PairingBlob(blob: Data(count: 64 * 1024 + 1)))) { $0 }
            #expect(response.status == .contentTooLarge)
            // Body over the cap, and not even JSON: refused before decoding.
            let junk = ByteBuffer(repeating: UInt8(ascii: "x"), count: WireLimits.maxPairingBodyBytes + 1)
            let raw = try await client.execute(uri: "/v1/pairing/\(pairingID)", method: .put,
                                               headers: authHeaders(), body: junk) { $0 }
            #expect(raw.status == .contentTooLarge)
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

    @Test func epochIsStableAcrossRestartsAndNewForANewDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
        let path = directory.appendingPathComponent("relay-\(UUID().uuidString).sqlite3").path
        let otherPath = directory.appendingPathComponent("relay-\(UUID().uuidString).sqlite3").path
        defer {
            for file in [path, otherPath] {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file + suffix) }
            }
        }
        let first: String
        do {
            let storage = try SQLiteRelayStorage(path: path)
            first = try await storage.epoch()
            _ = try await storage.append([envelope(1)])
        }
        #expect(UUID(uuidString: first) != nil)
        // Same file after a restart: same epoch.
        #expect(try await SQLiteRelayStorage(path: path).epoch() == first)
        #expect(try await SQLiteRelayStorage(path: path).epoch() == first)
        // A new database file (the relay was reset or replaced): a new epoch.
        let other = try await SQLiteRelayStorage(path: otherPath).epoch()
        #expect(other != first)
        #expect(try await SQLiteRelayStorage.inMemory().epoch() != first)
    }

    @Test func pinnedHashSurvivesRestartWithoutUndoingRotation() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        #expect(try await storage.authTokenHash() == nil)
        #expect(try await storage.seedAuthTokenHash("pin-1") == "pin-1")
        try await storage.setAuthTokenHash("rotated")
        // Same pin on the next start: the rotation stands.
        #expect(try await storage.seedAuthTokenHash("pin-1") == "rotated")
        // A new pin value wins.
        #expect(try await storage.seedAuthTokenHash("pin-2") == "pin-2")
        #expect(try await storage.authTokenHash() == "pin-2")
    }

    @Test func emptyAppendReportsLatestSeq() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await storage.append([envelope(1)])
        #expect(try await storage.append([]) == AppendResult(inserted: 0, latestSeq: 1))
    }
}
