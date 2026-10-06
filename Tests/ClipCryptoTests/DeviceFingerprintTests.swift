import Foundation
import XCTest
@testable import ClipCrypto

/// The device-list fingerprint and the join date sealed in a device record (F13, decoy spotting).
final class DeviceFingerprintTests: XCTestCase {
    /// Computed independently with Python: `hashlib.sha256(b"clip.device.fingerprint.v1" + pk).hexdigest()[:16]`.
    func testKnownAnswers() {
        XCTAssertEqual(DeviceFingerprint.of(publicKey: Data((0..<32).map { UInt8($0) })), "B486 2DD6 CA02 F69F")
        // The RFC 9180 X25519 public key used in MembershipTests.
        let rfcKey = Data([
            0x62, 0xa6, 0x1c, 0xeb, 0x33, 0x85, 0x40, 0x51, 0x6e, 0xdd, 0xe4, 0x60, 0xe2, 0x79, 0x23, 0xa8,
            0xdf, 0x67, 0x49, 0xbc, 0x38, 0xe2, 0x7b, 0x10, 0x01, 0xcd, 0x5b, 0x8b, 0x91, 0x02, 0xe4, 0x4c,
        ])
        XCTAssertEqual(DeviceFingerprint.of(publicKey: rfcKey), "866E 2906 DC9A 9BAD")
    }

    func testShapeAndDeviceKeyHelper() {
        let key = DeviceKey.generate()
        let fingerprint = key.fingerprint
        XCTAssertEqual(fingerprint, DeviceFingerprint.of(publicKey: key.publicKey))
        XCTAssertEqual(fingerprint.count, 19)
        XCTAssertEqual(fingerprint.split(separator: " ").map(\.count), [4, 4, 4, 4])
        XCTAssertNotEqual(fingerprint, DeviceKey.generate().fingerprint)
    }

    func testJoinDateRoundTripsThroughASealedRecord() throws {
        let vault = VaultKey.generate()
        let device = DeviceKey.generate()
        let joined = Date(timeIntervalSince1970: 1_790_000_000.1234)
        let record = try DeviceDirectory.seal(
            deviceID: "A", publicKey: device.publicKey, info: DeviceInfo(name: "Mac", joinedAt: joined), vaultKey: vault)
        let opened = try DeviceDirectory.open(record, vaultKey: vault)
        XCTAssertEqual(opened.name, "Mac")
        // Whole milliseconds, like every other synced date.
        XCTAssertEqual(opened.joinedAt?.timeIntervalSince1970 ?? 0, 1_790_000_000.123, accuracy: 0.0005)
    }

    func testRecordsWithoutAJoinDateStillOpen() throws {
        // What a device from before join dates sealed, and what it reads from a newer one.
        let legacy = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"name":"Old PC"}"#.utf8))
        XCTAssertEqual(legacy, DeviceInfo(name: "Old PC"))
        XCTAssertNil(legacy.joinedAt)
        struct OldDeviceInfo: Codable { var name: String }
        let newer = try JSONEncoder().encode(DeviceInfo(name: "Mac", joinedAt: Date()))
        XCTAssertEqual(try JSONDecoder().decode(OldDeviceInfo.self, from: newer).name, "Mac")
    }
    /// Name, join date (F13) and peer address (F16) all survive a sealed record, under their wire keys.
    func testNameJoinDateAndPeerRoundTrip() throws {
        let vault = VaultKey.generate()
        let joined = Date(timeIntervalSince1970: 1_790_000_000.5)
        let info = DeviceInfo(name: "Mac", joinedAt: joined, peer: "100.64.0.7:8790")
        let record = try DeviceDirectory.seal(
            deviceID: "A", publicKey: DeviceKey.generate().publicKey, info: info, vaultKey: vault)
        XCTAssertEqual(try DeviceDirectory.open(record, vaultKey: vault), info)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "Mac")
        XCTAssertEqual(json?["joinedMillis"] as? Int64, 1_790_000_000_500)
        XCTAssertEqual(json?["peer"] as? String, "100.64.0.7:8790")
        XCTAssertEqual(json?.count, 3)
        // Absent fields are left out, not written as null.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(DeviceInfo(name: "PC")), as: UTF8.self), #"{"name":"PC"}"#)
    }

    /// Records sealed by older clients: no join date and no peer (before both), or only one of them (a t33
    /// client from before join dates wrote `peer` alone; a t34 client wrote `joinedMillis` alone).
    func testRecordsMissingJoinDateOrPeerStillDecode() throws {
        let neither = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"name":"Old PC"}"#.utf8))
        XCTAssertEqual(neither, DeviceInfo(name: "Old PC"))
        XCTAssertNil(neither.joinedAt)
        XCTAssertNil(neither.peer)
        let peerOnly = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"name":"Mac","peer":"100.64.0.7:8790"}"#.utf8))
        XCTAssertEqual(peerOnly, DeviceInfo(name: "Mac", peer: "100.64.0.7:8790"))
        let dateOnly = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"name":"Mac","joinedMillis":1000}"#.utf8))
        XCTAssertEqual(dateOnly, DeviceInfo(name: "Mac", joinedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertNil(dateOnly.peer)
    }
}
