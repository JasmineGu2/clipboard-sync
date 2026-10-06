import ClipCore
import Crypto
import Foundation

/// Seals and opens the chunks of one blob (F11, F12). See docs/design.md §6 and docs/threat-model.md.
///
/// Each chunk is AES-256-GCM in combined form (nonce(12) || ciphertext || tag(16)) under a per-blob key
/// (`VaultKey.blobKey(for:)`), with a fresh random nonce and associated data
/// `"clip.blob.v1|<itemID>|<blobID>|<index>|<count>|<size>"`. So a chunk only opens:
/// - under this blob's key and ID (it can't be moved to another blob),
/// - for this item (it can't be moved to another item),
/// - at its own index (no reordering or swapping within the blob),
/// - for a blob of exactly this size and chunk count, which come from the encrypted create op. A receiver
///   asks for all `count` chunks and checks each one's plaintext length, so dropping the tail (truncation)
///   or passing a short final chunk fails, and the whole-file SHA-256 is checked again at the end.
public struct BlobCipher: Sendable {
    public let item: ItemID
    public let blob: BlobRef
    // Raw key bytes: SymmetricKey isn't Sendable.
    private let keyBytes: Data

    /// Bytes a sealed chunk adds to its plaintext: the nonce and the tag.
    public static let overhead = 12 + 16

    public init(vaultKey: VaultKey, item: ItemID, blob: BlobRef) {
        self.item = item
        self.blob = blob
        self.keyBytes = vaultKey.blobKey(for: blob.id).withUnsafeBytes { Data($0) }
    }

    /// Seals chunk `index`. Its plaintext must be exactly `blob.plaintextLength(ofChunk: index)` bytes.
    public func seal(_ plaintext: Data, index: Int) throws -> Data {
        try seal(plaintext, index: index, nonce: AES.GCM.Nonce())
    }

    /// Fixed-nonce seal, for the known-answer test only (same rule as `OpCipher`'s).
    func seal(_ plaintext: Data, index: Int, nonce: AES.GCM.Nonce) throws -> Data {
        guard (0..<blob.chunkCount).contains(index), plaintext.count == blob.plaintextLength(ofChunk: index) else {
            throw CryptoError.invalidChunk
        }
        do {
            let box = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: keyBytes), nonce: nonce, authenticating: aad(index: index))
            guard let combined = box.combined else { throw CryptoError.encodingFailed }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    /// Opens chunk `index` and checks its plaintext length.
    /// - Throws: `CryptoError.decryptionFailed` for a wrong key, blob, item, index, size or a tampered chunk;
    ///   `CryptoError.invalidChunk` for an index out of range or a plaintext of the wrong length.
    public func open(_ sealed: Data, index: Int) throws -> Data {
        guard (0..<blob.chunkCount).contains(index) else { throw CryptoError.invalidChunk }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: aad(index: index))
        } catch {
            throw CryptoError.decryptionFailed
        }
        // The AAD already binds the size; this catches a sender that sealed a chunk of the wrong length.
        guard plaintext.count == blob.plaintextLength(ofChunk: index) else { throw CryptoError.invalidChunk }
        return plaintext
    }

    /// `"clip.blob.v1|<itemID>|<blobID>|<index>|<count>|<size>"` as UTF-8 (UUIDs upper case, decimal numbers).
    func aad(index: Int) -> Data {
        Data("clip.blob.v1|\(item.rawValue.uuidString)|\(blob.id.rawValue.uuidString)|\(index)|\(blob.chunkCount)|\(blob.size)".utf8)
    }
}
