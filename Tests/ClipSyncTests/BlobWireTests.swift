import ClipCore
import ClipCrypto
import ClipWire
import Foundation
import XCTest

/// The blob parts of the wire contract (ClipWire) agree with the model (ClipCore) and the cipher (ClipCrypto).
final class BlobWireTests: XCTestCase {
    func testLimitsAgreeAcrossModules() {
        XCTAssertEqual(WireLimits.blobChunkPlaintextBytes, BlobRef.defaultChunkSize)
        XCTAssertEqual(WireLimits.blobChunkOverheadBytes, BlobCipher.overhead)
        XCTAssertEqual(WireLimits.maxBlobBytes, 512 * 1024 * 1024)
        // A create op with the largest thumbnail, as base64 JSON, stays far under the per-op cap.
        XCTAssertLessThan(ItemContent.maxThumbnailBytes * 4 / 3 + 4096, WireLimits.maxCiphertextBytes / 2)
    }

    func testBlobIDValidation() {
        XCTAssertTrue(WireLimits.isValidBlobID(UUID().uuidString))
        XCTAssertTrue(WireLimits.isValidBlobID(UUID().uuidString.lowercased()))
        for bad in ["", "../etc/passwd", String(repeating: "a", count: 36), UUID().uuidString + "x",
                    "00000000-0000-0000-0000-00000000000G", "00000000_0000-0000-0000-000000000000"] {
            XCTAssertFalse(WireLimits.isValidBlobID(bad), bad)
        }
    }

    func testBlobStatusCompleteness() throws {
        let status = BlobStatus(blobID: "x", chunkCount: 3, received: [0, 2])
        XCTAssertFalse(status.isComplete)
        let json = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(BlobStatus.self, from: json), status)
        XCTAssertTrue(BlobStatus(blobID: "x", chunkCount: 2, received: [0, 1]).isComplete)
    }
}
