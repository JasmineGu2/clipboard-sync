import ClipCrypto
import Foundation

extension SyncEngine {
    /// On the existing device: makes a one-time code and parks the wrapped vault key on the relay.
    /// Show `code.display` to the user; it's valid for 10 minutes and works once.
    public static func startPairing(vaultKey: VaultKey, transport: any SyncTransport) async throws -> PairingCode {
        let code = PairingCode.generate()
        try await transport.putPairing(id: code.pairingID, blob: try code.wrap(vaultKey))
        return code
    }

    /// On the new device: fetches the blob for a typed code and unwraps the vault key.
    /// - Throws: `SyncError.invalidPairingCode`, `.pairingNotFound` (wrong, used or expired code),
    ///   `.pairingDecryptionFailed`, or a `TransportError` for network trouble.
    public static func completePairing(code: String, transport: any SyncTransport) async throws -> VaultKey {
        guard let parsed = PairingCode(string: code) else { throw SyncError.invalidPairingCode }
        let blob: Data?
        do {
            blob = try await transport.takePairing(id: parsed.pairingID)
        } catch TransportError.notFound {
            blob = nil
        }
        guard let blob else { throw SyncError.pairingNotFound }
        do {
            return try parsed.unwrap(blob)
        } catch {
            throw SyncError.pairingDecryptionFailed
        }
    }
}
