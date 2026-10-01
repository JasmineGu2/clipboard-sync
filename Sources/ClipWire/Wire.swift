import Foundation

// Wire contract between clients and the relay (Server/). JSON over HTTP, tailnet only.
// The server sees only these fields. `ciphertext` is AES-256-GCM over an encoded Op.

public enum WireVersion { public static let current = 1 }

/// One encrypted op as the server stores it.
public struct Envelope: Codable, Hashable, Sendable {
    /// Client-chosen op ID (UUID string). The server dedupes on it, so retries are safe.
    public var opID: String
    /// Item ID in the clear so the AAD can be rebuilt; see threat model (grouping leak).
    public var itemID: String
    public var deviceID: String
    /// GCM combined form: nonce(12) || ciphertext || tag(16), base64 in JSON.
    public var ciphertext: Data
    /// Server-assigned, strictly increasing. nil on upload.
    public var seq: Int64?

    public init(opID: String, itemID: String, deviceID: String, ciphertext: Data, seq: Int64? = nil) {
        self.opID = opID
        self.itemID = itemID
        self.deviceID = deviceID
        self.ciphertext = ciphertext
        self.seq = seq
    }
}

/// POST /v1/ops
public struct PushRequest: Codable, Sendable {
    public var envelopes: [Envelope]
    public init(envelopes: [Envelope]) { self.envelopes = envelopes }
}

public struct PushResponse: Codable, Sendable {
    /// Highest seq after the push.
    public var latestSeq: Int64
    public init(latestSeq: Int64) { self.latestSeq = latestSeq }
}

/// GET /v1/ops?after=<seq>&limit=<n>&wait=<seconds>
/// With wait > 0 and nothing new, the server holds the request up to `wait` seconds (long-poll).
public struct PullResponse: Codable, Sendable {
    public var envelopes: [Envelope]   // ordered by seq ascending
    public var latestSeq: Int64
    public var hasMore: Bool
    public init(envelopes: [Envelope], latestSeq: Int64, hasMore: Bool) {
        self.envelopes = envelopes
        self.latestSeq = latestSeq
        self.hasMore = hasMore
    }
}

/// PUT /v1/pairing/<pairingID>   (one blob per ID, expires after 10 minutes)
/// GET /v1/pairing/<pairingID>   (returns once, then deletes; 404 if missing or expired)
public struct PairingBlob: Codable, Sendable {
    public var blob: Data
    public init(blob: Data) { self.blob = blob }
}

public enum WireHeaders {
    /// `Authorization: Bearer <token>`. Token = HKDF(vaultKey, "clip.auth.v1"), hex.
    /// The server stores SHA-256(token) on first use (trust on first use) and rejects any other token.
    /// Pairing endpoints need no token; the pairing ID itself is unguessable.
    public static let authorization = "Authorization"
}

public enum WireLimits {
    public static let maxEnvelopesPerPush = 500
    public static let maxCiphertextBytes = 256 * 1024
    public static let maxPullLimit = 1000
    public static let maxWaitSeconds = 30
}
