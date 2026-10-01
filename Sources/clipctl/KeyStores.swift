import ArgumentParser
import ClipCrypto
import Foundation
#if os(Windows)
import WinSDK
#endif

/// Picks where the vault key lives (PRD N9): DPAPI on Windows. Elsewhere a CLI has no Keychain,
/// so a plain file is used only behind `--insecure-file-key`.
func makeKeyStore(home: HomeFolder, insecureFileKey: Bool) throws -> any KeyStore {
    #if os(Windows)
    if insecureFileKey { warn("--insecure-file-key is ignored on Windows; the key is protected with DPAPI.") }
    return DPAPIKeyStore(url: home.url.appendingPathComponent("key.dpapi"))
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

#if os(Windows)
/// Keeps the vault key encrypted with DPAPI under the current Windows user (CryptProtectData).
/// Only this user on this machine can unwrap `key.dpapi`.
struct DPAPIKeyStore: KeyStore {
    let url: URL

    /// Optional entropy: binds the blob to this app, so another DPAPI caller can't open it by accident.
    static let entropy = Array("clip.v1".utf8)

    func loadVaultKey() throws -> VaultKey? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var raw = try Self.unprotect(Array(try Data(contentsOf: url)))
        defer { raw.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        return try VaultKey(rawBytes: Data(raw))
    }

    func saveVaultKey(_ key: VaultKey) throws {
        let sealed = try Self.protect(Array(key.rawBytes))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sealed).write(to: url, options: .atomic)
    }

    func deleteVaultKey() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func protect(_ plain: [UInt8]) throws -> [UInt8] {
        try transform(plain, operation: "CryptProtectData") { input, entropy, output in
            "ClipSync vault key".withCString(encodedAs: UTF16.self) { description in
                CryptProtectData(input, description, entropy, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
            }
        }
    }

    static func unprotect(_ sealed: [UInt8]) throws -> [UInt8] {
        try transform(sealed, operation: "CryptUnprotectData") { input, entropy, output in
            CryptUnprotectData(input, nil, entropy, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
        }
    }

    private static func transform(
        _ input: [UInt8],
        operation: String,
        _ call: (UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>) -> Bool
    ) throws -> [UInt8] {
        var inputBytes = input
        var entropyBytes = entropy
        return try inputBytes.withUnsafeMutableBufferPointer { inBuffer in
            try entropyBytes.withUnsafeMutableBufferPointer { entropyBuffer in
                var inBlob = DATA_BLOB(cbData: DWORD(inBuffer.count), pbData: inBuffer.baseAddress)
                var entropyBlob = DATA_BLOB(cbData: DWORD(entropyBuffer.count), pbData: entropyBuffer.baseAddress)
                var outBlob = DATA_BLOB(cbData: 0, pbData: nil)
                guard call(&inBlob, &entropyBlob, &outBlob) else {
                    throw CLIError("\(operation) failed (Windows error \(GetLastError())). The key may belong to another Windows user.")
                }
                defer {
                    if let data = outBlob.pbData {
                        memset(data, 0, Int(outBlob.cbData))
                        LocalFree(data)
                    }
                }
                return Array(UnsafeBufferPointer(start: outBlob.pbData, count: Int(outBlob.cbData)))
            }
        }
    }
}
#else
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
}
#endif
