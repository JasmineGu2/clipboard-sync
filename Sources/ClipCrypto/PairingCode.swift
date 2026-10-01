import Crypto
import Foundation

/// A one-time code that moves the vault key to a new device. See docs/design.md §3 (F10).
///
/// 20 random bytes (160 bits) written as 32 Crockford base32 characters, shown in groups of 4.
public struct PairingCode: Sendable, Equatable {
    static let byteCount = 20
    static let length = 32
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The 20 code bytes.
    let bytes: Data
    /// Canonical form: 32 upper-case Crockford characters, no separators.
    public let canonical: String

    private init(bytes: Data) {
        self.bytes = bytes
        self.canonical = Self.encode(bytes)
    }

    public static func generate() -> PairingCode {
        let random = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
        return PairingCode(bytes: random.withUnsafeBytes { Data($0) })
    }

    /// Parses a typed code. Ignores spaces and dashes, accepts lower case, and reads I/L as 1 and O as 0.
    /// Returns nil for the wrong length or any character outside the Crockford alphabet.
    public init?(string: String) {
        var values: [UInt8] = []
        values.reserveCapacity(Self.length)
        for character in string.uppercased() {
            switch character {
            case " ", "-":
                continue
            case "I", "L":
                values.append(1)
            case "O":
                values.append(0)
            default:
                guard let index = Self.alphabet.firstIndex(of: character) else { return nil }
                values.append(UInt8(index))
            }
            if values.count > Self.length { return nil }
        }
        guard values.count == Self.length else { return nil }
        self.init(bytes: Self.decode(values))
    }

    /// Groups of 4 joined with "-", e.g. `ABCD-EFGH-...`.
    public var display: String {
        var groups: [String] = []
        var rest = Substring(canonical)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: "-")
    }

    /// Relay mailbox ID: the first 32 hex chars of SHA256("clip.pair.id|" + canonical code).
    public var pairingID: String {
        String(SHA256.hash(data: Data("clip.pair.id|\(canonical)".utf8)).hexString.prefix(32))
    }

    /// Seals the vault key for the relay: AES.GCM combined form under the wrap key, AAD = pairingID.
    public func wrap(_ key: VaultKey) throws -> Data {
        do {
            let box = try AES.GCM.seal(key.rawBytes, using: wrapKey, authenticating: Data(pairingID.utf8))
            guard let combined = box.combined else { throw CryptoError.encodingFailed }
            return combined
        } catch {
            throw CryptoError.encodingFailed
        }
    }

    /// Opens a blob made by `wrap` with the same code.
    /// - Throws: `CryptoError.decryptionFailed` for a wrong code or a tampered blob.
    public func unwrap(_ blob: Data) throws -> VaultKey {
        let raw: Data
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            raw = try AES.GCM.open(box, using: wrapKey, authenticating: Data(pairingID.utf8))
        } catch {
            throw CryptoError.decryptionFailed
        }
        return try VaultKey(rawBytes: raw)
    }

    /// HKDF-SHA256(code bytes, salt "clip.v1", info "clip.pair.wrap.v1", 32 bytes).
    var wrapKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: VaultKey.hkdfSalt,
            info: Data("clip.pair.wrap.v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Crockford base32 (exactly 160 bits <-> 32 symbols, no padding)

    private static func encode(_ bytes: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1f)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return out
    }

    private static func decode(_ values: [UInt8]) -> Data {
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for value in values {
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return out
    }
}

extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "PairingCode(<redacted>)" }
    public var debugDescription: String { description }
    /// No children, so `dump` and debugger views never show the bytes or the canonical string.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
