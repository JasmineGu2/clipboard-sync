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
    /// The relay's epoch (see `PullResponse.epoch`). The relay always sends it; optional only so a client can
    /// still read a relay from before epochs existed.
    public var epoch: String?
    public init(latestSeq: Int64, epoch: String? = nil) {
        self.latestSeq = latestSeq
        self.epoch = epoch
    }
}

/// GET /v1/ops?after=<seq>&limit=<n>&wait=<seconds>
/// With wait > 0 and nothing new, the server holds the request up to `wait` seconds (long-poll).
/// Cursor rule: after applying a page, move the cursor to the LAST envelope's `seq`, not `latestSeq`.
/// `latestSeq` is the newest seq in the whole log; when `hasMore` is true they differ.
/// If `after` is greater than the relay's `latestSeq`, the relay answers 409 with `CursorAheadResponse`.
public struct PullResponse: Codable, Sendable {
    public var envelopes: [Envelope]   // ordered by seq ascending
    public var latestSeq: Int64
    public var hasMore: Bool
    /// A random ID (UUID string) the relay makes when its database is first created and keeps for the life of
    /// that database. A different epoch than last time means the relay lost its log, even when the new log has
    /// already grown past the client's cursor (which `CursorAheadResponse` can't catch). The relay always sends
    /// it; optional only so a client can still read a relay from before epochs existed.
    public var epoch: String?
    public init(envelopes: [Envelope], latestSeq: Int64, hasMore: Bool, epoch: String? = nil) {
        self.envelopes = envelopes
        self.latestSeq = latestSeq
        self.hasMore = hasMore
        self.epoch = epoch
    }
}

/// 409 body for GET /v1/ops when `after` is past the end of the log. It means the relay lost its log
/// (reset, restored from an old backup, or replaced). The client resets its cursor to 0 and pulls again;
/// that's safe because applying an op twice is a no-op.
public struct CursorAheadResponse: Codable, Sendable, Equatable {
    /// Highest seq the relay has (0 when its log is empty).
    public var latestSeq: Int64
    public init(latestSeq: Int64) { self.latestSeq = latestSeq }
}

/// PUT /v1/pairing/<pairingID>   (bearer token required: only a device already in the vault can park a key.
///                                One blob per ID, expires after 10 minutes. 204 on success, 409 if the ID
///                                is already taken and not expired, 429 when the relay holds too many.)
/// GET /v1/pairing/<pairingID>   (no token: the new device has none yet. Returns once, then deletes;
///                                404 if missing or expired.)
public struct PairingBlob: Codable, Sendable {
    public var blob: Data
    public init(blob: Data) { self.blob = blob }
}

/// POST /v1/auth/rotate   (bearer token required: the CURRENT token; 204 on success)
/// Replaces the relay's stored token hash, and nothing else. Clients revoke with `POST /v1/auth/revoke` instead
/// (`RevokeRequest`), which also wipes the log and hands the new vault key to the remaining devices.
public struct RotateTokenRequest: Codable, Sendable, Equatable {
    /// SHA-256 of the new bearer token, 64 hex characters. The token itself never leaves the device.
    public var newTokenSHA256: String
    public init(newTokenSHA256: String) { self.newTokenSHA256 = newTokenSHA256 }
}

// MARK: - Devices and revocation (F13, design §3)

/// One device in the vault, as the relay stores it.
/// PUT /v1/devices/<deviceID>   (bearer token; 204. 409 if the relay already holds a different public key for
///                               this ID, 429 when it holds `WireLimits.maxDevices` records.)
/// GET /v1/devices              (bearer token; `DeviceListResponse`)
public struct DeviceRecord: Codable, Hashable, Sendable {
    public var deviceID: String
    /// The device's X25519 public key, 32 bytes. Public, so it travels in the clear; the relay uses it only to
    /// refuse a second key for the same device ID.
    public var publicKey: Data
    /// The device's name, AES-GCM sealed under a key derived from the vault key, with the device ID and public key
    /// as associated data. The relay can't read it, and can't pair a name with a key it chose.
    public var sealed: Data

    public init(deviceID: String, publicKey: Data, sealed: Data) {
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.sealed = sealed
    }
}

public struct DeviceListResponse: Codable, Sendable {
    public var devices: [DeviceRecord]
    public init(devices: [DeviceRecord]) { self.devices = devices }
}

/// A new vault key sealed to one remaining device (HPKE, see ClipCrypto `RekeyHandoff`).
public struct Handoff: Codable, Hashable, Sendable {
    public var deviceID: String
    public var blob: Data
    public init(deviceID: String, blob: Data) {
        self.deviceID = deviceID
        self.blob = blob
    }
}

