import ArgumentParser
import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import ClipWire
import Foundation
#if os(Windows)
import ClipWindows
#endif

/// Options every command accepts, before or after the subcommand name.
struct GlobalOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Folder for config.json, clips.sqlite and the key.",
        discussion: "Default: %APPDATA%\\ClipSync on Windows, ~/.config/clipsync elsewhere.",
        valueName: "dir"))
    var home: String?

    @Flag(help: "Non-Windows only: keep the vault key in a plain file (insecure; see content/clipctl.md).")
    var insecureFileKey = false

    var homeFolder: HomeFolder {
        HomeFolder(url: home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? HomeFolder.defaultURL)
    }
}

/// A runtime failure. ArgumentParser prints it as "Error: <message>" and exits 1.
struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// What lives in `<home>/config.json`. The key is never here.
struct Config: Codable, Sendable {
    var serverURL: String
    var deviceID: UUID
    var deviceName: String
}

/// The files of one client. `--home` lets two independent clients share a PC.
struct HomeFolder: Sendable {
    let url: URL

    static var defaultURL: URL {
        #if os(Windows)
        if let appData = WindowsPaths.appDataHome { return appData }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("clipsync", isDirectory: true)
    }

    var configURL: URL { url.appendingPathComponent("config.json") }
    var databaseURL: URL { url.appendingPathComponent("clips.sqlite") }
    /// Local copies of image and file payloads, one file per blob.
    var blobsURL: URL { url.appendingPathComponent("blobs", isDirectory: true) }
    /// F15: while this file exists, `watch` doesn't capture.
    var pausedURL: URL { url.appendingPathComponent("paused") }
    var isPaused: Bool { FileManager.default.fileExists(atPath: pausedURL.path) }
    var hasConfig: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func loadConfig() throws -> Config {
        guard hasConfig else {
            throw CLIError("No client set up in \(url.path). Run `clipctl init --server <url>` or `clipctl pair join`.")
        }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        } catch {
            throw CLIError("Can't read \(configURL.path): \(error)")
        }
    }

    func save(_ config: Config) throws {
        try create()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}

/// Parses and checks a relay URL.
func relayURL(_ string: String) throws -> URL {
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", url.host != nil else {
        throw ValidationError("Server must be an http(s) URL, e.g. http://relay.tailnet:8080")
    }
    return url
}

func defaultDeviceName() -> String {
    let env = ProcessInfo.processInfo.environment
    return env["COMPUTERNAME"] ?? env["HOSTNAME"] ?? ProcessInfo.processInfo.hostName
}

