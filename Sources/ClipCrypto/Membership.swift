import ClipWire
import Crypto
import Foundation

/// What a device record says, once opened.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    /// When the device joined the vault, as the device itself reports it (whole milliseconds). nil from devices
    /// that predate it. Sealed like the name, so the relay can't change it, but any vault member could write any
    /// date: it's a hint for spotting a decoy, the key fingerprint is the check (docs/threat-model.md).
    public var joinedAt: Date?

    public init(name: String, joinedAt: Date? = nil) {
        self.name = name
        self.joinedAt = joinedAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 * 1000).rounded(.down) / 1000) }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        /// Unix milliseconds, so every platform's default JSON coder reads it the same way.
        case joinedMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        joinedAt = try container.decodeIfPresent(Int64.self, forKey: .joinedMillis)
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(joinedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }, forKey: .joinedMillis)
    }
}

/// Seals and opens device records (the vault's device list on the relay). See docs/design.md §3 (F13).
///
/// A record carries the device's public key in the clear and its name sealed with AES-256-GCM under
/// `HKDF(vault, info "clip.device.v1")`, with associated data `"clip.device.v1|<deviceID>|<hex public key>"`.
/// The relay can't read the name, and it can't swap in a public key of its own: the record would stop opening.
/// That matters because a revoke hands the new vault key to every listed public key.
public enum DeviceDirectory {
    public static func seal(
        deviceID: String, publicKey: Data, info: DeviceInfo, vaultKey: VaultKey
    ) throws -> DeviceRecord {
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(info)
        } catch {
            throw CryptoError.encodingFailed
        }
        do {
            let box = try AES.GCM.seal(
                plaintext, using: vaultKey.directoryKey,
                authenticating: aad(deviceID: deviceID, publicKey: publicKey))
            guard let combined = box.combined else { throw CryptoError.encodingFailed }
            return DeviceRecord(deviceID: deviceID, publicKey: publicKey, sealed: combined)
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    /// - Throws: `CryptoError.decryptionFailed` when the record wasn't sealed under this vault key for this
    ///   device ID and public key.
    public static func open(_ record: DeviceRecord, vaultKey: VaultKey) throws -> DeviceInfo {
        guard record.publicKey.count == WireLimits.devicePublicKeyBytes else { throw CryptoError.decryptionFailed }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: record.sealed)
            plaintext = try AES.GCM.open(
                box, using: vaultKey.directoryKey,
                authenticating: aad(deviceID: record.deviceID, publicKey: record.publicKey))
        } catch {
            throw CryptoError.decryptionFailed
        }
        do {
            return try JSONDecoder().decode(DeviceInfo.self, from: plaintext)
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    static func aad(deviceID: String, publicKey: Data) -> Data {
        Data("clip.device.v1|\(deviceID)|\(publicKey.hexString)".utf8)
    }
}

/// Hands a new vault key to one remaining device during a revoke (F13). See docs/design.md §3.
///
/// HPKE (RFC 9180) in PSK mode, ciphersuite DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM:
/// - recipient: the device's X25519 public key, so only that device can open it (not the lost device);
/// - PSK: `HKDF(old vault key, info "clip.rekey.psk.v1")`, PSK ID `"clip.rekey.v1"`, so only a holder of the old
///   vault key can make one (not the relay, which could otherwise slip a device a key of its own choosing);
/// - info: `"clip.rekey.v1|<deviceID>"`, so a blob made for one device doesn't open as another's.
/// The blob is the encapsulated key (32 bytes) followed by the sealed new vault key.
public enum RekeyHandoff {
    static var ciphersuite: HPKE.Ciphersuite { HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256) }
    static let pskID = Data("clip.rekey.v1".utf8)
    static let aad = Data("clip.rekey.v1".utf8)
    static let encapsulatedKeyBytes = 32

    public static func seal(
        newKey: VaultKey, toPublicKey recipient: Data, deviceID: String, oldKey: VaultKey
    ) throws -> Data {
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient)
            var sender = try HPKE.Sender(
                recipientKey: publicKey, ciphersuite: ciphersuite, info: info(deviceID: deviceID),
                presharedKey: oldKey.rekeyPSK, presharedKeyIdentifier: pskID)
            let ciphertext = try sender.seal(newKey.rawBytes, authenticating: aad)
            return sender.encapsulatedKey + ciphertext
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    /// Opens a handoff meant for this device, made by someone holding `currentKey`.
    /// - Throws: `CryptoError.decryptionFailed` for a blob made for another device, under another vault key,
    ///   or tampered with.
    public static func open(
        _ blob: Data, deviceKey: DeviceKey, deviceID: String, currentKey: VaultKey
    ) throws -> VaultKey {
        guard blob.count > encapsulatedKeyBytes else { throw CryptoError.decryptionFailed }
        let raw: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: deviceKey.privateKey, ciphersuite: ciphersuite, info: info(deviceID: deviceID),
                encapsulatedKey: Data(blob.prefix(encapsulatedKeyBytes)),
                presharedKey: currentKey.rekeyPSK, presharedKeyIdentifier: pskID)
            raw = try recipient.open(Data(blob.dropFirst(encapsulatedKeyBytes)), authenticating: aad)
        } catch {
            throw CryptoError.decryptionFailed
        }
        return try VaultKey(rawBytes: raw)
    }

    static func info(deviceID: String) -> Data {
        Data("clip.rekey.v1|\(deviceID)".utf8)
    }
}
