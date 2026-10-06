import ClipWire
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import RelayCore

// F13: device records, revocation and rekey handoffs.

let newToken = "f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f"

func record(_ id: String, key: UInt8 = 1, sealed: UInt8 = 9) -> DeviceRecord {
    DeviceRecord(deviceID: id, publicKey: Data(repeating: key, count: 32), sealed: Data(repeating: sealed, count: 40))
}

extension TestClientProtocol {
    func putDevice(_ record: DeviceRecord, path: String? = nil, token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/devices/\(path ?? record.deviceID)", method: .put, headers: authHeaders(value),
                          body: try json(record)) { $0 }
    }

    func listDevices(token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/devices", method: .get, headers: authHeaders(value)) { $0 }
    }

    func revoke(_ request: RevokeRequest, token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/auth/revoke", method: .post, headers: authHeaders(value), body: try json(request)) { $0 }
    }

    func rekey(_ id: String) async throws -> TestResponse {
        try await execute(uri: "/v1/rekey/\(id)", method: .get) { $0 }
    }
}

@Suite struct DeviceTests {
    @Test func putAndList() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.putDevice(record("dev-b")).status == .noContent)
            #expect(try await client.putDevice(record("dev-a")).status == .noContent)
            // Same key again (a device re-registering, maybe with a new name) is fine.
            #expect(try await client.putDevice(record("dev-a", sealed: 7)).status == .noContent)
            let list = try decode(DeviceListResponse.self, try await client.listDevices())
            #expect(list.devices == [record("dev-a", sealed: 7), record("dev-b")])
        }
    }

    @Test func aDeviceIDKeepsItsFirstKey() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.putDevice(record("dev-a", key: 1)).status == .noContent)
            #expect(try await client.putDevice(record("dev-a", key: 2)).status == .conflict)
            let list = try decode(DeviceListResponse.self, try await client.listDevices())
            #expect(list.devices.map(\.publicKey) == [Data(repeating: 1, count: 32)])
        }
    }

    @Test func needsTheToken() async throws {
        try await Relay().run { client async throws in
            _ = try await client.push([envelope(1)])  // adopt `token`
            #expect(try await client.putDevice(record("dev-a"), token: "wrong").status == .unauthorized)
            #expect(try await client.listDevices(token: "wrong").status == .unauthorized)
        }
    }

    @Test func badRecordsAre400() async throws {
        try await Relay().run { client async throws in
            var shortKey = record("dev-a")
            shortKey.publicKey = Data(count: 31)
            var emptySealed = record("dev-a")
            emptySealed.sealed = Data()
            var bigSealed = record("dev-a")
            bigSealed.sealed = Data(count: WireLimits.maxSealedDeviceBytes + 1)
            for bad in [shortKey, emptySealed, bigSealed] {
                #expect(try await client.putDevice(bad).status == .badRequest)
            }
            #expect(try await client.putDevice(record("dev-a"), path: "dev-b").status == .badRequest)
        }
    }

    @Test func tableIsCapped() async throws {
        try await Relay().run { client async throws in
            for i in 0..<WireLimits.maxDevices {
                #expect(try await client.putDevice(record("dev-\(i)")).status == .noContent)
            }
            #expect(try await client.putDevice(record("one-too-many")).status == .tooManyRequests)
            // An existing device can still update its record.
            #expect(try await client.putDevice(record("dev-0", sealed: 3)).status == .noContent)
        }
    }
}

@Suite struct RevokeTests {
    func revokeRequest(keep ids: [String], handoffsFor: [String]? = nil) -> RevokeRequest {
        RevokeRequest(
            newTokenSHA256: TokenAuthenticator.sha256Hex(newToken),
            devices: ids.map { record($0, sealed: 5) },
            handoffs: (handoffsFor ?? ids).map { Handoff(deviceID: $0, blob: Data(repeating: 0xaa, count: 80)) })
    }

    @Test func revokeSwapsTheTokenWipesTheLogAndStartsANewEpoch() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            let pushed = try decode(PushResponse.self, try await client.push([envelope(1), envelope(2)]))
            for id in ["dev-a", "dev-b", "dev-lost"] { _ = try await client.putDevice(record(id)) }
            #expect(try await PairingTests().put(client, pairingID, Data([1, 2, 3])).status == .noContent)

