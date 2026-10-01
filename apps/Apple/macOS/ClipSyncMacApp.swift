import AppKit
import ClipAppCore
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

    init() {
        let pasteboard = MacPasteboard()
        self.pasteboard = pasteboard
        self.app = ClipApp.bootstrap(
            home: AppPaths.home,
            keyStore: KeychainKeyStore.appDefault,
            deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            pasteboard: pasteboard
        )
        startWatcherIfReady()
    }

    /// Starts capturing once setup is done. Safe to call repeatedly.
    func startWatcherIfReady() {
        guard watcher == nil, app.state == .ready, let history = app.history else { return }
        let watcher = MacPasteboardWatcher(reader: pasteboard, isPaused: app.capturePaused) { text in
            Task { await history.capture(text) }
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
