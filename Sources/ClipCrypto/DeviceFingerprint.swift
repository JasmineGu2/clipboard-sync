import Crypto
import Foundation

/// A short, readable fingerprint of a device's public key (F13), shown in the device list so a person can check
/// that each listed device is one of theirs: the fingerprint next to "This device" on a device should match the
/// one shown for it everywhere else. See docs/threat-model.md (decoy devices).
///
/// `SHA-256("clip.device.fingerprint.v1" || publicKey)`, the first 8 bytes as upper-case hex in four groups of four,
/// e.g. `B486 2DD6 CA02 F69F`. 64 bits: matching a chosen device's fingerprint takes about 2^64 key generations,
/// which is out of reach for someone planting a decoy. It is a check for people, not an identifier.
public enum DeviceFingerprint {
    static let domain = Data("clip.device.fingerprint.v1".utf8)
    static let byteCount = 8

    public static func of(publicKey: Data) -> String {
        let digest = SHA256.hash(data: domain + publicKey)
        let hex = Data(digest.prefix(byteCount)).hexString.uppercased()
        return stride(from: 0, to: hex.count, by: 4).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<hex.index(from, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

extension DeviceKey {
    /// This device's own fingerprint, as other devices show it.
    public var fingerprint: String { DeviceFingerprint.of(publicKey: publicKey) }
}
