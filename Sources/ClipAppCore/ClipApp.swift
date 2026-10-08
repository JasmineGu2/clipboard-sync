import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import Observation

/// Makes the transport for a server URL and bearer token (nil while pairing). `HTTPTransport` in the apps,
/// an `InMemoryRelay` in tests.
public typealias TransportFactory = @Sendable (URL, String?) -> any SyncTransport

/// F16: direct device-to-device sync while the relay is unreachable. Platform code supplies the sockets
/// (ClipPeerSocket): the Mac listens and dials, the iPhone only dials (it can't listen in the background).
public struct PeerSupport: Sendable {
    public var dialer: any PeerDialer
    /// Makes and binds this device's listener, or returns nil when it can't (no Tailscale address). nil: dial only.
    public var makeListener: (@Sendable () -> PeerListener?)?

    public init(dialer: any PeerDialer, makeListener: (@Sendable () -> PeerListener?)? = nil) {
        self.dialer = dialer
        self.makeListener = makeListener
    }
}

/// Where the app is in setup.
public enum OnboardingState: Equatable, Sendable {
    /// No vault yet: show onboarding (create, or join with a code).
    case needsSetup
    /// Creating or joining; show progress.
    case working
    /// `history` is set and syncing.
    case ready
    /// The local database couldn't be opened. Nothing works; show the message.
    case failed(AppMessage)
}

/// The app's root object: opens storage, runs onboarding, then owns the sync engine and the history model.
@MainActor
@Observable
public final class ClipApp {
    public private(set) var state: OnboardingState
    /// Set once `state` is `.ready`.
    public private(set) var history: HistoryModel?
    /// The last onboarding or pairing error, as copy.
    public var message: AppMessage?
    /// F15, persisted in the config.
    public private(set) var capturePaused = false
    public private(set) var receivesLatest = true
    /// F14, persisted in the config. nil keeps items forever.
    public private(set) var expiryDays: Int?
    /// Where files from other devices are saved (`HistoryModel.receivedFilesDirectory`); a platform choice, not
    /// config. Carried into each history model this app makes.
    public var receivedFilesDirectory: URL? {
        didSet { history?.receivedFilesDirectory = receivedFilesDirectory }
    }
    public var onFileSaved: ((URL) -> Void)? {
        didSet { history?.onFileSaved = onFileSaved }
    }
    /// F13: the vault's devices, as of the last `loadDevices()`. This device comes first.
    public private(set) var devices: [VaultDevice] = []

    /// The name this device shows on synced items. Starts as the platform default (the onboarding field's
    /// prefill) and becomes the saved name once set up.
    public private(set) var deviceName: String

    nonisolated public static let databaseFileName = "clips.sqlite"
    /// Folder (next to the database) for local copies of image and file payloads.
    nonisolated public static let blobsFolderName = "blobs"
    /// Folder for copies named like their items, handed to the clipboard.
    nonisolated public static let exportsFolderName = "exports"
    nonisolated public static let configFileName = "config.json"

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let pasteboard: any PasteboardWriter
    @ObservationIgnored private let makeTransport: TransportFactory
    @ObservationIgnored private let autoSync: Bool
    @ObservationIgnored private var db: ClipDatabase?
    @ObservationIgnored private var blobCache: BlobCache?
    @ObservationIgnored private let thumbnails: any ThumbnailMaker
    @ObservationIgnored private var config: AppConfig?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let peerSupport: PeerSupport?
    @ObservationIgnored private var peerListener: PeerListener?

    /// How often a running app re-checks for expired items.
    nonisolated static let expiryCheckInterval: Duration = .seconds(3600)

    nonisolated public static let httpTransport: TransportFactory = { url, token in HTTPTransport(baseURL: url, token: token) }

