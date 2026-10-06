import Crypto
import Foundation

/// A device's own X25519 key pair (F13). Made once per device and kept in its `KeyStore` next to the vault key.
/// It never leaves the device. Other devices see only the public key, which lets them hand this device a new
/// vault key when a lost device is revoked, in a way the lost device can't open. See docs/design.md §3.
///
/// The private key bytes never appear in `description`, `debugDescription` or `dump()`.
public struct DeviceKey: Sendable {
    static let byteCount = 32

    // Raw bytes because swift-crypto's private key types are not Sendable; a key object is built per use.
    private let bytes: Data

    private init(bytes: Data) {
        self.bytes = bytes
    }

    public static func generate() -> DeviceKey {
        DeviceKey(bytes: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    /// Rebuilds a device key from its 32 raw private-key bytes.
    /// - Throws: `CryptoError.invalidKeyLength` unless `rawBytes` is a valid 32-byte X25519 private key.
    public init(rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount,
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawBytes)) != nil
        else { throw CryptoError.invalidKeyLength }
        self.bytes = Data(rawBytes)
    }

    /// The raw private key, for a `KeyStore`. Handle with care.
    public var rawBytes: Data { bytes }

    /// The 32-byte X25519 public key. Safe to share.
    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    var privateKey: Curve25519.KeyAgreement.PrivateKey {
        // `init(rawBytes:)` and `generate()` only ever store bytes that parse.
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
    }
}

extension DeviceKey: Equatable {
    /// Constant-time comparison.
    public static func == (a: DeviceKey, b: DeviceKey) -> Bool {
        SymmetricKey(data: a.bytes) == SymmetricKey(data: b.bytes)
    }
}

extension DeviceKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "DeviceKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
