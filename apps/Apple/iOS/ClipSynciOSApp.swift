import ClipAppCore
import SwiftUI
import UIKit

@main
struct ClipSynciOSApp: App {
    @State private var app: ClipApp
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // F17: the Apple Watch gets the pinned items as they change, and can ask for one on this clipboard.
        let watch = WatchLink.shared
        watch.activate()
        let app = ClipApp.bootstrap(
            home: AppPaths.home,
            keyStore: KeychainKeyStore.appDefault,
            // Only the onboarding prefill: since iOS 16, UIDevice.name is the generic model name without a
            // special entitlement, so onboarding asks for a name and saves it in the config.
            deviceName: UIDevice.current.model,
            pasteboard: IOSPasteboard(),
            pinnedMirror: watch
        )
        watch.onCopyRequest = { id in app.history?.copyPinned(id: id) ?? false }
        _app = State(initialValue: app)
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the long-poll and the hourly expiry check in the background; catch up (and pick
            // up share-extension sends) as soon as the app is back.
            if phase == .active, let history = app.history {
                Task {
                    await app.expireNow()
                    await history.syncNow()
                }
            }
        }
    }
}

/// UIPasteboard behind ClipAppCore's writer protocol. iOS has no clipboard watcher, so no marker type.
@MainActor
final class IOSPasteboard: PasteboardWriter {
    func write(text: String) {
        UIPasteboard.general.string = text
    }
}

struct RootView: View {
    let app: ClipApp

    var body: some View {
        switch app.state {
        case .ready:
            if let history = app.history {
                HistoryView(history: history, app: app)
            }
        case .needsSetup, .working:
            NavigationStack {
                OnboardingView(app: app)
                    .navigationTitle(Strings.onboardingTitle)
            }
        case .failed(let message):
            ContentUnavailableView(
                Strings.appName,
                systemImage: "exclamationmark.triangle",
                description: Text(message.text)
            )
        }
    }
}