    private init(
        home: URL, keyStore: any KeyStore, deviceName: String, pasteboard: any PasteboardWriter,
        makeTransport: @escaping TransportFactory, autoSync: Bool, db: ClipDatabase?, state: OnboardingState,
        thumbnails: any ThumbnailMaker = NoThumbnails(), peerSupport: PeerSupport? = nil
    ) {
        self.peerSupport = peerSupport
        self.blobCache = db == nil ? nil : try? BlobCache(directory: home.appendingPathComponent(Self.blobsFolderName))
        self.thumbnails = thumbnails
        self.home = home
        self.keyStore = keyStore
        self.deviceName = deviceName
        self.pasteboard = pasteboard
        self.makeTransport = makeTransport
        self.autoSync = autoSync
        self.db = db
        self.state = state
    }

    /// Opens the database in `home` (created if needed) and loads the config and vault key.
    /// With both present the app is `.ready` and syncing; otherwise `.needsSetup`.
    /// - Parameters:
    ///   - autoSync: start `SyncEngine.run()` (long-poll loop) when ready. Tests pass false and sync by hand.
    public static func bootstrap(
        home: URL,
        keyStore: any KeyStore,
        deviceName: String,
        pasteboard: any PasteboardWriter,
        makeTransport: @escaping TransportFactory = ClipApp.httpTransport,
        autoSync: Bool = true,
        thumbnails: any ThumbnailMaker = platformThumbnailMaker(),
        peerSupport: PeerSupport? = nil
    ) -> ClipApp {
        let db: ClipDatabase
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            db = try ClipDatabase(url: home.appendingPathComponent(databaseFileName))
        } catch {
            return ClipApp(
                home: home, keyStore: keyStore, deviceName: deviceName, pasteboard: pasteboard,
                makeTransport: makeTransport, autoSync: autoSync, db: nil, state: .failed(.storage))
        }
        let app = ClipApp(
            home: home, keyStore: keyStore, deviceName: deviceName, pasteboard: pasteboard,
            makeTransport: makeTransport, autoSync: autoSync, db: db, state: .needsSetup, thumbnails: thumbnails,
            peerSupport: peerSupport)
        HistoryModel.cleanExports(in: home.appendingPathComponent(exportsFolderName), olderThan: 24 * 60 * 60)
        do {
            if var config = try AppConfig.load(from: app.configURL), let key = try keyStore.loadVaultKey() {
                if config.joinedAt == nil {
                    // Set up before the device list showed join dates: the config was written at setup.
                    config.joinedAt = Self.creationDate(of: app.configURL) ?? Date()
                    try? config.save(to: app.configURL)
                }
                try app.becomeReady(config: config, key: key)
            }
        } catch {
            // A damaged config or an unreadable key: set up again. The local history stays in the database.
            app.message = AppMessage(error)
        }
        return app
    }

    private var configURL: URL { home.appendingPathComponent(Self.configFileName) }

    // MARK: Onboarding

    /// First device: makes a new vault key. Checks the server answers before saving anything,
    /// so a typo in the URL doesn't leave a half-set-up app.
    /// - Parameter deviceName: the name other devices show on clips from here. Blank or nil uses `deviceName`.
    public func createVault(server: String, deviceName name: String? = nil) async {
        guard state == .needsSetup, let db else { return }
        guard let url = AppConfig.parseServerURL(server) else {
            message = .invalidServer
            return
        }
        state = .working
        message = nil
        let key = VaultKey.generate()
        let config = AppConfig(serverURL: url, deviceName: resolvedDeviceName(name), joinedAt: Date())
        do {
            let engine = try makeEngine(db: db, config: config, key: key)
            try await engine.syncOnce()
            try save(config: config, key: key)
            try becomeReady(config: config, key: key, engine: engine)
        } catch {
            message = AppMessage(error)
            state = .needsSetup
        }
    }

    /// New device: fetches the vault key with a code shown on an existing device, then pulls the history.
    public func joinVault(server: String, code: String, deviceName name: String? = nil) async {
        guard state == .needsSetup, let db else { return }
        guard let url = AppConfig.parseServerURL(server) else {
            message = .invalidServer
            return
        }
        state = .working
        message = nil
        let key: VaultKey
        let config = AppConfig(serverURL: url, deviceName: resolvedDeviceName(name), joinedAt: Date())
        do {
            key = try await SyncEngine.completePairing(code: code, transport: makeTransport(url, nil))
            // The code is spent now, so save the key before anything else can fail.
            try save(config: config, key: key)
        } catch {
            message = AppMessage(error)
            state = .needsSetup
            return
        }
        do {
            let engine = try makeEngine(db: db, config: config, key: key)
            try? await engine.syncOnce()  // Offline is fine; run() catches up.
            try becomeReady(config: config, key: key, engine: engine)
        } catch {
            message = AppMessage(error)
            state = .needsSetup
        }
    }

    /// On a ready device: parks the vault key on the relay under a one-time code. Returns the code to show
    /// (groups of 4), or nil with `message` set.
    public func startPairing() async -> String? {
        guard state == .ready, let config, let engine else {
            message = .notSetUp
            return nil
        }
        do {
            // The engine's key, not the one loaded at launch: a revoke may have replaced it since.
            let vaultKey = await engine.currentVaultKey
            let transport = makeTransport(config.serverURL, vaultKey.authToken)
            return try await SyncEngine.startPairing(vaultKey: vaultKey, transport: transport).display
        } catch {
            message = AppMessage(error)
            return nil
        }
    }

    // MARK: Devices (F13)

    /// Reads the vault's device list from the relay into `devices`. Sets `message` on failure.
    public func loadDevices() async {
        guard state == .ready, let engine else {
            message = .notSetUp
            return
        }
        do {
            devices = try await engine.devices()
        } catch {
            message = AppMessage(error)
        }
    }

    /// Removes a lost device from the vault: it stops syncing and can't read anything new. The other devices move to
    /// a new key on their next sync. Returns true on success; otherwise `message` says why.
    @discardableResult
    public func removeDevice(_ device: VaultDevice) async -> Bool {
        guard state == .ready, let engine else {
            message = .notSetUp
            return false
        }
        do {
            try await engine.revoke([device.id])
            message = nil
            devices = (try? await engine.devices()) ?? devices.filter { $0.id != device.id }
            return true
        } catch {
            message = AppMessage(error)
            return false
        }
    }

    // MARK: Removed from the vault (F13)

    /// True once another device removed this one: syncing has stopped for good, and the app should offer
    /// `setUpAgain()`. Follows the history's status, which the engine sets on its first refused request.
    public var isRemoved: Bool { history?.syncStatus == .removed }

    /// Prefix of the folder in `home` that `setUpAgain()` moves the old vault's files into.
    nonisolated public static let removedFolderPrefix = "removed-"

    /// After this device was removed: goes back to onboarding so it can join with a new pairing code or start a
    /// new vault. Nothing is deleted. The database, file cache, exports and config move into
    /// `home/removed-<date>/`, where the old history stays readable (the database is plaintext on the device,
    /// see docs/threat-model.md). The vault key is dropped from the key store: the relay refuses it and it
    /// can't open anything written since the removal. The device key is replaced too, so the new membership
    /// doesn't reuse a key pair whose device was declared lost. Returns false, with `message` set, if the files
    /// couldn't be moved; the app is then `.failed` until it's restarted.
    @discardableResult
    public func setUpAgain() -> Bool {
        guard state == .ready else { return false }
        stop()
        history = nil
        engine = nil
        config = nil
        devices = []
        db?.close()
        db = nil
        blobCache = nil
        message = nil
        do {
            try moveVaultFilesAside()
        } catch {
            state = .failed(.storage)
            return false
        }
        do {
            try keyStore.deleteVaultKey()
            try keyStore.saveDeviceKey(DeviceKey.generate())
        } catch {
            // The files are already aside, so onboarding can go ahead: create and join overwrite both keys.
            message = .keychain
        }
        do {
            let fresh = try ClipDatabase(url: home.appendingPathComponent(Self.databaseFileName))
            db = fresh
            blobCache = try? BlobCache(directory: home.appendingPathComponent(Self.blobsFolderName))
        } catch {
            state = .failed(.storage)
            return false
        }
        state = .needsSetup
        return true
    }

    /// Moves everything that belongs to the old vault into a new `removed-<date>` folder in `home`.
    private func moveVaultFilesAside() throws {
        let files = FileManager.default
        let stamp = Self.folderStamp(Date())
        var archive = home.appendingPathComponent(Self.removedFolderPrefix + stamp, isDirectory: true)
        var suffix = 1
        while files.fileExists(atPath: archive.path) {
            suffix += 1
            archive = home.appendingPathComponent("\(Self.removedFolderPrefix)\(stamp)-\(suffix)", isDirectory: true)
        }
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        let names = [
            Self.databaseFileName, Self.databaseFileName + "-wal", Self.databaseFileName + "-shm",
            Self.blobsFolderName, Self.exportsFolderName, Self.configFileName,
        ]
        for name in names where files.fileExists(atPath: home.appendingPathComponent(name).path) {
            try files.moveItem(at: home.appendingPathComponent(name), to: archive.appendingPathComponent(name))
        }
    }

    /// `2026-10-05-143012`: sorts by time and is safe in a file name everywhere.
    nonisolated static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// F15.
    public func setCapturePaused(_ paused: Bool) {
        capturePaused = paused
        guard var config else { return }
        config.capturePaused = paused
        self.config = config
        do {
            try config.save(to: configURL)
        } catch {
            message = AppMessage(error)
        }
    }

    /// Whether the newest copy from another device goes on this device's clipboard.
    public func setReceivesLatest(_ on: Bool) {
        receivesLatest = on
        history?.receivesLatest = on
        guard var config else { return }
        config.receivesLatest = on
        self.config = config
        do {
            try config.save(to: configURL)
        } catch {
            message = AppMessage(error)
        }
    }

    /// F14. Saves the setting and expires anything already past it. nil or below 1 keeps items forever;
    /// anything over `SyncEngine.maxExpiryDays` is capped.
    public func setExpiryDays(_ days: Int?) async {
        guard var config else { return }
        let days = days.flatMap { $0 >= 1 ? min($0, SyncEngine.maxExpiryDays) : nil }
        expiryDays = days
        config.expiryDays = days
        self.config = config
        do {
            try config.save(to: configURL)
        } catch {
            message = AppMessage(error)
            return
        }
        await expireNow()
    }

    /// Deletes unpinned items older than `expiryDays`. The deletes sync like any other edit.
    /// A running app does this hourly; iOS also calls it when the app comes back to the front, because the
    /// hourly loop doesn't run while the app is suspended.
    public func expireNow() async {
        guard let engine, let days = expiryDays, days >= 1 else { return }
        do {
            // Clamped here too: a hand-edited config.json never went through setExpiryDays.
            try await engine.expireItems(olderThan: .seconds(min(days, SyncEngine.maxExpiryDays) * 86_400))
        } catch {
            message = AppMessage(error)
        }
    }

    /// Stops syncing and refreshing (app termination, tests).
    public func stop() {
        runTask?.cancel()
        runTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        peerListener?.stop()
        peerListener = nil
        history?.stop()
    }

    // MARK: Internals

    private func resolvedDeviceName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? deviceName : trimmed
    }

    private func makeEngine(db: ClipDatabase, config: AppConfig, key: VaultKey) throws -> SyncEngine {
        let deviceKey: DeviceKey
        do {
            deviceKey = try keyStore.loadOrCreateDeviceKey()
        } catch {
            throw AppError.keyStore(String(describing: error))
        }
        let keyStore = self.keyStore
        let makeTransport = self.makeTransport
        let url = config.serverURL
        let membership = SyncEngine.Membership(
            deviceKey: deviceKey,
            makeTransport: { token in makeTransport(url, token) },
            saveVaultKey: { key in
                do {
                    try keyStore.saveVaultKey(key)
                } catch {
                    throw AppError.keyStore(String(describing: error))
                }
            },
            joinedAt: config.joinedAt)
        return try SyncEngine(
            db: db, vaultKey: key, transport: makeTransport(config.serverURL, key.authToken),
            device: DeviceID(config.deviceID), deviceName: config.deviceName, blobCache: blobCache,
            membership: membership)
    }

    private func save(config: AppConfig, key: VaultKey) throws {
        do {
            try keyStore.saveVaultKey(key)
        } catch {
            throw AppError.keyStore(String(describing: error))
        }
        try config.save(to: configURL)
    }

    private func becomeReady(config: AppConfig, key: VaultKey, engine existing: SyncEngine? = nil) throws {
        guard let db else { return }
        let engine = try existing ?? makeEngine(db: db, config: config, key: key)
        self.config = config
        self.engine = engine
        deviceName = config.deviceName
        capturePaused = config.capturePaused
        receivesLatest = config.receivesLatest
        expiryDays = config.expiryDays
        let history = HistoryModel(
            engine: engine, db: db, pasteboard: pasteboard, thumbnails: thumbnails,
            exportsDirectory: home.appendingPathComponent(Self.exportsFolderName))
        history.receivesLatest = config.receivesLatest
        history.receivedFilesDirectory = receivedFilesDirectory
        history.onFileSaved = onFileSaved
        self.history = history
        history.start()
        if autoSync {
            // F16: listen (Mac) and dial (both) while the relay is unreachable.
            let listener = peerSupport?.makeListener?()
            if let listener {
                do {
                    try listener.start { await engine.handlePeerRequest($0) }
                    peerListener = listener
                } catch {
                    listener.stop()
                }
            }
            let setup = peerSupport.map { PeerSetup(dialer: $0.dialer, listenAddress: peerListener?.boundAddress) }
            runTask = Task {
                if let setup { await engine.enablePeerSync(setup) }
                await engine.run()
            }
            expiryTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.expireNow()
                    guard self != nil else { return }  // app gone: don't keep waking hourly
                    try? await Task.sleep(for: Self.expiryCheckInterval)
                }
            }
        }
        state = .ready
    }
}

