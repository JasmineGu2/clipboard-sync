import Crypto
import Foundation
import Hummingbird

/// Bearer-token auth. The relay stores only SHA-256(token), which comes from one of:
/// - an operator pin (`--token-sha256` / `CLIP_RELAY_TOKEN_SHA256`): trust on first use is off, and a request
///   with any other token gets 401 even on a fresh database;
/// - trust on first use (no pin): the first token seen is adopted;
/// - `rotate(to:)` (POST /v1/auth/rotate), which replaces the hash for revocation.
///
/// The hash in force is cached after the first lookup, so a request costs one SHA-256 and no database write.
/// This actor must be the only writer of the hash while the relay runs (it is: rotation goes through it).
public actor TokenAuthenticator {
    let storage: any RelayStorage
    /// Operator-pinned hash (lowercase hex). When set, trust on first use is disabled.
    let pinnedHash: String?
    private var cachedHash: String?
    static let maxTokenLength = 512

    public init(storage: any RelayStorage, pinnedHash: String? = nil) {
        self.storage = storage
        self.pinnedHash = pinnedHash?.lowercased()
    }

    /// Whether a token can still be adopted by trust on first use.
    public var trustsOnFirstUse: Bool { pinnedHash == nil }

    /// Throws 401 unless the request carries the token whose hash is in force.
    public func authorize(_ request: Request) async throws {
        guard let header = request.headers[.authorization],
              let token = Self.bearerToken(from: header)
        else {
            throw HTTPError(.unauthorized)
        }
        let presented = Self.sha256Hex(token)
        let expected = try await currentHash(adopting: presented)
        guard let expected, Self.constantTimeEquals(expected, presented) else {
            throw HTTPError(.unauthorized)
        }
    }

    /// Replaces the hash in force. The caller must already have passed `authorize` with the current token.
    public func rotate(to newHash: String) async throws {
        let normalized = newHash.lowercased()
        try await storage.setAuthTokenHash(normalized)
        cachedHash = normalized
    }

    /// The hash in force, loading it on first use. Without a pin and with nothing stored, adopts `presented`.
    private func currentHash(adopting presented: String) async throws -> String? {
        if let cachedHash { return cachedHash }
        let loaded: String?
        if let pinnedHash {
            loaded = try await storage.seedAuthTokenHash(pinnedHash)
        } else if let stored = try await storage.authTokenHash() {
            loaded = stored
        } else {
            loaded = try await storage.adoptAuthTokenHash(presented)
        }
        // Another request may have filled the cache (or rotated) while this one was suspended; keep that.
        if let cachedHash { return cachedHash }
        cachedHash = loaded
        return loaded
    }

    static func bearerToken(from header: String) -> String? {
        let prefix = "bearer "
        guard header.count > prefix.count, header.prefix(prefix.count).lowercased() == prefix else { return nil }
        let token = header.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.utf8.count <= maxTokenLength else { return nil }
        return token
    }

    static func sha256Hex(_ string: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(string.utf8)) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Compares without an early exit, so timing doesn't reveal how many leading bytes match.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}
