import ClipCore
import Crypto
import Foundation
import XCTest
@testable import ClipCrypto

/// Blob chunk encryption (PRD N7, N8): round trip, a known-answer vector, and every way of moving a chunk.
final class BlobCipherTests: XCTestCase {
    private let fixedKeyBytes = Data(0..<32)
    private let item = ItemID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
    private let blobID = BlobID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!)

    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// 10 bytes in chunks of 4: "0123", "4567", "89".
    private var smallBlob: BlobRef {
        BlobRef(id: blobID, size: 10, sha256: Data(SHA256.hash(data: Data("0123456789".utf8))), chunkSize: 4,
                contentType: "text/plain")
    }

    private func chunks(_ cipher: BlobCipher, _ plaintext: Data) throws -> [Data] {
        let ref = cipher.blob
        return try (0..<ref.chunkCount).map { index in
            let start = index * ref.chunkSize
            return try cipher.seal(plaintext.subdata(in: start..<(start + ref.plaintextLength(ofChunk: index))), index: index)
        }
    }

    // MARK: Known answer

    /// Expected bytes come from scripts/kat/blobcipher_kat.py (Python `cryptography`), not from Swift: they pin
    /// the per-blob key derivation, the AAD string and the nonce || ciphertext || tag layout.
    func testFixedNonceKnownAnswer() throws {
        let key = try VaultKey(rawBytes: fixedKeyBytes)
        XCTAssertEqual(
            key.blobKey(for: blobID).withUnsafeBytes { $0.hexString },
            "03695480ad21637fe6389e927a194760347bfcacadbe79e6f16b55f354cbf226")

        let cipher = BlobCipher(vaultKey: key, item: item, blob: smallBlob)
        XCTAssertEqual(
            String(decoding: cipher.aad(index: 2), as: UTF8.self),
            "clip.blob.v1|00000000-0000-0000-0000-0000000000B1|00000000-0000-0000-0000-0000000000C1|2|3|10")
        let nonce = try AES.GCM.Nonce(data: bytes("000102030405060708090a0b"))
        let chunk0 = "000102030405060708090a0b7e3310c2656311e62a480755273a0d82714afaec"
        let chunk2 = "000102030405060708090a0b763bb2954d52ea00242b7bb21b5cd0a2150b"
        XCTAssertEqual(try cipher.seal(Data("0123".utf8), index: 0, nonce: nonce).hexString, chunk0)
        XCTAssertEqual(try cipher.seal(Data("89".utf8), index: 2, nonce: nonce).hexString, chunk2)
        // Bytes made outside Swift open to the same plaintext.
        XCTAssertEqual(try cipher.open(bytes(chunk0), index: 0), Data("0123".utf8))
        XCTAssertEqual(try cipher.open(bytes(chunk2), index: 2), Data("89".utf8))
    }

    /// Freezes how an image item's create op encodes, the same way OpCipher's vector freezes text ops.
    /// Text items must not change at all: the optional blob fields are left out when nil.
    func testBlobContentEncodingIsStable() throws {
        let device = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)
        let ref = BlobRef(id: blobID, size: 10, sha256: Data(repeating: 0xab, count: 32), chunkSize: 4,
                          contentType: "image/png")
        let content = ItemContent(
            kind: .image, text: "shot.png", sourceDevice: device, sourceDeviceName: "Mac",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), blob: ref, thumbnail: Data([1, 2, 3]))
        let json = String(decoding: try ClipCoding.makeEncoder().encode(content), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"blob":{"chunkSize":4,"contentType":"image\/png","id":{"rawValue":"00000000-0000-0000-0000-0000000000C1"},"#
                + #""sha256":"q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=","size":10},"createdAt":1790000000000,"#
                + #""kind":"image","sourceDevice":{"rawValue":"00000000-0000-0000-0000-0000000000D1"},"#
                + #""sourceDeviceName":"Mac","text":"shot.png","thumbnail":"AQID"}"#)
        XCTAssertEqual(try ClipCoding.makeDecoder().decode(ItemContent.self, from: Data(json.utf8)), content)

        let text = ItemContent(text: "hi", sourceDevice: device, sourceDeviceName: "Mac",
                               createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let textJSON = String(decoding: try ClipCoding.makeEncoder().encode(text), as: UTF8.self)
        XCTAssertFalse(textJSON.contains("blob"))
        XCTAssertFalse(textJSON.contains("thumbnail"))
    }

    // MARK: Round trip

    func testRoundTripAndChunkGeometry() throws {
        let plaintext = Data("0123456789".utf8)
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob)
        let sealed = try chunks(cipher, plaintext)
        XCTAssertEqual(sealed.map(\.count), [4 + 28, 4 + 28, 2 + 28])
        let opened = try sealed.enumerated().map { try cipher.open($0.element, index: $0.offset) }
        XCTAssertEqual(opened.reduce(Data(), +), plaintext)
        XCTAssertNil(sealed[0].range(of: Data("0123".utf8)))
    }

    func testEmptyBlobHasOneAuthenticatedChunk() throws {
        let ref = BlobRef(id: BlobID(), size: 0, sha256: Data(SHA256.hash(data: Data())), contentType: nil)
        XCTAssertEqual(ref.chunkCount, 1)
        XCTAssertEqual(ref.plaintextLength(ofChunk: 0), 0)
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: ref)
        let sealed = try cipher.seal(Data(), index: 0)
        XCTAssertEqual(sealed.count, BlobCipher.overhead)
        XCTAssertEqual(try cipher.open(sealed, index: 0), Data())
    }

    func testChunkCountRoundsUp() {
        func ref(_ size: Int64) -> BlobRef { BlobRef(id: BlobID(), size: size, sha256: Data(), chunkSize: 4, contentType: nil) }
        XCTAssertEqual([1, 4, 5, 8, 9].map { ref($0).chunkCount }, [1, 1, 2, 2, 3])
        XCTAssertEqual(ref(9).plaintextLength(ofChunk: 2), 1)
        XCTAssertEqual(ref(8).plaintextLength(ofChunk: 1), 4)
    }

    func testNoncesDifferAcrossSeals() throws {
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob)
        let a = try cipher.seal(Data("0123".utf8), index: 0)
        let b = try cipher.seal(Data("0123".utf8), index: 0)
        XCTAssertNotEqual(a.prefix(12), b.prefix(12))
    }

    func testSealRefusesWrongLength() {
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob)
        XCTAssertThrowsError(try cipher.seal(Data("012".utf8), index: 0)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .invalidChunk)
        }
        XCTAssertThrowsError(try cipher.seal(Data("89".utf8), index: 3)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .invalidChunk)
        }
    }

    // MARK: Tamper

    private func assertFails(_ expression: @autoclosure () throws -> Data, _ expected: ClipCrypto.CryptoError = .decryptionFailed,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, expected, file: file, line: line)
        }
    }

    func testBitFlipsFail() throws {
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob)
        let sealed = try cipher.seal(Data("0123".utf8), index: 0)
        for index in [0, 12, sealed.count - 1] {  // nonce, body, tag
            var tampered = sealed
            tampered[tampered.startIndex + index] ^= 0x01
            assertFails(try cipher.open(tampered, index: 0))
        }
        assertFails(try cipher.open(sealed.prefix(10), index: 0))
    }

    func testReorderedChunksFail() throws {
        // Two full-length chunks, so only the index in the AAD tells them apart.
        let cipher = BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob)
        let sealed = try chunks(cipher, Data("0123456789".utf8))
        assertFails(try cipher.open(sealed[1], index: 0))
        assertFails(try cipher.open(sealed[0], index: 1))
        assertFails(try cipher.open(sealed[0], index: 2))
    }

    func testChunkMovedToAnotherBlobFails() throws {
        let key = VaultKey.generate()
        let a = BlobCipher(vaultKey: key, item: item, blob: smallBlob)
        var otherRef = smallBlob
        otherRef.id = BlobID()
        let b = BlobCipher(vaultKey: key, item: item, blob: otherRef)
        assertFails(try b.open(try a.seal(Data("0123".utf8), index: 0), index: 0))
    }

    func testChunkMovedToAnotherItemFails() throws {
        let key = VaultKey.generate()
        let a = BlobCipher(vaultKey: key, item: item, blob: smallBlob)
        let b = BlobCipher(vaultKey: key, item: ItemID(), blob: smallBlob)
        assertFails(try b.open(try a.seal(Data("0123".utf8), index: 0), index: 0))
    }

    /// Truncation: a relay that drops the tail and claims the blob is shorter. The receiver's count and size come
    /// from the encrypted op, but even a receiver told a smaller size can't open chunks sealed for the real one.
    func testTruncatedBlobFails() throws {
        let key = VaultKey.generate()
        let full = BlobCipher(vaultKey: key, item: item, blob: smallBlob)
        let sealed = try chunks(full, Data("0123456789".utf8))
        var shortRef = smallBlob
        shortRef.size = 8  // two chunks: "0123", "4567"
        let short = BlobCipher(vaultKey: key, item: item, blob: shortRef)
        assertFails(try short.open(sealed[0], index: 0))
        assertFails(try short.open(sealed[1], index: 1))
        // Asking past the last chunk is refused before decrypting.
        assertFails(try full.open(sealed[2], index: 3), .invalidChunk)
    }

    /// A key holder who seals a short chunk under the right AAD (e.g. a final chunk passed off as a middle one)
    /// is caught by the length check after decrypting.
    func testWrongLengthChunkFromKeyHolderFails() throws {
        let key = VaultKey.generate()
        let cipher = BlobCipher(vaultKey: key, item: item, blob: smallBlob)
        let box = try AES.GCM.seal(Data("01".utf8), using: key.blobKey(for: blobID), authenticating: cipher.aad(index: 0))
        assertFails(try cipher.open(try XCTUnwrap(box.combined), index: 0), .invalidChunk)
    }

    func testWrongVaultKeyFails() throws {
        let sealed = try BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob).seal(Data("0123".utf8), index: 0)
        assertFails(try BlobCipher(vaultKey: .generate(), item: item, blob: smallBlob).open(sealed, index: 0))
    }

    func testBlobKeysDifferPerBlobAndFromDataKey() {
        let key = VaultKey.generate()
        let a = key.blobKey(for: BlobID()).withUnsafeBytes { Data($0) }
        let b = key.blobKey(for: BlobID()).withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, key.dataKey.withUnsafeBytes { Data($0) })
    }
}
