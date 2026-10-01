import ClipCore
import ClipWire
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

    // MARK: - OpCipher envelope with a fixed nonce

    /// Pins the whole wire format: op JSON, data key derivation, AAD string, and the
    /// nonce || ciphertext || tag layout. Expected bytes were computed independently with
    /// Python's `cryptography` (HKDF-SHA256 + AESGCM) from the plaintext below. The plaintext
    /// itself is Swift's output frozen as of 2026-10-01: changing it breaks old devices, so it fails here first.
    func testOpCipherFixedNonceKnownAnswer() throws {
        let device = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)
        let op = Op(
            id: OpID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!),
            itemID: ItemID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!),
            timestamp: HLCTimestamp(wallMillis: 1_790_000_000_000, counter: 7, device: device),
            kind: .create(ItemContent(
                text: "hello",
                sourceDevice: device,
                sourceDeviceName: "PC",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000)
            ))
        )
        let expectedPlaintext = #"{"id":{"rawValue":"00000000-0000-0000-0000-0000000000A1"},"#
            + #""itemID":{"rawValue":"00000000-0000-0000-0000-0000000000B1"},"#
            + #""kind":{"create":{"_0":{"createdAt":1790000000000,"kind":"text","#
            + #""sourceDevice":{"rawValue":"00000000-0000-0000-0000-0000000000D1"},"#
            + #""sourceDeviceName":"PC","text":"hello"}}},"#
            + #""timestamp":{"counter":7,"device":{"rawValue":"00000000-0000-0000-0000-0000000000D1"},"#
            + #""wallMillis":1790000000000}}"#
        // scripts/kat/opcipher_kat.py prints this.
        let expectedCombined = "000102030405060708090a0b"
            + "445bbfd098ef664d059465acf319a1fdf274e5ead0d44de5deb0f4fea557052ed9109bc878fd62eff57c168e3532fb63"
            + "5d4b7cd1459b39870226fa5805dc2917319d08f96b39307d4a2514da1c218ab4ef330560e9b471180f653de485b218b2"
            + "994a994d582d558c160333d0ae86512fac29dfc7f3c24fd683d3c06bcff6e15ff1cdc88ae6ebec463d18e1d194e3b262"
            + "50a193f5ac6a1ea8acb3797bdcf55298e6480cef8b6f5fb80d9f45bb5a9a4e6050a504810fe5ddf74ee630231f4fea6b"
            + "851c791e758987bdef5b029f1c7413c04bbdbb98812174f7ccea9e02237087437f54a83a7effea9f9062c6fe9b0894d7"
            + "4d5e378a013f968d0f33e945e36b0421befb692a9991d2cf433741559c70f12792d584118c80fe81d446530a2fae7005"
            + "ef68eac8972725ee0b0a433eec1519bfa7600278df6783f716a43fec71e8c3fbb4ae6ace87b7d84b8c80988c85897d3b"
            + "ade3145424df903ced24b8e55f3859790d0a26cda99d4ce09dea3557472b90446762e4c39022f86e783eb0cf5edd7826"
            + "5c79b66b93f8e800eb80d700c64532605380d97b82b2234e1de1d9ea519a125b04c92507dac7"

        let plaintext = try OpCipher.makeEncoder().encode(op)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), expectedPlaintext)

        let cipher = OpCipher(vaultKey: try VaultKey(rawBytes: fixedKeyBytes))
        let nonce = try AES.GCM.Nonce(data: bytes("000102030405060708090a0b"))
        let envelope = try cipher.seal(op, device: device, nonce: nonce)
        XCTAssertEqual(envelope.ciphertext.hexString, expectedCombined)

        // And the reverse: bytes made outside Swift open to the same op.
        let foreign = Envelope(
            opID: envelope.opID, itemID: envelope.itemID, deviceID: envelope.deviceID,
            ciphertext: Data(bytes(expectedCombined))
        )
        XCTAssertEqual(try cipher.open(foreign), op)
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
