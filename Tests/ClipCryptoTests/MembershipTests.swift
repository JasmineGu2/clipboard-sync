import ClipWire
import Crypto
import Foundation
import XCTest
@testable import ClipCrypto

/// F13: device keys, sealed device records and rekey handoffs. Known answers for the new derivations and the
/// HPKE suite, then round trips and every way a record or handoff must fail to open.
final class MembershipTests: XCTestCase {
    private let fixedKeyBytes = Data((0..<32).map { UInt8($0) })

    private func data(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    // MARK: - Known answers

    /// Computed independently with Python hmac/hashlib (RFC 5869) for the vault key 0x00...0x1f.
    func testDirectoryKeyKnownAnswer() throws {
        let key = try VaultKey(rawBytes: fixedKeyBytes)
        XCTAssertEqual(
            key.directoryKey.withUnsafeBytes { $0.hexString },
            "3f324bed31564529750a29fd36edf2b32a184a0db5b7b73462fb94f7421a8668")
    }

    /// Computed independently with Python hmac/hashlib (RFC 5869) for the vault key 0x00...0x1f.
    func testRekeyPSKKnownAnswer() throws {
        let key = try VaultKey(rawBytes: fixedKeyBytes)
        XCTAssertEqual(
            key.rekeyPSK.withUnsafeBytes { $0.hexString },
            "db0befe325921696e2ebc97e5305012ec53c53a567a1b1b8854a9bcf196f063a")
    }

    /// RFC 9180 test vector for exactly our suite and mode: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
    /// AES-256-GCM, mode_psk (kem 0x20, kdf 1, aead 2, mode 1), first encryption. From the CFRG test-vectors.json
    /// that swift-crypto ships in Tests/CryptoTests/HPKE.
    func testHPKEPSKModeRFC9180Vector() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: data("d99132243a09c24a7497f3da8608f0ba808c21a575d33679f4b24603e96d27ad"))
        XCTAssertEqual(
            privateKey.publicKey.rawRepresentation,
            data("62a61ceb338540516edde460e27923a8df6749bc38e27b1001cd5b8b9102e44c"))
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: RekeyHandoff.ciphersuite,
            info: data("4f6465206f6e2061204772656369616e2055726e"),
            encapsulatedKey: data("4f3e44d4dde1d0d12a724242df8cef0a68ea53617dab8a6aade4239d404a5154"),
            presharedKey: SymmetricKey(data: data("0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82")),
            presharedKeyIdentifier: data("456e6e796e20447572696e206172616e204d6f726961"))
        let plaintext = try recipient.open(
            data("316d9b4214a33182212888e86f23005b0706c30db2b1052c4e28c2c100fcdb85cc934b0a64c8db0d7dd339b64c"),
            authenticating: data("436f756e742d30"))
        XCTAssertEqual(plaintext, data("4265617574792069732074727574682c20747275746820626561757479"))
    }

    // MARK: - Device key

    func testDeviceKeyRoundTripsAndIsRedacted() throws {
        let key = DeviceKey.generate()
        XCTAssertEqual(try DeviceKey(rawBytes: key.rawBytes), key)
        XCTAssertEqual(key.publicKey.count, 32)
        XCTAssertNotEqual(DeviceKey.generate(), key)
        XCTAssertThrowsError(try DeviceKey(rawBytes: Data(count: 31)))

        let hex = key.rawBytes.hexString
        var dumped = ""
        dump(key, to: &dumped)
        for text in [key.description, key.debugDescription, "\(key)", dumped] {
            XCTAssertFalse(text.contains(hex), text)
        }
    }

    func testInMemoryKeyStoreCreatesTheDeviceKeyOnce() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try store.loadDeviceKey())
        let first = try store.loadOrCreateDeviceKey()
        XCTAssertEqual(try store.loadOrCreateDeviceKey(), first)
        XCTAssertEqual(try store.loadDeviceKey(), first)
    }

    // MARK: - Device records

    func testDeviceRecordRoundTrip() throws {
        let vault = VaultKey.generate()
        let device = DeviceKey.generate()
        let record = try DeviceDirectory.seal(
            deviceID: "dev-1", publicKey: device.publicKey, info: DeviceInfo(name: "Desk PC"), vaultKey: vault)
        XCTAssertEqual(record.deviceID, "dev-1")
        XCTAssertEqual(record.publicKey, device.publicKey)
        XCTAssertFalse(String(decoding: record.sealed, as: UTF8.self).contains("Desk PC"))
        XCTAssertEqual(try DeviceDirectory.open(record, vaultKey: vault), DeviceInfo(name: "Desk PC"))
    }

    /// The relay can't swap the public key or move a record to another device ID, and an old vault key's record
    /// doesn't open under the new one.
    func testDeviceRecordRejectsTamperingAndOtherVaults() throws {
        let vault = VaultKey.generate()
        let record = try DeviceDirectory.seal(
            deviceID: "dev-1", publicKey: DeviceKey.generate().publicKey, info: DeviceInfo(name: "Mac"),
            vaultKey: vault)

        var swappedKey = record
        swappedKey.publicKey = DeviceKey.generate().publicKey
        var movedID = record
        movedID.deviceID = "dev-2"
        var flipped = record
        flipped.sealed[flipped.sealed.count - 1] ^= 1
        var shortKey = record
        shortKey.publicKey = Data(record.publicKey.prefix(31))

        for bad in [swappedKey, movedID, flipped, shortKey] {
            XCTAssertThrowsError(try DeviceDirectory.open(bad, vaultKey: vault)) {
                XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
            }
        }
        XCTAssertThrowsError(try DeviceDirectory.open(record, vaultKey: VaultKey.generate()))
    }

    // MARK: - Handoffs

    func testHandoffRoundTrip() throws {
        let old = VaultKey.generate()
        let new = VaultKey.generate()
        let device = DeviceKey.generate()
        let blob = try RekeyHandoff.seal(newKey: new, toPublicKey: device.publicKey, deviceID: "dev-1", oldKey: old)
        XCTAssertEqual(blob.count, 32 + 32 + 16, "encapsulated key + sealed vault key + tag")
        XCTAssertEqual(try RekeyHandoff.open(blob, deviceKey: device, deviceID: "dev-1", currentKey: old), new)
        // Fresh ephemeral key each time.
        XCTAssertNotEqual(
            try RekeyHandoff.seal(newKey: new, toPublicKey: device.publicKey, deviceID: "dev-1", oldKey: old), blob)
    }

    /// The lost device has the old vault key but not the recipient's private key; the relay has neither.
    func testHandoffOnlyOpensForItsDeviceWithTheOldVaultKey() throws {
        let old = VaultKey.generate()
        let new = VaultKey.generate()
        let device = DeviceKey.generate()
        let blob = try RekeyHandoff.seal(newKey: new, toPublicKey: device.publicKey, deviceID: "dev-1", oldKey: old)

        // Another device's private key (the lost device's own key).
        XCTAssertThrowsError(try RekeyHandoff.open(blob, deviceKey: .generate(), deviceID: "dev-1", currentKey: old))
        // Right private key, wrong PSK: someone without the old vault key (the relay) made it, or it's stale.
        XCTAssertThrowsError(try RekeyHandoff.open(blob, deviceKey: device, deviceID: "dev-1", currentKey: new))
        // Made for another device ID.
        XCTAssertThrowsError(try RekeyHandoff.open(blob, deviceKey: device, deviceID: "dev-2", currentKey: old))
        // Tampered or truncated.
        var flipped = blob
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try RekeyHandoff.open(flipped, deviceKey: device, deviceID: "dev-1", currentKey: old))
        XCTAssertThrowsError(
            try RekeyHandoff.open(blob.prefix(32), deviceKey: device, deviceID: "dev-1", currentKey: old))
    }

    /// A blob the relay made itself, with a key of its choosing, doesn't open: it lacks the PSK.
    func testRelayCannotForgeAHandoff() throws {
        let old = VaultKey.generate()
        let device = DeviceKey.generate()
        let forged = try RekeyHandoff.seal(
            newKey: .generate(), toPublicKey: device.publicKey, deviceID: "dev-1", oldKey: .generate())
        XCTAssertThrowsError(try RekeyHandoff.open(forged, deviceKey: device, deviceID: "dev-1", currentKey: old)) {
            XCTAssertEqual($0 as? ClipCrypto.CryptoError, .decryptionFailed)
        }
    }

    func testSealingToAnInvalidPublicKeyFails() {
        XCTAssertThrowsError(try RekeyHandoff.seal(
            newKey: .generate(), toPublicKey: Data(count: 5), deviceID: "dev-1", oldKey: .generate()))
    }
}
