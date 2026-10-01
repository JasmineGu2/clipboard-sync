import Crypto
import Foundation
import XCTest
@testable import ClipCrypto

/// Known-answer tests. Expected values come from published vectors or from an independent
/// HKDF built here on HMAC-SHA256 (and cross-checked offline with Python's hmac/hashlib).
final class KnownAnswerTests: XCTestCase {
    // MARK: - Independent RFC 5869 HKDF (extract, then expand), test-only

    private func referenceHKDF(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> (prk: [UInt8], okm: [UInt8]) {
        let prk = Array(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
        var okm: [UInt8] = []
        var previous: [UInt8] = []
        var counter: UInt8 = 1
        while okm.count < length {
            previous = Array(HMAC<SHA256>.authenticationCode(for: previous + info + [counter], using: SymmetricKey(data: prk)))
            okm += previous
            counter += 1
        }
        return (prk, Array(okm.prefix(length)))
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }

    // MARK: - RFC 5869 Test Case 1

    func testRFC5869TestCase1() {
        let ikm = [UInt8](repeating: 0x0b, count: 22)
        let salt = bytes("000102030405060708090a0b0c")
        let info = bytes("f0f1f2f3f4f5f6f7f8f9")
        let expectedPRK = "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
        let expectedOKM = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"

        let reference = referenceHKDF(ikm: ikm, salt: salt, info: info, length: 42)
        XCTAssertEqual(reference.prk.hexString, expectedPRK)
        XCTAssertEqual(reference.okm.hexString, expectedOKM)

        let library = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 42
        )
        XCTAssertEqual(library.withUnsafeBytes { $0.hexString }, expectedOKM)
    }

    // MARK: - Vault key derivations for the fixed key 0x00...0x1f

    private let fixedKeyBytes = Data((0..<32).map { UInt8($0) })

    func testAuthTokenKnownAnswer() throws {
        let key = try VaultKey(rawBytes: fixedKeyBytes)
        let expected = "4346d366d13d64963cffd4880429fa7b631c753a4f7315de5e699a19f7920546"
        XCTAssertEqual(key.authToken, expected)

        let reference = referenceHKDF(
            ikm: Array(fixedKeyBytes), salt: Array("clip.v1".utf8), info: Array("clip.auth.v1".utf8), length: 32
        )
        XCTAssertEqual(reference.okm.hexString, expected)
    }

    func testDataKeyKnownAnswer() throws {
        let key = try VaultKey(rawBytes: fixedKeyBytes)
        let expected = "9465a96eb24eb872e7e5cb56ca56db2315114376732c30cd5078e7607708deb7"
        XCTAssertEqual(key.dataKey.withUnsafeBytes { $0.hexString }, expected)

        let reference = referenceHKDF(
            ikm: Array(fixedKeyBytes), salt: Array("clip.v1".utf8), info: Array("clip.data.v1".utf8), length: 32
        )
        XCTAssertEqual(reference.okm.hexString, expected)
    }

    func testPairingWrapKeyKnownAnswer() throws {
        let code = try XCTUnwrap(PairingCode(string: "000G40R40M30E209185GR38E1W8124GK"))
        XCTAssertEqual(code.bytes, Data((0..<20).map { UInt8($0) }))
        // Computed independently with Python hmac/hashlib (RFC 5869).
        let expected = "13bbafa857fa86c8d62e92ad96fb666ca8e7d30b0c46fc83990e1fc0745df457"
        XCTAssertEqual(code.wrapKey.withUnsafeBytes { $0.hexString }, expected)

        let reference = referenceHKDF(
            ikm: Array(code.bytes), salt: Array("clip.v1".utf8), info: Array("clip.pair.wrap.v1".utf8), length: 32
        )
        XCTAssertEqual(reference.okm.hexString, expected)
    }

    // MARK: - AES-256-GCM: McGrew & Viega, "The Galois/Counter Mode of Operation", Test Case 16

    func testAESGCMTestCase16() throws {
        let key = SymmetricKey(data: bytes("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
        let plaintext = bytes(
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
                + "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"
        )
        let aad = bytes("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let nonce = try AES.GCM.Nonce(data: bytes("cafebabefacedbaddecaf888"))
        let expectedCiphertext = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
            + "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"
        let expectedTag = "76fc6ece0f4e1768cddf8853bb2d551b"

        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        XCTAssertEqual(box.ciphertext.hexString, expectedCiphertext)
        XCTAssertEqual(box.tag.hexString, expectedTag)

        let opened = try AES.GCM.open(
            AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes(expectedCiphertext), tag: bytes(expectedTag)),
            using: key,
            authenticating: aad
        )
        XCTAssertEqual(Array(opened), plaintext)
    }
}
