import ClipWire
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import RelayCore

// Blob routes (F11, F12): chunked upload with a resume query, chunk download, body caps, auth, delete.

let blobA = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

func chunkBody(_ n: Int, bytes: Int = 64) -> ByteBuffer {
    ByteBuffer(bytes: Data(repeating: UInt8(n & 0xff), count: bytes))
}

extension TestClientProtocol {
    func putChunk(_ index: Int, blob: String = blobA, count: Int, body: ByteBuffer,
                  token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/blobs/\(blob)/chunks/\(index)?count=\(count)", method: .put,
                          headers: [.authorization: "Bearer \(value)", .contentType: "application/octet-stream"],
                          body: body) { $0 }
    }

    func getChunk(_ index: Int, blob: String = blobA, token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/blobs/\(blob)/chunks/\(index)", method: .get, headers: authHeaders(value)) { $0 }
    }

    func blobStatus(_ blob: String = blobA, token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/blobs/\(blob)", method: .get, headers: authHeaders(value)) { $0 }
    }

    func deleteBlob(_ blob: String = blobA, token value: String = token) async throws -> TestResponse {
        try await execute(uri: "/v1/blobs/\(blob)", method: .delete, headers: authHeaders(value)) { $0 }
    }
}

@Suite struct BlobRouteTests {
    @Test func uploadStatusDownloadRoundTrip() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.blobStatus().status == .notFound)
            #expect(try await client.putChunk(0, count: 3, body: chunkBody(0)).status == .noContent)
            #expect(try await client.putChunk(2, count: 3, body: chunkBody(2, bytes: 30)).status == .noContent)

            // The resume query: which chunks are there.
            let status = try decode(BlobStatus.self, try await client.blobStatus())
            #expect(status == BlobStatus(blobID: blobA, chunkCount: 3, received: [0, 2]))
            #expect(!status.isComplete)
            #expect(try await client.getChunk(1).status == .notFound)

            #expect(try await client.putChunk(1, count: 3, body: chunkBody(1)).status == .noContent)
            #expect(try decode(BlobStatus.self, try await client.blobStatus()).isComplete)

            let chunk = try await client.getChunk(2)
            #expect(chunk.status == .ok)
            #expect(chunk.headers[.contentType] == "application/octet-stream")
            #expect(Data(chunk.body.readableBytesView) == Data(repeating: 2, count: 30))
        }
    }

    @Test func retriedChunkKeepsTheFirstCopy() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(7)).status == .noContent)
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(9)).status == .noContent)
            #expect(Data(try await client.getChunk(0).body.readableBytesView) == Data(repeating: 7, count: 64))
        }
    }

    @Test func chunkCountIsFixedByTheFirstChunk() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0)).status == .noContent)
            #expect(try await client.putChunk(1, count: 3, body: chunkBody(1)).status == .conflict)
            #expect(try await client.putChunk(2, count: 2, body: chunkBody(2)).status == .badRequest)
        }
    }

    @Test func badParametersAre400() async throws {
        try await Relay().run { client async throws in
            #expect(try await client.putChunk(0, blob: "not-a-uuid", count: 1, body: chunkBody(0)).status == .badRequest)
            #expect(try await client.putChunk(-1, count: 1, body: chunkBody(0)).status == .badRequest)
            #expect(try await client.putChunk(0, count: 0, body: chunkBody(0)).status == .badRequest)
            #expect(try await client.putChunk(0, count: WireLimits.maxBlobChunks + 1, body: chunkBody(0)).status == .badRequest)
            #expect(try await client.putChunk(WireLimits.maxBlobChunks, count: WireLimits.maxBlobChunks,
                                              body: chunkBody(0)).status == .badRequest)
            // Shorter than a nonce and a tag: can't be a sealed chunk.
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0, bytes: 27)).status == .badRequest)
            let missingCount = try await client.execute(
                uri: "/v1/blobs/\(blobA)/chunks/0", method: .put, headers: authHeaders(), body: chunkBody(0)) { $0 }
            #expect(missingCount.status == .badRequest)
            #expect(try await client.getChunk(0, blob: "..%2F..%2Fetc").status == .badRequest)
        }
    }

    @Test func chunkBodyCapIs413() async throws {
        try await Relay().run { client async throws in
            let max = WireLimits.maxBlobChunkBodyBytes
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0, bytes: max)).status == .noContent)
            #expect(try await client.putChunk(0, blob: blobA.replacingOccurrences(of: "F", with: "E"), count: 1,
                                              body: chunkBody(0, bytes: max + 1)).status == .contentTooLarge)
        }
    }

    @Test func everyBlobRouteNeedsTheToken() async throws {
        try await Relay(pinnedHash: TokenAuthenticator.sha256Hex(token)).run { client async throws in
            let wrong = "f" + token.dropFirst()
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0), token: wrong).status == .unauthorized)
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0)).status == .noContent)
            #expect(try await client.getChunk(0, token: wrong).status == .unauthorized)
            #expect(try await client.blobStatus(token: wrong).status == .unauthorized)
            #expect(try await client.deleteBlob(token: wrong).status == .unauthorized)
            let noHeader = try await client.execute(uri: "/v1/blobs/\(blobA)/chunks/0", method: .get) { $0 }
            #expect(noHeader.status == .unauthorized)
            #expect(try await client.getChunk(0).status == .ok)
        }
    }

    @Test func deleteRemovesEverythingAndIsIdempotent() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0)).status == .noContent)
            #expect(try await client.putChunk(1, count: 2, body: chunkBody(1)).status == .noContent)
            #expect(try await client.deleteBlob().status == .noContent)
            #expect(try await client.blobStatus().status == .notFound)
            #expect(try await client.getChunk(0).status == .notFound)
            #expect(try await client.deleteBlob().status == .noContent)
            // A fresh upload under the same ID may choose a new count.
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0)).status == .noContent)
        }
        #expect(try await relay.storage.blobBytesStored() == 64)
    }

    @Test func storageCapIs507() async throws {
        var relay = try Relay()
        relay.maxBlobStorageBytes = 100
        try await relay.run { client async throws in
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0, bytes: 60)).status == .noContent)
            #expect(try await client.putChunk(1, count: 2, body: chunkBody(1, bytes: 60)).status.code == 507)
            // Already stored chunks still answer 204: a retry isn't new data.
            #expect(try await client.putChunk(0, count: 2, body: chunkBody(0, bytes: 60)).status == .noContent)
        }
    }

    @Test func blobsLiveApartFromTheOpLog() async throws {
        let relay = try Relay()
        try await relay.run { client async throws in
            #expect(try await client.putChunk(0, count: 1, body: chunkBody(0)).status == .noContent)
            let page = try decode(PullResponse.self, try await client.pull("?after=0"))
            #expect(page.envelopes.isEmpty)
            #expect(page.latestSeq == 0)
        }
    }

    @Test func blobsSurviveReopeningTheDatabase() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("relay-blobs-\(UUID().uuidString).sqlite3").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        do {
            let storage = try SQLiteRelayStorage(path: path)
            _ = try await storage.putBlobChunk(blobID: blobA, index: 0, count: 2, data: Data([1, 2, 3]), now: 1,
                                               maxTotalBytes: .max)
        }
        let reopened = try SQLiteRelayStorage(path: path)
        let status = try await reopened.blobStatus(blobID: blobA)
        #expect(status?.chunkCount == 2)
        #expect(status?.received == [0])
        #expect(try await reopened.blobChunk(blobID: blobA, index: 0) == Data([1, 2, 3]))
    }
}
