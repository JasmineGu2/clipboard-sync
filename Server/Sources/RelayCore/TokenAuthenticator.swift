import Crypto
import Foundation
import Hummingbird

/// Bearer-token auth with trust on first use: the first token seen is adopted (its SHA-256 is stored),
/// and every later request must present the same token.
public struct TokenAuthenticator: Sendable {
    let storage: any RelayStorage
    static let maxTokenLength = 512

    public init(storage: any RelayStorage) {
        self.storage = storage
    }

    /// Throws 401 unless the request carries the adopted token.
    public func authorize(_ request: Request) async throws {
        guard let header = request.headers[.authorization],
              let token = Self.bearerToken(from: header)
        else {
            throw HTTPError(.unauthorized)
        }
        let presented = Self.sha256Hex(token)
        let stored = try await storage.adoptAuthTokenHash(presented)
        guard Self.constantTimeEquals(stored, presented) else {
            throw HTTPError(.unauthorized)
        }
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
