import Crypto
import Foundation
import XCTest
@testable import ClipCrypto

/// F16: the sealed channel for direct device-to-device sync.
final class PeerChannelTests: XCTestCase {
    let mac = DeviceKey.generate()
    let pc = DeviceKey.generate()
    let vault = VaultKey.generate()

    func seal(_ text: String = "hello", from: String = "MAC", to: String = "PC", sender: DeviceKey? = nil,
              recipient: Data? = nil, vault: VaultKey? = nil) throws -> PeerChannel.SealedRequest {
        try PeerChannel.sealRequest(
            Data(text.utf8), from: from, to: to, deviceKey: sender ?? mac, recipient: recipient ?? pc.publicKey,
            vaultKey: vault ?? self.vault)
    }

    func open(_ request: PeerChannel.SealedRequest, from: String = "MAC", to: String = "PC", me: DeviceKey? = nil,
              sender: Data? = nil, vault: VaultKey? = nil) throws -> (plaintext: Data, responseKey: PeerChannel.ResponseKey) {
        try PeerChannel.openRequest(
            encapsulatedKey: request.encapsulatedKey, ciphertext: request.ciphertext, from: from, to: to,
            deviceKey: me ?? pc, sender: sender ?? mac.publicKey, vaultKey: vault ?? self.vault)
    }

    func testRoundTripBothWays() throws {
        let request = try seal()
        let opened = try open(request)
        XCTAssertEqual(opened.plaintext, Data("hello".utf8))
        let response = try opened.responseKey.seal(Data("answer".utf8))
        XCTAssertEqual(try request.responseKey.open(response), Data("answer".utf8))
        XCTAssertEqual(request.encapsulatedKey.count, PeerChannel.encapsulatedKeyBytes)
    }

    func testOnlyCurrentVaultMembersGetThrough() throws {
        let request = try seal()
        // Another vault key (a device on the key from before a revoke, or a stranger): the PSK differs.
        XCTAssertThrowsError(try open(request, vault: .generate()))
        XCTAssertThrowsError(try open(try seal(vault: .generate())))
        // Someone else's device key claiming to be the Mac: sender authentication fails.
        XCTAssertThrowsError(try open(try seal(sender: .generate())))
        // Not for this device: only the PC's private key opens it.
        XCTAssertThrowsError(try open(request, me: .generate()))
        // Relabelled or reflected: the device IDs are in the HPKE info.
        XCTAssertThrowsError(try open(request, from: "OTHER"))
        XCTAssertThrowsError(try open(request, from: "PC", to: "MAC"))
    }

    func testTamperingFails() throws {
        let request = try seal()
        var ciphertext = Data(request.ciphertext)  // HPKE may hand back a slice; index from 0 on a copy
        ciphertext[0] ^= 1
        XCTAssertThrowsError(try PeerChannel.openRequest(
            encapsulatedKey: request.encapsulatedKey, ciphertext: ciphertext, from: "MAC", to: "PC", deviceKey: pc,
            sender: mac.publicKey, vaultKey: vault))
        XCTAssertThrowsError(try PeerChannel.openRequest(
            encapsulatedKey: Data(count: 31), ciphertext: request.ciphertext, from: "MAC", to: "PC", deviceKey: pc,
            sender: mac.publicKey, vaultKey: vault))
        var response = Data(try open(request).responseKey.seal(Data("answer".utf8)))
        response[response.count - 1] ^= 1
        XCTAssertThrowsError(try request.responseKey.open(response))
    }

    func testEachRequestHasItsOwnResponseKey() throws {
        let first = try seal(), second = try seal()
        XCTAssertNotEqual(first.encapsulatedKey, second.encapsulatedKey)
        let answer = try open(first).responseKey.seal(Data("for the first".utf8))
        XCTAssertThrowsError(try second.responseKey.open(answer))
    }

    /// Computed independently with Python hmac/hashlib (RFC 5869) for the vault key 0x00...0x1f.
    func testPeerPSKKnownAnswer() throws {
        let key = try VaultKey(rawBytes: Data(0..<32))
        XCTAssertEqual(
            key.peerPSK.withUnsafeBytes { $0.hexString },
            "d51e47dea6a82c65f3072cca38824abd3d0eb642389a86af9bcc531a8e0e3904")
    }

    /// RFC 9180 test vector for exactly our suite and mode: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM,
    /// mode_auth_psk (kem 0x20, kdf 1, aead 2, mode 3): first encryption and first export. From the CFRG
    /// test-vectors.json that swift-crypto ships in Tests/CryptoTests/HPKE.
    func testHPKEAuthPSKModeRFC9180Vector() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hex("a494cc9d803df57792c866f6ab716ba8ce953236e3ec71914908cd80fb721c15"))
        XCTAssertEqual(
            privateKey.publicKey.rawRepresentation,
            hex("49823d14040d46e3d405e21f421a810a4968a361bc96c5abcf2f36e66b15a36e"))
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: PeerChannel.ciphersuite,
            info: hex("4f6465206f6e2061204772656369616e2055726e"),
            encapsulatedKey: hex("d38af616e071a4e3717ad1575fc8df781c541b4d0cc02cdf98f2d156a9eda15f"),
            authenticatedBy: try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: hex("f94a4aad51983c18a48a960f2072c14818b9bf1eac2cc4575e32d8d029387a2e")),
            presharedKey: SymmetricKey(data: hex("0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82")),
            presharedKeyIdentifier: hex("456e6e796e20447572696e206172616e204d6f726961"))
        let plaintext = try recipient.open(
            hex("49d13e16bc1f0e45805ac211e0c2e6bf5d436ed00df5f02f16c4c8eaeda0418d3f614636e2f026949bbd6dd281"),
            authenticating: hex("436f756e742d30"))
        XCTAssertEqual(plaintext, hex("4265617574792069732074727574682c20747275746820626561757479"))
        let exported = try recipient.exportSecret(context: Data(), outputByteCount: 32)
        XCTAssertEqual(
            exported.withUnsafeBytes { Data($0) },
            hex("0404bb6afcf9f3a2f8b10e0d2077b7829b5b90d97f799a3ebdefa3772e53137a"))
    }

    private func hex(_ string: String) -> Data {
        var out = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            out.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
