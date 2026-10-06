import Crypto
import Foundation

/// Seals one direct device-to-device exchange (F16). See docs/design.md §7.
///
/// The request is HPKE (RFC 9180) in AuthPSK mode, ciphersuite DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
/// AES-256-GCM:
/// - recipient: the responding device's X25519 public key, so only that device can open it;
/// - sender authentication: the requesting device's own X25519 key (the F13 device key), so the responder knows
///   which vault device sent it, and a device that isn't in its device list can't;
/// - PSK: `HKDF(vault key, info "clip.peer.psk.v1")`, PSK ID `"clip.peer.v1"`, so both sides must hold the
///   current vault key. A revoked device, or one on a vault key from before a revoke, can't make or open one;
/// - info: `"clip.peer.v1|<from deviceID>|<to deviceID>"`, so a request can't be redirected or reflected.
///
/// The response is AES-256-GCM under a key exported from the request's HPKE context (`exportSecret`, context
/// `"clip.peer.response.v1"`), with a random nonce and the same IDs as associated data. Each request has a fresh
/// ephemeral key, so each response key is new: an old response can't be replayed to a later request, and only
/// the device that sent the request (and the one that answered) can read it.
///
/// Replay of a request is caught by the responder (timestamp window and a cache of seen encapsulated keys, in
/// ClipSync); a replayed request would only re-deliver ops, which is harmless (N13), and its answer is sealed to
/// the original sender's request key.
public enum PeerChannel {
    static var ciphersuite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
    }
    static let pskID = Data("clip.peer.v1".utf8)
    static let responseContext = Data("clip.peer.response.v1".utf8)
    public static let encapsulatedKeyBytes = 32

    /// A sealed request and the key its response will come back under.
    public struct SealedRequest: Sendable {
        /// The HPKE encapsulated key (32 bytes). Also the request's identity for replay checks.
        public let encapsulatedKey: Data
        public let ciphertext: Data
        /// Opens the response to this request.
        public let responseKey: ResponseKey
    }

    /// The per-request key responses are sealed under. Held as bytes because SymmetricKey isn't Sendable.
    public struct ResponseKey: Sendable {
        let bytes: Data
        let aad: Data

        init(_ key: SymmetricKey, aad: Data) {
            bytes = key.withUnsafeBytes { Data($0) }
            self.aad = aad
        }

        public func seal(_ plaintext: Data) throws -> Data {
            do {
                guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: bytes), authenticating: aad)
                    .combined else { throw CryptoError.encodingFailed }
                return combined
            } catch {
                throw CryptoError.encodingFailed
            }
        }

        /// - Throws: `CryptoError.decryptionFailed` for a response to another request, or one tampered with.
        public func open(_ sealed: Data) throws -> Data {
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: bytes), authenticating: aad)
            } catch {
                throw CryptoError.decryptionFailed
            }
        }
    }

    /// Seals `plaintext` from this device (`from`, holding `deviceKey`) to the device `to` with public key
    /// `recipient`, under the current vault key.
    public static func sealRequest(
        _ plaintext: Data, from: String, to: String, deviceKey: DeviceKey, recipient: Data, vaultKey: VaultKey
    ) throws -> SealedRequest {
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient)
            var sender = try HPKE.Sender(
                recipientKey: publicKey, ciphersuite: ciphersuite, info: info(from: from, to: to),
                authenticatedBy: deviceKey.privateKey, presharedKey: vaultKey.peerPSK, presharedKeyIdentifier: pskID)
            let ciphertext = try sender.seal(plaintext, authenticating: info(from: from, to: to))
            let exported = try sender.exportSecret(context: responseContext, outputByteCount: 32)
            return SealedRequest(
                encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext,
                responseKey: ResponseKey(exported, aad: responseAAD(from: from, to: to)))
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    /// Opens a request sent to this device (`to`, holding `deviceKey`) by the device `from` with public key
    /// `sender`. Returns the plaintext and the key to seal the response under.
    /// - Throws: `CryptoError.decryptionFailed` unless the request was made by `sender`'s private key, for this
    ///   device's key, under this vault key, between these two device IDs, and not tampered with.
    public static func openRequest(
        encapsulatedKey: Data, ciphertext: Data, from: String, to: String, deviceKey: DeviceKey, sender: Data,
        vaultKey: VaultKey
    ) throws -> (plaintext: Data, responseKey: ResponseKey) {
        guard encapsulatedKey.count == encapsulatedKeyBytes else { throw CryptoError.decryptionFailed }
        do {
            let senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sender)
            var recipient = try HPKE.Recipient(
                privateKey: deviceKey.privateKey, ciphersuite: ciphersuite, info: info(from: from, to: to),
                encapsulatedKey: encapsulatedKey, authenticatedBy: senderKey,
                presharedKey: vaultKey.peerPSK, presharedKeyIdentifier: pskID)
            let plaintext = try recipient.open(ciphertext, authenticating: info(from: from, to: to))
            let exported = try recipient.exportSecret(context: responseContext, outputByteCount: 32)
            return (plaintext, ResponseKey(exported, aad: responseAAD(from: from, to: to)))
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    static func info(from: String, to: String) -> Data {
        Data("clip.peer.v1|\(from)|\(to)".utf8)
    }

    static func responseAAD(from: String, to: String) -> Data {
        Data("clip.peer.response.v1|\(from)|\(to)".utf8)
    }
}
