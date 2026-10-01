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

    public let deviceName: String

    nonisolated public static let databaseFileName = "clips.sqlite"
    nonisolated public static let configFileName = "config.json"

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let pasteboard: any PasteboardWriter
    @ObservationIgnored private let makeTransport: TransportFactory
    @ObservationIgnored private let autoSync: Bool
    @ObservationIgnored private let db: ClipDatabase?
    @ObservationIgnored private var config: AppConfig?
    @ObservationIgnored private var vaultKey: VaultKey?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    nonisolated public static let httpTransport: TransportFactory = { url, token in HTTPTransport(baseURL: url, token: token) }

    private init(
        home: URL, keyStore: any KeyStore, deviceName: String, pasteboard: any PasteboardWriter,
        makeTransport: @escaping TransportFactory, autoSync: Bool, db: ClipDatabase?, state: OnboardingState
    ) {
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
        autoSync: Bool = true
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
            makeTransport: makeTransport, autoSync: autoSync, db: db, state: .needsSetup)
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
    public func createVault(server: String) async {
        guard state == .needsSetup, let db else { return }
        guard let url = AppConfig.parseServerURL(server) else {
            message = .invalidServer
            return
        }
        state = .working
        message = nil
        let key = VaultKey.generate()
        let config = AppConfig(serverURL: url, deviceName: deviceName)
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
    public func joinVault(server: String, code: String) async {
        guard state == .needsSetup, let db else { return }
        guard let url = AppConfig.parseServerURL(server) else {
            message = .invalidServer
            return
        }
        state = .working
        message = nil
        let key: VaultKey
        let config = AppConfig(serverURL: url, deviceName: deviceName)
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

    /// Stops syncing and refreshing (app termination, tests).
    public func stop() {
        runTask?.cancel()
        runTask = nil
        history?.stop()
    }

    // MARK: Internals

    private func makeEngine(db: ClipDatabase, config: AppConfig, key: VaultKey) throws -> SyncEngine {
        try SyncEngine(
            db: db, vaultKey: key, transport: makeTransport(config.serverURL, key.authToken),
            device: DeviceID(config.deviceID), deviceName: config.deviceName)
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
        capturePaused = config.capturePaused
        let history = HistoryModel(engine: engine, db: db, pasteboard: pasteboard)
        self.history = history
        history.start()
        if autoSync {
            runTask = Task { await engine.run() }
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
    case failed(AppMessage)

    public var text: String {
        switch self {
        case .sent: Strings.shareSent
        case .savedOffline: Strings.shareSavedOffline
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
}