// MARK: - Measurement (N3, N4)

extension ClipApp {
    /// Fills `home` with a set-up vault holding `count` text items, for launch and idle measurements (DEBUG builds
    /// of the apps, never a real vault: callers pass a home of their own and a throwaway key). Does nothing when
    /// the database already has that many items, so only the first launch pays for it. Returns the item count.
    @discardableResult
    public nonisolated static func seedForMeasurement(
        home: URL, key: VaultKey, keyStore: any KeyStore, count: Int, serverURL: URL, deviceName: String
    ) throws -> Int {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent(configFileName)
        let config = try AppConfig.load(from: configURL)
            ?? AppConfig(serverURL: serverURL, deviceName: deviceName, joinedAt: Date())
        try config.save(to: configURL)
        try keyStore.saveVaultKey(key)
        let db = try ClipDatabase(url: home.appendingPathComponent(databaseFileName))
        defer { db.close() }
        let existing = try db.count()
        guard existing < count else { return existing }
        // Straight into the database in batches (one transaction each), as already-synced ops: a measurement
        // home has no relay to push them to.
        let device = DeviceID(config.deviceID)
        let words = ["invoice", "meeting", "deploy", "tracking", "password reset", "address", "recipe", "flight"]
        let nowMillis = UInt64(Date().timeIntervalSince1970 * 1000)
        var batch: [Op] = []
        for index in existing..<count {
            let wall = nowMillis - UInt64(count - index) * 1000
            let text = "\(words[index % words.count]) note \(index): " + String(repeating: "lorem ipsum ", count: 1 + index % 12)
            let content = ItemContent(
                text: text, sourceDevice: device, sourceDeviceName: config.deviceName,
                createdAt: Date(timeIntervalSince1970: Double(wall) / 1000))
            batch.append(Op(itemID: ItemID(), timestamp: HLCTimestamp(wallMillis: wall, counter: 0, device: device), kind: .create(content)))
            if batch.count == 500 || index == count - 1 {
                _ = try db.insert(batch, outbound: false)
                batch = []
            }
        }
        return count
    }
}

