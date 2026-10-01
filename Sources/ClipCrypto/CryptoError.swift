/// Every failure ClipCrypto reports. Messages never include key material.
public enum CryptoError: Error, Equatable, Sendable {
    /// Key bytes were not exactly 32 bytes.
    case invalidKeyLength
    /// Authentication failed: wrong key, tampered ciphertext, or wrong associated data.
    case decryptionFailed
    /// The decrypted op's IDs differ from the envelope that carried it.
    case mismatchedEnvelope
    /// A pairing code could not be parsed.
    case invalidPairingCode
    /// An op could not be encoded, or decrypted bytes could not be decoded as an op.
    case encodingFailed
}
