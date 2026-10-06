import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation
import XCTest
@testable import ClipSync

final class ZZFootprintProbe: BlobTransferTests {
    func testProbeCalls() async throws {
        let file = try makeFile(bytes: 20 * 1_048_576)
        func mb() -> Double { Double(FootprintSampler.footprint() ?? 0) / 1_048_576 }
        let cache = try BlobCache(directory: try tempDirectory())
        let id = BlobID()
        let imported = try cache.importFile(at: file, as: id, maxBytes: .max)
        let ref = BlobRef(id: id, size: imported.size, sha256: imported.sha256, contentType: nil)
        let cipher = BlobCipher(vaultKey: key, item: ItemID(), blob: ref)
        let plain = try cache.readChunk(of: id, index: 0, chunkSize: 1 << 20, length: 1 << 20)
        let sealed = try cipher.seal(plain, index: 0)
        let u = try tempDirectory().appendingPathComponent("x")
        try sealed.write(to: u)
        var b = mb()
        func step(_ name: String, _ body: () throws -> Void) rethrows {
            for _ in 0..<20 { try body() }
            let n = mb(); print("PROBE \(name) +\(String(format: "%.1f", n - b))"); b = n
        }
        try step("readChunk") { _ = try cache.readChunk(of: id, index: 1, chunkSize: 1 << 20, length: 1 << 20) }
        try step("seal") { _ = try cipher.seal(plain, index: 0) }
        try step("open") { _ = try cipher.open(sealed, index: 0) }
        try step("contentsOf") { _ = try Data(contentsOf: u) }
        try step("write(to:)") { try sealed.write(to: u) }
        let dl = try BlobCache(directory: try tempDirectory()).beginDownload(BlobRef(id: BlobID(), size: 20 << 20, sha256: Data(count: 32), contentType: nil))
        try step("append") { try dl.append(plain) }
        // async variants
        let t = try DiskBlobTransport(directory: try tempDirectory())
        for _ in 0..<20 { try await t.putBlobChunk(blobID: id.description, index: 0, count: 1, data: sealed) }
        print("PROBE async put +\(String(format: "%.1f", mb() - b))"); b = mb()
        for _ in 0..<20 { _ = try await t.blobChunk(blobID: id.description, index: 0) }
        print("PROBE async get +\(String(format: "%.1f", mb() - b))"); b = mb()
    }
}