// MARK: - One-shot send (share extension, App Intent)

public enum SendResult: Equatable, Sendable {
    /// Saved and pushed to the server.
    case sent
    /// Saved locally; the server didn't answer in time, so the app pushes it later.
    case savedOffline
    /// An image or file: saved and announced, but its upload didn't finish in time. The app finishes it.
    case uploadingLater
    case failed(AppMessage)

    public var text: String {
        switch self {
        case .sent: Strings.shareSent
        case .savedOffline: Strings.shareSavedOffline
        case .uploadingLater: Strings.shareUploadLater
        case .failed(let message): message.text
        }
    }
}

extension ClipApp {
    /// Adds `text` to the history in `home` and syncs once, giving up on the sync after `timeout`.
    /// For short-lived processes (share extension, Shortcuts), which can't run the long-poll loop.
    public nonisolated static func sendOnce(
        _ text: String,
        home: URL,
        keyStore: any KeyStore,
        timeout: Duration = .seconds(5),
        makeTransport: @escaping TransportFactory = ClipApp.httpTransport
    ) async -> SendResult {
        let engine: SyncEngine
        do {
            guard let config = try AppConfig.load(from: home.appendingPathComponent(configFileName)),
                  let key = try keyStore.loadVaultKey()
            else { return .failed(.notSetUp) }
            let db = try ClipDatabase(url: home.appendingPathComponent(databaseFileName))
            engine = try SyncEngine(
                db: db, vaultKey: key, transport: makeTransport(config.serverURL, key.authToken),
                device: DeviceID(config.deviceID), deviceName: config.deviceName)
            try await engine.addText(text)
        } catch {
            return .failed(AppMessage(error))
        }
        let synced = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await engine.syncOnce()) != nil }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return synced ? .sent : .savedOffline
    }

    /// `sendOnce` for an image or file (share extension). Copies it into the shared blob cache, records it,
    /// then pushes the item and uploads the payload until `timeout`. Whatever doesn't finish stays queued in
    /// the shared database, and the app's run loop completes it.
    public nonisolated static func sendFileOnce(
        _ url: URL,
        name: String? = nil,
        home: URL,
        keyStore: any KeyStore,
        timeout: Duration = .seconds(5),
        thumbnails: any ThumbnailMaker = platformThumbnailMaker(),
        makeTransport: @escaping TransportFactory = ClipApp.httpTransport
    ) async -> SendResult {
        let engine: SyncEngine
        do {
            guard let config = try AppConfig.load(from: home.appendingPathComponent(configFileName)),
                  let key = try keyStore.loadVaultKey()
            else { return .failed(.notSetUp) }
            let db = try ClipDatabase(url: home.appendingPathComponent(databaseFileName))
            engine = try SyncEngine(
                db: db, vaultKey: key, transport: makeTransport(config.serverURL, key.authToken),
                device: DeviceID(config.deviceID), deviceName: config.deviceName,
                blobCache: try BlobCache(directory: home.appendingPathComponent(blobsFolderName)))
            let shown = name ?? url.lastPathComponent
            let type = FileTypes.contentType(forName: shown)
            let kind = FileTypes.kind(forContentType: type)
            let thumbnail = kind == .image ? thumbnails.thumbnail(forFileAt: url, maxBytes: ItemContent.maxThumbnailBytes) : nil
            try await engine.addFile(at: url, kind: kind, name: shown, contentType: type, thumbnail: thumbnail)
        } catch {
            return .failed(AppMessage(error))
        }
        let deadline = ContinuousClock.now + timeout
        guard await finishes(within: timeout, { try await engine.syncOnce() }) else { return .savedOffline }
        let uploaded = await finishes(within: deadline - ContinuousClock.now) { _ = try await engine.uploadPendingBlobs() }
        return uploaded ? .sent : .uploadingLater
    }

    /// Runs `body` until it finishes or `limit` passes. True when it finished without throwing.
    private nonisolated static func finishes(
        within limit: Duration, _ body: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        guard limit > .zero else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await body()) != nil }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
