import ArgumentParser
import ClipCrypto
import Foundation
#if os(Windows)
import ClipWindows
#endif

/// Picks where the vault key lives (PRD N9): DPAPI on Windows. Elsewhere a CLI has no Keychain,
/// so a plain file is used only behind `--insecure-file-key`.
func makeKeyStore(home: HomeFolder, insecureFileKey: Bool) throws -> any KeyStore {
    #if os(Windows)
    if insecureFileKey { warn("--insecure-file-key is ignored on Windows; the key is protected with DPAPI.") }
    return DPAPIKeyStore(url: WindowsPaths.keyURL(home: home.url))
    #else
    guard insecureFileKey else {
        throw ValidationError(
            "No secure key store for clipctl on this OS. Pass --insecure-file-key to keep the key in a plain file (see content/clipctl.md).")
    }
    warn("the vault key is stored unencrypted in \(home.url.path)/key.insecure. Anyone who can read it can read your clipboard history.")
    return InsecureFileKeyStore(url: home.url.appendingPathComponent("key.insecure"))
    #endif
}

func keyStoreLabel() -> String {
    #if os(Windows)
    "DPAPI (key.dpapi, current Windows user)"
    #else
    "plain file (key.insecure, --insecure-file-key)"
    #endif
}

#if !os(Windows)
/// The 32 raw key bytes in a 0600 file. Only behind `--insecure-file-key`; PRD N9 forbids it by default.
struct InsecureFileKeyStore: KeyStore {
    let url: URL

    func loadVaultKey() throws -> VaultKey? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try VaultKey(rawBytes: Data(contentsOf: url))
    }

    func saveVaultKey(_ key: VaultKey) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try key.rawBytes.write(to: url)
    }

    func deleteVaultKey() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `device.insecure`: this device's own key pair (F13), as plain as the vault key next to it.
    var deviceKeyURL: URL { url.deletingLastPathComponent().appendingPathComponent("device.insecure") }

    func loadDeviceKey() throws -> DeviceKey? {
        guard FileManager.default.fileExists(atPath: deviceKeyURL.path) else { return nil }
        return try DeviceKey(rawBytes: Data(contentsOf: deviceKeyURL))
    }

    func saveDeviceKey(_ key: DeviceKey) throws {
        try FileManager.default.createDirectory(
            at: deviceKeyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: deviceKeyURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try key.rawBytes.write(to: deviceKeyURL)
    }
}
#endif
