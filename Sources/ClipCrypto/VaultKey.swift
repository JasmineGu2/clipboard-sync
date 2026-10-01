import Crypto
import Foundation

/// The 256-bit secret shared by every device in a vault. See docs/design.md §3.
///
/// The key bytes never appear in `description`, `debugDescription` or `dump()`.
public struct VaultKey: Sendable {
    /// Salt for every HKDF derivation in the protocol.
    static let hkdfSalt = Data("clip.v1".utf8)
    static let byteCount = 32

    // Held as Data because swift-crypto's SymmetricKey is not Sendable; a SymmetricKey is built per use.
    private let bytes: Data

    private init(bytes: Data) {
        self.bytes = bytes
    }

    /// A fresh random 256-bit vault key.
    public static func generate() -> VaultKey {
        VaultKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Rebuilds a vault key from its 32 raw bytes.
    /// - Throws: `CryptoError.invalidKeyLength` unless `rawBytes` is exactly 32 bytes.
    public init(rawBytes: Data) throws {
        guard rawBytes.count == Self.byteCount else { throw CryptoError.invalidKeyLength }
        self.bytes = Data(rawBytes)
    }

    /// The raw key bytes, for a `KeyStore` or for pairing. Handle with care.
    public var rawBytes: Data {
        bytes
    }

    /// Bearer token for the relay: hex(HKDF-SHA256(vault, salt "clip.v1", info "clip.auth.v1", 32 bytes)).
    public var authToken: String {
        derive(info: "clip.auth.v1").withUnsafeBytes { $0.hexString }
    }

    /// hex(SHA-256(UTF-8 of `authToken`)): what the relay stores, and what `--token-sha256` pins.
    /// Safe to show: it identifies the vault to the relay but can't be used as a token.
    public var authTokenSHA256: String {
        SHA256.hash(data: Data(authToken.utf8)).hexString
    }

    /// Encrypts ops: HKDF-SHA256(vault, salt "clip.v1", info "clip.data.v1", 32 bytes).
    var dataKey: SymmetricKey {
        derive(info: "clip.data.v1")
    }

    private func derive(info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: Self.hkdfSalt,
            info: Data(info.utf8),
            outputByteCount: Self.byteCount
        )
    }
}

extension VaultKey: Equatable {
    /// Constant-time comparison (SymmetricKey's == does not short-circuit).
    public static func == (a: VaultKey, b: VaultKey) -> Bool {
        SymmetricKey(data: a.bytes) == SymmetricKey(data: b.bytes)
    }
}

extension VaultKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension Sequence where Element == UInt8 {
    /// Lowercase hex, two characters per byte.
    var hexString: String {
        let digits = Array("0123456789abcdef")
        var out = ""
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }
}
