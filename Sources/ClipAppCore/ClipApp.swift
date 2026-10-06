import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import Observation

/// Makes the transport for a server URL and bearer token (nil while pairing). `HTTPTransport` in the apps,
/// an `InMemoryRelay` in tests.
public typealias TransportFactory = @Sendable (URL, String?) -> any SyncTransport

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
    @ObservationIgnored private let db: ClipDatabase?
    @ObservationIgnored private let blobCache: BlobCache?
    @ObservationIgnored private let thumbnails: any ThumbnailMaker
    @ObservationIgnored private var config: AppConfig?
    @ObservationIgnored private var vaultKey: VaultKey?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// How often a running app re-checks for expired items.
    nonisolated static let expiryCheckInterval: Duration = .seconds(3600)

    nonisolated public static let httpTransport: TransportFactory = { url, token in HTTPTransport(baseURL: url, token: token) }

    private init(
        home: URL, keyStore: any KeyStore, deviceName: String, pasteboard: any PasteboardWriter,
        makeTransport: @escaping TransportFactory, autoSync: Bool, db: ClipDatabase?, state: OnboardingState,
        thumbnails: any ThumbnailMaker = NoThumbnails()
    ) {
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
        thumbnails: any ThumbnailMaker = platformThumbnailMaker()
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
            makeTransport: makeTransport, autoSync: autoSync, db: db, state: .needsSetup, thumbnails: thumbnails)
        HistoryModel.cleanExports(in: home.appendingPathComponent(exportsFolderName), olderThan: 24 * 60 * 60)
        do {
            if let config = try AppConfig.load(from: app.configURL), let key = try keyStore.loadVaultKey() {
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
        let config = AppConfig(serverURL: url, deviceName: resolvedDeviceName(name))
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
        let config = AppConfig(serverURL: url, deviceName: resolvedDeviceName(name))
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
        guard state == .ready, let config, let vaultKey else {
            message = .notSetUp
            return nil
        }
        do {
            let transport = makeTransport(config.serverURL, vaultKey.authToken)
            return try await SyncEngine.startPairing(vaultKey: vaultKey, transport: transport).display
        } catch {
            message = AppMessage(error)
            return nil
        }
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
    func expireNow() async {
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
        history?.stop()
    }

    // MARK: Internals

    private func resolvedDeviceName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? deviceName : trimmed
    }

    private func makeEngine(db: ClipDatabase, config: AppConfig, key: VaultKey) throws -> SyncEngine {
        try SyncEngine(
            db: db, vaultKey: key, transport: makeTransport(config.serverURL, key.authToken),
            device: DeviceID(config.deviceID), deviceName: config.deviceName, blobCache: blobCache)
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
        self.vaultKey = key
        self.engine = engine
        deviceName = config.deviceName
        capturePaused = config.capturePaused
        receivesLatest = config.receivesLatest
        expiryDays = config.expiryDays
        let history = HistoryModel(
            engine: engine, db: db, pasteboard: pasteboard, thumbnails: thumbnails,
            exportsDirectory: home.appendingPathComponent(Self.exportsFolderName))
        history.receivesLatest = config.receivesLatest
        self.history = history
        history.start()
        if autoSync {
            runTask = Task { await engine.run() }
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
