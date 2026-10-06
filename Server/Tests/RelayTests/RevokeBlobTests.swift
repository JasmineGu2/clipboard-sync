import ClipWire
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import RelayCore

// F13 x F11/F12: a revoke wipes image and file blobs with the log, and blob routes refuse the old token, also when
// the token passed its check just before the revoke landed.

@Suite struct RevokeBlobTests {
    func revokeRequest(keep ids: [String]) -> RevokeRequest {
        RevokeRequest(
            newTokenSHA256: TokenAuthenticator.sha256Hex(newToken),
            devices: ids.map { record($0, sealed: 5) },
            handoffs: ids.map { Handoff(deviceID: $0, blob: Data(repeating: 0xaa, count: 80)) })
    }

    @Test func revokeWipesBlobsAndTheOldTokenGets401OnEveryBlobRoute() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0)).status == .noContent)
            #expect(try await client.putChunk(1, count: 2, body: chunkBody(1)).status == .noContent)
            for id in ["dev-a", "dev-lost"] { _ = try await client.putDevice(record(id)) }
            #expect(try await client.revoke(revokeRequest(keep: ["dev-a"])).status == .ok)

            // The old token: refused for upload, status, download and delete.
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(7), token: token).status == .unauthorized)
            #expect(try await client.blobStatus(token: token).status == .unauthorized)
            #expect(try await client.getChunk(0, token: token).status == .unauthorized)
            #expect(try await client.deleteBlob(token: token).status == .unauthorized)

            // The chunks sealed under the old vault key are gone; nothing counts against the cap any more.
            #expect(try await client.blobStatus(token: newToken).status == .notFound)
            #expect(try await client.getChunk(0, token: newToken).status == .notFound)
            #expect(try await relay.storage.blobBytesStored() == 0)

            // A remaining device re-uploads under the new key, with the same blob ID, and it's stored (not
            // ignored as "already stored", which is what keeping the old chunks would have caused).
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(8), token: newToken).status == .noContent)
            let download = try await client.getChunk(0, token: newToken)
            #expect(download.status == .ok)
            #expect(Data(buffer: download.body) == Data(repeating: 8, count: 64))
        }
    }

    /// Requests that passed the token check just before a revoke reach storage after it. Each blob call re-checks
    /// the hash in the same storage call, like push.
    @Test func blobCallsRecheckTheTokenInStorage() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        let old = try await storage.adoptAuthTokenHash("old-hash")
        _ = try await storage.putBlobChunk(
            blobID: blobA, index: 0, count: 2, data: Data(repeating: 1, count: 64), now: 0, maxTotalBytes: 1 << 30,
            requiringTokenHash: old)
        _ = try await storage.revoke(
            newTokenHash: "new-hash", devices: [record("dev-a")], handoffs: [], maxHandoffsPerDevice: 8,
            expectedDeviceIDs: nil)
        #expect(try await storage.blobStatus(blobID: blobA) == nil, "the revoke wiped the blob")

        // A stale upload must not plant an old-key chunk in the fresh relay.
        await #expect(throws: AuthChanged.self) {
            try await storage.putBlobChunk(
                blobID: blobA, index: 0, count: 2, data: Data(repeating: 2, count: 64), now: 0,
                maxTotalBytes: 1 << 30, requiringTokenHash: old)
        }
        #expect(try await storage.blobStatus(blobID: blobA) == nil)

        // The new key's upload lands; stale reads and deletes are refused and change nothing.
        #expect(try await storage.putBlobChunk(
            blobID: blobA, index: 0, count: 2, data: Data(repeating: 3, count: 64), now: 0, maxTotalBytes: 1 << 30,
            requiringTokenHash: "new-hash") == .stored)
        await #expect(throws: AuthChanged.self) { try await storage.blobStatus(blobID: blobA, requiringTokenHash: old) }
        await #expect(throws: AuthChanged.self) {
            try await storage.blobChunk(blobID: blobA, index: 0, requiringTokenHash: old)
        }
        await #expect(throws: AuthChanged.self) { try await storage.deleteBlob(blobID: blobA, requiringTokenHash: old) }
        #expect(try await storage.blobChunk(blobID: blobA, index: 0, requiringTokenHash: "new-hash")
            == Data(repeating: 3, count: 64))
    }

    /// The wipe is part of the revoke's transaction: a revoke that fails (device list changed) keeps the blobs.
    @Test func aRefusedRevokeKeepsTheBlobs() async throws {
        let storage = try SQLiteRelayStorage.inMemory()
        _ = try await storage.putBlobChunk(
            blobID: blobA, index: 0, count: 1, data: Data(repeating: 1, count: 64), now: 0, maxTotalBytes: 1 << 30)
        _ = try await storage.putDevice(record("dev-a"), maxDevices: 8)
        await #expect(throws: DeviceListChanged.self) {
            try await storage.revoke(
                newTokenHash: "new-hash", devices: [record("dev-a")], handoffs: [], maxHandoffsPerDevice: 8,
                expectedDeviceIDs: ["dev-a", "dev-other"])
        }
        #expect(try await storage.blobStatus(blobID: blobA)?.received == [0])
    }
}