func warn(_ message: String) {
    fflush(nil)  // keep stdout and stderr in order when both go to one console or file
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

func describe(_ error: any Error) -> String {
    if let error = error as? SyncError {
        switch error {
        case .emptyText: return "the text is empty"
        case .opTooLarge(let bytes): return "too large to sync (\(bytes) bytes encrypted)"
        case .missingSeq: return "the relay sent an envelope without a sequence number"
        case .invalidPairingCode: return "that isn't a valid pairing code"
        case .pairingNotFound: return "no pairing for that code: it's wrong, already used, or expired"
        case .pairingDecryptionFailed: return "the pairing blob didn't open with that code"
        case .expiryStalled: return "expiry stopped: the local database didn't record the deletes"
        case .deviceRevoked:
            return "this device was removed from the vault: the relay refused its key and no other device left it a new one"
        case .cannotRevokeThisDevice: return "a device can't remove itself; run `clipctl revoke` on another device"
        case .unknownDevice: return "no such device in the vault; see `clipctl devices`"
        case .notRegistered: return "this device isn't in the device list yet; run `clipctl sync` once, then try again"
        case .membershipUnavailable: return "this client has no device key"
        case .blobsUnavailable: return "this client can't sync images or files"
        case .fileTooLarge(let bytes): return "the file is \(bytes) bytes; the limit is \(WireLimits.maxBlobBytes)"
        case .unreadableFile: return "the file can't be read"
        }
    }
    if let error = error as? BlobTransferError {
        switch error {
        case .notABlobItem: return "that item is text, not an image or file"
        case .noLocalCopy: return "this device has no copy of that file"
        case .notUploadedYet(let chunk):
            return "the relay doesn't have it (chunk \(chunk)): the sending device hasn't uploaded it yet, or it was "
                + "removed from the vault before any other device downloaded it; try again later"
        case .relayCountMismatch: return "the relay holds a different blob under that ID"
        case .invalidBlobRef: return "the item's file reference is outside the limits"
        case .corruptChunk(let index): return "chunk \(index) didn't decrypt: tampered with or corrupted on the relay"
        }
    }
    if let error = error as? BlobCacheError {
        switch error {
        case .hashMismatch: return "the downloaded file didn't match its SHA-256; the partial file was removed, try again"
        case .tooLarge(let bytes): return "the file is \(bytes) bytes; the limit is \(WireLimits.maxBlobBytes)"
        case .missing: return "no local copy"
        case .wrongChunkLength: return "a chunk had the wrong length"
        case .io(let message): return "file error: \(message)"
        }
    }
    return String(describing: error)
}

/// An opened client: config, key, database and engine.
struct Client: Sendable {
    let home: HomeFolder
    let config: Config
    let key: VaultKey
    let db: ClipDatabase
    let transport: HTTPTransport
    let engine: SyncEngine

    static let lastErrorKey = "clipctl.last_error"
    static let lastSyncKey = "clipctl.last_sync"

    var device: DeviceID { DeviceID(config.deviceID) }

    static func open(_ global: GlobalOptions) throws -> Client {
        let home = global.homeFolder
        let config = try home.loadConfig()
        let store = try makeKeyStore(home: home, insecureFileKey: global.insecureFileKey)
        guard let key = try store.loadVaultKey() else {
            throw CLIError("No vault key found for \(home.url.path). Run `clipctl init` or `clipctl pair join` again.")
        }
        let url = try relayURL(config.serverURL)
        let transport = HTTPTransport(baseURL: url, token: key.authToken)
        let db = try ClipDatabase(url: home.databaseURL)
        // F13: the device key lets other devices hand this one a new vault key when they revoke a lost device.
        let membership = SyncEngine.Membership(
            deviceKey: try store.loadOrCreateDeviceKey(),
            makeTransport: { HTTPTransport(baseURL: url, token: $0) },
            saveVaultKey: { try store.saveVaultKey($0) })
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: transport,
            device: DeviceID(config.deviceID), deviceName: config.deviceName,
            blobCache: try BlobCache(directory: home.blobsURL), membership: membership)
        return Client(home: home, config: config, key: key, db: db, transport: transport, engine: engine)
    }

    /// After a local change the relay gets this long; the change stays queued either way.
    static let afterChangeTimeout = 8
    /// An explicit `clipctl sync`.
    static let syncTimeout = 30

    /// One push and pull; remembers the outcome for `status`.
    ///
    /// Bounded by `seconds` because Foundation on Windows reports an unreachable relay only when the
    /// request times out (30 s), and a one-shot command shouldn't hang that long.
    func sync(timeout seconds: Int) async throws {
        let engine = self.engine
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await engine.syncOnce() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw CLIError("the relay didn't answer within \(seconds) s")
                }
                try await group.next()
                group.cancelAll()
            }
            try db.setMeta(Self.lastErrorKey, nil)
            try db.setMeta(Self.lastSyncKey, ISO8601DateFormatter().string(from: Date()))
        } catch {
            try? db.setMeta(Self.lastErrorKey, describe(error))
            throw error
        }
    }

    /// After a local change: sync, but only warn when the relay can't be reached. The change stays queued.
    func syncAfterChange() async {
        do {
            try await sync(timeout: Self.afterChangeTimeout)
        } catch {
            warn("offline, saved locally and will sync later (\(describe(error)))")
        }
    }

    /// Uploads queued images and files, printing one line per chunk to stderr. No timeout: a large file takes
    /// as long as it takes, and an interrupted upload resumes from the relay's chunks next time.
    func uploadPending() async throws -> Int {
        try await engine.uploadPendingBlobs(progress: chunkProgress("upload"))
    }

    /// Finds a visible item by the start of its ID (case-insensitive, dashes optional).
    func item(prefix: String) throws -> ItemState {
        let wanted = prefix.lowercased().replacingOccurrences(of: "-", with: "")
        guard !wanted.isEmpty else { throw ValidationError("Give at least one character of the item ID.") }
        let all = try db.items(limit: max(1, try db.count()))
        let matches = all.filter {
            $0.id.description.lowercased().replacingOccurrences(of: "-", with: "").hasPrefix(wanted)
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw CLIError("No item with an ID starting \"\(prefix)\". Try `clipctl list`.")
        default:
            let ids = matches.prefix(5).map { shortID($0.id) }.joined(separator: ", ")
            throw CLIError("\"\(prefix)\" matches \(matches.count) items (\(ids)). Type more of the ID.")
        }
    }
}
