import ClipCore
import ClipWire
import Crypto
import Foundation
import XCTest
@testable import ClipCrypto

final class OpCipherTests: XCTestCase {
    private let device = DeviceID()

    private func makeOp(text: String = "hello clipboard", item: ItemID = ItemID()) -> Op {
        let content = ItemContent(
            text: text,
            sourceDevice: device,
            sourceDeviceName: "Test PC",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
        let stamp = HLCTimestamp(wallMillis: 1_700_000_000_500, counter: 3, device: device)
        return Op(itemID: item, timestamp: stamp, kind: .create(content))
    }

    func testRoundTrip() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let op = makeOp()
        let envelope = try cipher.seal(op, device: device)

        XCTAssertEqual(envelope.opID, op.id.rawValue.uuidString)
        XCTAssertEqual(envelope.itemID, op.itemID.rawValue.uuidString)
        XCTAssertEqual(envelope.deviceID, device.rawValue.uuidString)
        XCTAssertNil(envelope.seq)
        XCTAssertEqual(try cipher.open(envelope), op)
    }

    func testRoundTripEveryOpKind() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let item = ItemID()
        let stamp = HLCTimestamp(wallMillis: 42, counter: 0, device: device)
        let kinds: [OpKind] = [.setPinned(true), .setTitle("Title"), .setTitle(nil), .setTag("work", present: true), .delete]
        for kind in kinds {
            let op = Op(itemID: item, timestamp: stamp, kind: kind)
            XCTAssertEqual(try cipher.open(cipher.seal(op, device: device)), op)
        }
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let envelope = try cipher.seal(makeOp(text: "SECRET-MARKER"), device: device)
        XCTAssertNil(envelope.ciphertext.range(of: Data("SECRET-MARKER".utf8)))
    }

    func testTamperedCiphertextFails() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let envelope = try cipher.seal(makeOp(), device: device)
        // Flip one bit in the nonce, the body and the tag in turn.
        for index in [0, 12, envelope.ciphertext.count - 1] {
            var tampered = envelope
            var bytes = [UInt8](tampered.ciphertext)
            bytes[index] ^= 0x01
            tampered.ciphertext = Data(bytes)
            XCTAssertThrowsError(try cipher.open(tampered)) {
                XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
            }
        }
        var truncated = envelope
        truncated.ciphertext = envelope.ciphertext.prefix(10)
        XCTAssertThrowsError(try cipher.open(truncated)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testSwappedItemIDFails() throws {
        let cipher = OpCipher(vaultKey: .generate())
        var envelope = try cipher.seal(makeOp(), device: device)
        envelope.itemID = ItemID().rawValue.uuidString
        XCTAssertThrowsError(try cipher.open(envelope)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testSwappedOpIDFails() throws {
        let cipher = OpCipher(vaultKey: .generate())
        var envelope = try cipher.seal(makeOp(), device: device)
        envelope.opID = OpID().rawValue.uuidString
        XCTAssertThrowsError(try cipher.open(envelope)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testPayloadTransplantedBetweenEnvelopesFails() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let a = try cipher.seal(makeOp(text: "a"), device: device)
        var b = try cipher.seal(makeOp(text: "b"), device: device)
        b.ciphertext = a.ciphertext
        XCTAssertThrowsError(try cipher.open(b)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testDecodedIDsMustMatchEnvelope() throws {
        // A key holder who seals an op under another envelope's IDs (valid AAD, wrong contents)
        // is caught by the ID check after decryption.
        let key = VaultKey.generate()
        let cipher = OpCipher(vaultKey: key)
        let op = makeOp()
        let otherOpID = OpID().rawValue.uuidString
        let plaintext = try OpCipher.makeEncoder().encode(op)
        let box = try AES.GCM.seal(
            plaintext,
            using: key.dataKey,
            authenticating: OpCipher.aad(itemID: op.itemID.rawValue.uuidString, opID: otherOpID)
        )
        let envelope = Envelope(
            opID: otherOpID,
            itemID: op.itemID.rawValue.uuidString,
            deviceID: device.rawValue.uuidString,
            ciphertext: try XCTUnwrap(box.combined)
        )
        XCTAssertThrowsError(try cipher.open(envelope)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .mismatchedEnvelope)
        }
    }

    func testWrongKeyFails() throws {
        let envelope = try OpCipher(vaultKey: .generate()).seal(makeOp(), device: device)
        XCTAssertThrowsError(try OpCipher(vaultKey: .generate()).open(envelope)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testNoncesDifferAcrossSeals() throws {
        let cipher = OpCipher(vaultKey: .generate())
        let op = makeOp()
        let first = try cipher.seal(op, device: device)
        let second = try cipher.seal(op, device: device)
        XCTAssertNotEqual(first.ciphertext.prefix(12), second.ciphertext.prefix(12))
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        XCTAssertEqual(try cipher.open(first), try cipher.open(second))
    }

    func testEncodingSortsKeysAndUsesISO8601Dates() throws {
        let json = try XCTUnwrap(String(data: OpCipher.makeEncoder().encode(makeOp()), encoding: .utf8))
        XCTAssertTrue(json.contains("\"createdAt\":\"2023-11-14T22:13:20.500Z\""), json)
        let id = try XCTUnwrap(json.range(of: "\"id\""))
        let itemID = try XCTUnwrap(json.range(of: "\"itemID\""))
        let timestamp = try XCTUnwrap(json.range(of: "\"timestamp\""))
        XCTAssertLessThan(id.lowerBound, itemID.lowerBound)
        XCTAssertLessThan(itemID.lowerBound, timestamp.lowerBound)
    }
}
