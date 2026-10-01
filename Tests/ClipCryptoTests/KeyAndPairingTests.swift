import Foundation
import XCTest
@testable import ClipCrypto

final class VaultKeyTests: XCTestCase {
    func testGenerateIsRandom32Bytes() {
        let a = VaultKey.generate()
        let b = VaultKey.generate()
        XCTAssertEqual(a.rawBytes.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.authToken, b.authToken)
    }

    func testRawBytesRoundTrip() throws {
        let key = VaultKey.generate()
        let copy = try VaultKey(rawBytes: key.rawBytes)
        XCTAssertEqual(copy, key)
        XCTAssertEqual(copy.authToken, key.authToken)
    }

    func testWrongLengthRejected() {
        for count in [0, 16, 31, 33, 64] {
            XCTAssertThrowsError(try VaultKey(rawBytes: Data(repeating: 7, count: count))) {
                XCTAssertEqual($0 as? CryptoError, .invalidKeyLength)
            }
        }
    }

    func testAuthTokenIsLowercaseHex() {
        let token = VaultKey.generate().authToken
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testDescriptionRedactsKey() throws {
        let key = try VaultKey(rawBytes: Data((0..<32).map { UInt8($0) }))
        let hex = key.rawBytes.hexString
        var dumped = ""
        dump(key, to: &dumped)
        for text in [key.description, key.debugDescription, String(describing: key), String(reflecting: key), "\(key)", dumped] {
            XCTAssertFalse(text.lowercased().contains(hex), text)
            XCTAssertFalse(text.lowercased().contains(hex.prefix(16)), text)
        }
    }
}

final class PairingCodeTests: XCTestCase {
    // Bytes 0x00...0x13 in Crockford base32, and its pairing ID (computed independently in Python).
    private let knownCode = "000G40R40M30E209185GR38E1W8124GK"
    private let knownPairingID = "d94fab87dae7d3d0ca2140ff2adb4242"

    func testGenerateShape() {
        let code = PairingCode.generate()
        XCTAssertEqual(code.canonical.count, 32)
        XCTAssertEqual(code.bytes.count, 20)
        XCTAssertNotEqual(code, PairingCode.generate())
        XCTAssertEqual(code.display.count, 32 + 7)
        XCTAssertEqual(code.display.split(separator: "-").map(\.count), Array(repeating: 4, count: 8))
        XCTAssertEqual(code.pairingID.count, 32)
        XCTAssertEqual(PairingCode(string: code.display), code)
        XCTAssertEqual(PairingCode(string: code.canonical), code)
    }

    func testKnownCode() throws {
        let code = try XCTUnwrap(PairingCode(string: knownCode))
        XCTAssertEqual(code.bytes, Data((0..<20).map { UInt8($0) }))
        XCTAssertEqual(code.canonical, knownCode)
        XCTAssertEqual(code.display, "000G-40R4-0M30-E209-185G-R38E-1W81-24GK")
        XCTAssertEqual(code.pairingID, knownPairingID)
    }

    func testNormalization() throws {
        let canonical = try XCTUnwrap(PairingCode(string: knownCode))
        let typed = [
            knownCode.lowercased(),
            "000g-40r4-0m30-e209-185g-r38e-1w81-24gk",
            "oOog-4Or4 0m3o-e2O9-l85g r38e-iw8L-24gk",
            "  000G 40R4 0M30 E209 185G R38E 1W81 24GK  ",
        ]
        for string in typed {
            XCTAssertEqual(PairingCode(string: string), canonical, string)
            XCTAssertEqual(PairingCode(string: string)?.pairingID, knownPairingID, string)
        }
    }

    func testInvalidCodesRejected() {
        let invalid = [
            "",
            String(knownCode.dropLast()),        // 31 chars
            knownCode + "0",                     // 33 chars
            "U" + knownCode.dropFirst(),         // U is not in the Crockford alphabet
            "*" + knownCode.dropFirst(),
            "É" + knownCode.dropFirst(),
        ]
        for string in invalid {
            XCTAssertNil(PairingCode(string: string), string)
        }
    }

    func testWrapUnwrapRoundTrip() throws {
        let key = VaultKey.generate()
        let sender = PairingCode.generate()
        let blob = try sender.wrap(key)
        XCTAssertNil(blob.range(of: key.rawBytes))

        // The new device types the code by hand.
        let receiver = try XCTUnwrap(PairingCode(string: sender.display.lowercased()))
        XCTAssertEqual(receiver.pairingID, sender.pairingID)
        XCTAssertEqual(try receiver.unwrap(blob), key)
    }

    func testWrongCodeFailsToUnwrap() throws {
        let blob = try PairingCode.generate().wrap(.generate())
        XCTAssertThrowsError(try PairingCode.generate().unwrap(blob)) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testTamperedBlobFailsToUnwrap() throws {
        let code = PairingCode.generate()
        var bytes = [UInt8](try code.wrap(.generate()))
        bytes[bytes.count - 1] ^= 0x80
        XCTAssertThrowsError(try code.unwrap(Data(bytes))) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testDescriptionRedactsCode() {
        let code = PairingCode.generate()
        XCTAssertFalse(String(describing: code).contains(code.canonical))
    }
}

final class InMemoryKeyStoreTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try store.loadVaultKey())
        let key = VaultKey.generate()
        try store.saveVaultKey(key)
        XCTAssertEqual(try store.loadVaultKey(), key)
        try store.deleteVaultKey()
        XCTAssertNil(try store.loadVaultKey())
    }

    func testConcurrentAccess() async throws {
        let store = InMemoryKeyStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try store.saveVaultKey(.generate())
                    _ = try store.loadVaultKey()
                }
            }
            try await group.waitForAll()
        }
        XCTAssertNotNil(try store.loadVaultKey())
    }
}