/// POST /v1/auth/revoke   (bearer token: the CURRENT one; 200 with `RevokeResponse`)
/// In one transaction the relay: replaces its token hash with `newTokenSHA256`, deletes every envelope and pending
/// pairing, starts a new epoch, replaces the device table with `devices`, drops handoffs for devices no longer
/// listed, and appends `handoffs`. Devices left out of `devices` are revoked: the old token gets 401 from then on.
public struct RevokeRequest: Codable, Sendable, Equatable {
    public var newTokenSHA256: String
    /// The devices that stay, their names sealed under the new vault key.
    public var devices: [DeviceRecord]
    /// The new vault key for each device that stays, this one included (so a crash before it saves the key is
    /// recoverable).
    public var handoffs: [Handoff]
    /// Every device ID the revoker saw in the list, revoked ones included. When set, the relay answers 409 and
    /// changes nothing if its list differs, so a device that registered meanwhile isn't silently dropped.
    public var expectedDeviceIDs: [String]?

    public init(
        newTokenSHA256: String, devices: [DeviceRecord], handoffs: [Handoff], expectedDeviceIDs: [String]? = nil
    ) {
        self.newTokenSHA256 = newTokenSHA256
        self.devices = devices
        self.handoffs = handoffs
        self.expectedDeviceIDs = expectedDeviceIDs
    }
}

public struct RevokeResponse: Codable, Sendable, Equatable {
    /// The relay's new epoch. Every device that sees it re-pushes all its ops under the new key.
    public var epoch: String
    public init(epoch: String) { self.epoch = epoch }
}

/// GET /v1/rekey/<deviceID>   (no token: the device's old token stopped working. Each blob is sealed to that
///                             device's own key, so it's useless to anyone else. Oldest first; 200 with an empty
///                             list when there are none.)
public struct HandoffsResponse: Codable, Sendable {
    public var handoffs: [Data]
    public init(handoffs: [Data]) { self.handoffs = handoffs }
}

public enum WireHeaders {
    /// `Authorization: Bearer <token>`. Token = HKDF(vaultKey, "clip.auth.v1"), hex.
    /// The server stores only SHA-256(token). It's either pinned by the operator (`--token-sha256`) or
    /// adopted from the first request it sees (trust on first use), and can be replaced via /v1/auth/rotate.
    /// Every route needs it except `GET /healthz` and `GET /v1/pairing/<id>`.
    public static let authorization = "Authorization"
}

public enum WireLimits {
    public static let maxEnvelopesPerPush = 500
    public static let maxCiphertextBytes = 256 * 1024
    /// Whole push body cap. Clients split pushes to stay under it; blobs (M4) go through a separate chunk API.
    public static let maxPushBodyBytes = 4 * 1024 * 1024
    public static let defaultPullLimit = 500
    public static let maxPullLimit = 1000
    public static let maxPairingBlobBytes = 64 * 1024
    /// Whole pairing PUT body cap, checked before decoding (64 KiB of blob is ~87 KiB as base64 JSON).
    public static let maxPairingBodyBytes = 100 * 1024
    /// Most unexpired pairing blobs the relay holds at once; beyond it a PUT gets 429.
    public static let maxLivePairings = 100
    /// opID, itemID and deviceID: 1...128 UTF-8 bytes, no NUL or other control characters.
    public static let maxIDBytes = 128
    public static let maxWaitSeconds = 30
    /// Most device records a relay holds (PUT /v1/devices beyond it gets 429; a revoke may list no more).
    public static let maxDevices = 64
    /// X25519 public keys are 32 bytes.
    public static let devicePublicKeyBytes = 32
    /// A sealed device name: nonce + JSON of a name up to a few hundred bytes + tag.
    public static let maxSealedDeviceBytes = 2048
    /// One handoff: HPKE encapsulated key (32) + sealed vault key (32) + tag (16) = 80 bytes; room to spare.
    public static let maxHandoffBytes = 512
    /// Handoffs kept per device, oldest dropped first. A device offline through more revocations than this
    /// has to pair again.
    public static let maxHandoffsPerDevice = 8
    /// PUT /v1/devices body cap, checked before decoding.
    public static let maxDeviceBodyBytes = 8 * 1024
    /// POST /v1/auth/revoke body cap: `maxDevices` records and handoffs as base64 JSON fit well under it.
    public static let maxRevokeBodyBytes = 512 * 1024
}

extension WireLimits {
    /// True for a valid opID, itemID or deviceID: 1...maxIDBytes UTF-8 bytes with no C0 or C1 control
    /// characters (which includes NUL). The relay answers 400 for anything else.
    public static func isValidID(_ id: String) -> Bool {
        let count = id.utf8.count
        guard count > 0, count <= maxIDBytes else { return false }
        return !id.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }
    }

    /// Pairing IDs are exactly 32 lowercase hex characters (design §3).
    public static func isValidPairingID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A SHA-256 digest as 64 hex characters (either case).
    public static func isValidSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
        }
    }
}