            let response = try await client.revoke(revokeRequest(keep: ["dev-a", "dev-b"]))
            #expect(response.status == .ok)
            let epoch = try decode(RevokeResponse.self, response).epoch
            #expect(epoch != pushed.epoch)

            // The old token is dead everywhere it was accepted.
            #expect(try await client.pull("?after=0", token: token).status == .unauthorized)
            #expect(try await client.push([envelope(3)], token: token).status == .unauthorized)
            #expect(try await client.listDevices(token: token).status == .unauthorized)
            #expect(try await client.revoke(revokeRequest(keep: ["dev-lost"]), token: token).status == .unauthorized)

            // The new one works, on an empty log with the new epoch.
            let page = try decode(PullResponse.self, try await client.pull("?after=0", token: newToken))
            #expect(page.envelopes.isEmpty)
            #expect(page.epoch == epoch)
            // Pairing blobs were parked under the old key; they're gone.
            #expect(try await PairingTests().get(client, pairingID).status == .notFound)

            // The device table is exactly what the revoke listed.
            let list = try decode(DeviceListResponse.self, try await client.listDevices(token: newToken))
            #expect(list.devices == [record("dev-a", sealed: 5), record("dev-b", sealed: 5)])
            // A pushed op after the wipe gets a seq the client can pull from 0.
            _ = try await client.push([envelope(1)], token: newToken)
            let after = try decode(PullResponse.self, try await client.pull("?after=0", token: newToken))
            #expect(after.envelopes.map(\.opID) == ["op-1"])
        }
    }

    @Test func handoffsAreServedWithoutATokenAndOnlyForKeptDevices() async throws {
        try await Relay().run { client async throws in
            for id in ["dev-a", "dev-lost"] { _ = try await client.putDevice(record(id)) }
            #expect(try await client.revoke(revokeRequest(keep: ["dev-a"])).status == .ok)

            let mine = try decode(HandoffsResponse.self, try await client.rekey("dev-a"))
            #expect(mine.handoffs == [Data(repeating: 0xaa, count: 80)])
            #expect(try decode(HandoffsResponse.self, try await client.rekey("dev-lost")).handoffs.isEmpty)
            #expect(try decode(HandoffsResponse.self, try await client.rekey("never-seen")).handoffs.isEmpty)
        }
    }

    /// A device that was offline through two revokes gets both handoffs, oldest first, so it can follow the chain.
    /// A device revoked by the second loses the handoff from the first. Old handoffs are capped per device.
    @Test func handoffsChainAndAreCapped() async throws {
        let relay = try Relay(pinnedHash: TokenAuthenticator.sha256Hex(token))
        try await relay.run { client async throws in
            func request(_ n: UInt8, keep ids: [String]) -> RevokeRequest {
                RevokeRequest(
                    newTokenSHA256: TokenAuthenticator.sha256Hex("token-\(n)"),
                    devices: ids.map { record($0) },
                    handoffs: ids.map { Handoff(deviceID: $0, blob: Data(repeating: n, count: 80)) })
            }
            #expect(try await client.revoke(request(1, keep: ["dev-a", "dev-b"]), token: token).status == .ok)
            #expect(try await client.revoke(request(2, keep: ["dev-a"]), token: "token-1").status == .ok)
            let chain = try decode(HandoffsResponse.self, try await client.rekey("dev-a")).handoffs
            #expect(chain == [Data(repeating: 1, count: 80), Data(repeating: 2, count: 80)])
            #expect(try decode(HandoffsResponse.self, try await client.rekey("dev-b")).handoffs.isEmpty)

            var current = "token-2"
            for n in UInt8(3)...20 {
                #expect(try await client.revoke(request(n, keep: ["dev-a"]), token: current).status == .ok)
                current = "token-\(n)"
            }
            let capped = try decode(HandoffsResponse.self, try await client.rekey("dev-a")).handoffs
            #expect(capped.count == WireLimits.maxHandoffsPerDevice)
            #expect(capped.last == Data(repeating: 20, count: 80))
            #expect(capped.first == Data(repeating: UInt8(21 - WireLimits.maxHandoffsPerDevice), count: 80))
        }
    }

    @Test func badRevokeRequestsAre400AndChangeNothing() async throws {
        try await Relay().run { client async throws in
            _ = try await client.push([envelope(1)])
            var badHash = revokeRequest(keep: ["dev-a"])
            badHash.newTokenSHA256 = "nope"
            var duplicate = revokeRequest(keep: ["dev-a", "dev-a"], handoffsFor: [])
            duplicate.handoffs = []
            let strayHandoff = revokeRequest(keep: ["dev-a"], handoffsFor: ["dev-a", "dev-x"])
            var bigHandoff = revokeRequest(keep: ["dev-a"])
            bigHandoff.handoffs[0].blob = Data(count: WireLimits.maxHandoffBytes + 1)
            var badRecord = revokeRequest(keep: ["dev-a"])
            badRecord.devices[0].publicKey = Data(count: 3)
            let nobody = revokeRequest(keep: [])

            for bad in [badHash, duplicate, strayHandoff, bigHandoff, badRecord, nobody] {
                #expect(try await client.revoke(bad).status == .badRequest)
            }
            // Still the old token and the old log.
            let page = try decode(PullResponse.self, try await client.pull("?after=0"))
            #expect(page.envelopes.map(\.opID) == ["op-1"])
        }
    }

    /// A revoked device that was waiting in a long-poll must not see what the remaining devices push next.
    @Test func aWaitingLongPollWithTheOldTokenEndsIn401() async throws {
        let relay = try Relay()
        let notifier = relay.notifier
        try await relay.run { client async throws in
            _ = try await client.push([envelope(1)])
            async let waiting = client.pull("?after=1&wait=20")
            try await waitUntil { await notifier.waiterCount == 1 }
            #expect(try await client.revoke(revokeRequest(keep: ["dev-a"])).status == .ok)
            _ = try await client.push([envelope(7), envelope(8)], token: newToken)
            #expect(try await waiting.status == .unauthorized)
        }
    }

    /// The revoker sends the device IDs it saw. If one registered meanwhile, the relay refuses and changes nothing.
    @Test func aDeviceThatRegisteredMeanwhileStopsTheRevoke() async throws {
        try await Relay().run { client async throws in
            for id in ["dev-a", "dev-lost"] { _ = try await client.putDevice(record(id)) }
            var request = revokeRequest(keep: ["dev-a"])
            request.expectedDeviceIDs = ["dev-a", "dev-lost"]
            _ = try await client.putDevice(record("dev-new"))  // registers after the revoker read the list
            #expect(try await client.revoke(request).status == .conflict)
            #expect(try await client.listDevices().status == .ok, "the old token still works")

            request.expectedDeviceIDs = ["dev-a", "dev-lost", "dev-new"]
            #expect(try await client.revoke(request).status == .ok)
        }
    }

    /// A push that passed the token check just before a revoke must not land in the new log.
    @Test func aWriteRechecksTheTokenInsideItsTransaction() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        let old = try await storage.adoptAuthTokenHash("old-hash")
        _ = try await storage.revoke(
            newTokenHash: "new-hash", devices: [record("dev-a")], handoffs: [], maxHandoffsPerDevice: 8,
            expectedDeviceIDs: nil)
        await #expect(throws: AuthChanged.self) { try await storage.append([envelope(1)], requiringTokenHash: old) }
        #expect(try await storage.latestSeq() == 0)
        #expect(try await storage.append([envelope(1)], requiringTokenHash: "new-hash").inserted == 1)
    }

    /// A restart keeps the revoked state: new token, new epoch, and the operator pin doesn't undo it.
    @Test func revokeSurvivesARestart() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString).sqlite3").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let pin = TokenAuthenticator.sha256Hex(token)
        let epoch: String
        do {
            let storage = try SQLiteRelayStorage(path: path)
            _ = try await storage.seedAuthTokenHash(pin)
            _ = try await storage.append([envelope(1)])
            epoch = try await storage.revoke(
                newTokenHash: "new-hash", devices: [record("dev-a")],
                handoffs: [Handoff(deviceID: "dev-a", blob: Data([1]))], maxHandoffsPerDevice: 8,
                expectedDeviceIDs: nil)
        }
        let reopened = try SQLiteRelayStorage(path: path)
        #expect(try await reopened.epoch() == epoch)
        #expect(try await reopened.seedAuthTokenHash(pin) == "new-hash")
        #expect(try await reopened.latestSeq() == 0)
        #expect(try await reopened.devices() == [record("dev-a")])
        #expect(try await reopened.handoffs(deviceID: "dev-a") == [Data([1])])
    }
}
