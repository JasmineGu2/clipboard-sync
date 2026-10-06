#if os(Windows)
import ClipCrypto
import Foundation
import WinSDK

/// Keeps the vault key encrypted with DPAPI under the current Windows user (CryptProtectData).
/// Only this user on this machine can unwrap `key.dpapi`.
public struct DPAPIKeyStore: KeyStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Optional entropy: binds the blob to this app, so another DPAPI caller can't open it by accident.
    static let entropy = Array("clip.v1".utf8)

    public func loadVaultKey() throws -> VaultKey? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var raw = try Self.unprotect(Array(try Data(contentsOf: url)))
        defer { raw.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        return try VaultKey(rawBytes: Data(raw))
    }

    public func saveVaultKey(_ key: VaultKey) throws {
        let sealed = try Self.protect(Array(key.rawBytes))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sealed).write(to: url, options: .atomic)
    }

    public func deleteVaultKey() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `device.dpapi` next to the vault key: this device's own key pair (F13), protected the same way.
    public var deviceKeyURL: URL { url.deletingLastPathComponent().appendingPathComponent("device.dpapi") }

    public func loadDeviceKey() throws -> DeviceKey? {
        guard FileManager.default.fileExists(atPath: deviceKeyURL.path) else { return nil }
        var raw = try Self.unprotect(Array(try Data(contentsOf: deviceKeyURL)))
        defer { raw.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        return try DeviceKey(rawBytes: Data(raw))
    }

    public func saveDeviceKey(_ key: DeviceKey) throws {
        let sealed = try Self.protect(Array(key.rawBytes))
        try FileManager.default.createDirectory(
            at: deviceKeyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sealed).write(to: deviceKeyURL, options: .atomic)
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
                    throw WindowsError("\(operation) failed (Windows error \(GetLastError())). The key may belong to another Windows user.")
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
#endif
