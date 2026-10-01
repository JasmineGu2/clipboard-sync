import ClipCore
import ClipWire
import Crypto
import Foundation

/// Seals ops into envelopes and opens them again. See docs/design.md §3.
///
/// Ciphertext is AES-256-GCM (combined form: nonce || ciphertext || tag) under the vault's data key,
/// with associated data `"clip.op.v1|<itemID>|<opID>"`, so a payload can't be moved to another envelope.
public struct OpCipher: Sendable {
    private let vaultKey: VaultKey

    public init(vaultKey: VaultKey) {
        self.vaultKey = vaultKey
    }

    public func seal(_ op: Op, device: DeviceID) throws -> Envelope {
        let opID = op.id.rawValue.uuidString
        let itemID = op.itemID.rawValue.uuidString
        let dataKey = vaultKey.dataKey
        let plaintext: Data
        do {
            plaintext = try Self.makeEncoder().encode(op)
        } catch {
            throw CryptoError.encodingFailed
        }
        let combined: Data
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: dataKey,
                nonce: AES.GCM.Nonce(),
                authenticating: Self.aad(itemID: itemID, opID: opID)
            )
            guard let bytes = box.combined else { throw CryptoError.encodingFailed }
            combined = bytes
        } catch {
            throw CryptoError.encodingFailed
        }
        return Envelope(opID: opID, itemID: itemID, deviceID: device.rawValue.uuidString, ciphertext: combined)
    }

    public func open(_ envelope: Envelope) throws -> Op {
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            plaintext = try AES.GCM.open(
                box,
                using: vaultKey.dataKey,
                authenticating: Self.aad(itemID: envelope.itemID, opID: envelope.opID)
            )
        } catch {
            throw CryptoError.decryptionFailed
        }
        let op: Op
        do {
            op = try Self.makeDecoder().decode(Op.self, from: plaintext)
        } catch {
            throw CryptoError.encodingFailed
        }
        guard op.id.rawValue.uuidString == envelope.opID,
              op.itemID.rawValue.uuidString == envelope.itemID
        else { throw CryptoError.mismatchedEnvelope }
        return op
    }

    /// `"clip.op.v1|<itemID>|<opID>"` as UTF-8.
    static func aad(itemID: String, opID: String) -> Data {
        Data("clip.op.v1|\(itemID)|\(opID)".utf8)
    }

    // MARK: - Op encoding

    // One shared encoding with ClipStore; see ClipCoding for why dates are integer milliseconds.
    static func makeEncoder() -> JSONEncoder { ClipCoding.makeEncoder() }
    static func makeDecoder() -> JSONDecoder { ClipCoding.makeDecoder() }
}
