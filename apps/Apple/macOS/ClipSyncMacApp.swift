import AppKit
import ClipAppCore
import ClipCrypto
import SwiftUI

@main
struct ClipSyncMacApp: App {
    @State private var controller = MacAppController()

    var body: some Scene {
        MenuBarExtra(Strings.appName, systemImage: "doc.on.clipboard") {
            MenuContentView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the ClipApp and the pasteboard watcher for the menu bar app.
@MainActor
@Observable
final class MacAppController {
    let app: ClipApp
    @ObservationIgnored private let pasteboard: MacPasteboard
    @ObservationIgnored private var watcher: MacPasteboardWatcher?
    @ObservationIgnored private let picker = QuickPicker()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// False when another app holds ⌃⌘V; the menu says so and still opens the picker.
    private(set) var hotKeyAvailable = true

    init() {
        let pasteboard = MacPasteboard()
        self.pasteboard = pasteboard
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var home = AppPaths.home
        var keyStore: any KeyStore = KeychainKeyStore.appDefault
        // F16: listen and dial for direct sync. Not in measurement mode: its vault key is a fixed throwaway, so a
        // listener there would let anyone holding that key in.
        var peerSupport: PeerSupport? = PeerSockets.mac
        #if DEBUG
        if let measurement = MeasurementMode.prepare(deviceName: deviceName) {
            home = measurement.home
            keyStore = measurement.keyStore
            peerSupport = nil
        }
        #endif
        self.app = ClipApp.bootstrap(
            home: home, keyStore: keyStore, deviceName: deviceName, pasteboard: pasteboard, peerSupport: peerSupport)
        startWatcherIfReady()
        hotKey = GlobalHotKey.controlCommandV { [weak self] in self?.togglePicker() }
        hotKeyAvailable = hotKey != nil
        #if DEBUG
        if MeasurementMode.openAtLaunch == "picker" {
            DispatchQueue.main.async { [weak self] in self?.togglePicker() }
        }
        #endif
    }

    /// ⌃⌘V, or the menu item. Only once set up and still in the vault.
    func togglePicker() {
        guard app.state == .ready, !app.isRemoved, let history = app.history else { return }
        picker.toggle(history: history)
    }

    /// After this device was removed: stop capturing into the old vault, then go back to onboarding.
    func setUpAgain() {
        picker.close()
        watcher?.stop()
        watcher = nil
    }

    /// Starts capturing once setup is done. Safe to call repeatedly.
    func startWatcherIfReady() {
        guard watcher == nil, app.state == .ready, let history = app.history else { return }
        let watcher = MacPasteboardWatcher(reader: pasteboard, isPaused: app.capturePaused) { clip in
            Task { await history.capture(clip) }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// F15.
    func setCapturePaused(_ paused: Bool) {
        app.setCapturePaused(paused)
        watcher?.isPaused = paused
    }
}
