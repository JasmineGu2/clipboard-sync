import ClipAppCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct ClipSynciOSApp: App {
    @State private var app: ClipApp
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // F17: the Apple Watch gets the pinned items as they change, and can ask for one on this clipboard.
        let watch = WatchLink.shared
        watch.activate()
        let app = Self.makeApp(pinnedMirror: watch)
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

extension ClipSynciOSApp {
    @MainActor
    static func makeApp(pinnedMirror: (any PinnedItemsMirror)?) -> ClipApp {
        // Only the onboarding prefill: since iOS 16, UIDevice.name is the generic model name without a
        // special entitlement, so onboarding asks for a name and saves it in the config.
        let deviceName = UIDevice.current.model
        #if DEBUG
        // Measurement mode: no Watch link and no direct sync (its vault key is a fixed throwaway).
        if let measurement = MeasurementMode.prepare(deviceName: deviceName) {
            let app = ClipApp.bootstrap(
                home: measurement.home, keyStore: measurement.keyStore, deviceName: deviceName,
                pasteboard: IOSPasteboard())
            MeasurementMode.mark("app model ready")
            return app
        }
        #endif
        return ClipApp.bootstrap(
            home: AppPaths.home, keyStore: KeychainKeyStore.appDefault, deviceName: deviceName,
            pasteboard: IOSPasteboard(), pinnedMirror: pinnedMirror, peerSupport: PeerSockets.dialOnly)
    }
}

/// UIPasteboard behind ClipAppCore's writer protocol. iOS has no clipboard watcher, so no marker type.
@MainActor
final class IOSPasteboard: PasteboardWriter {
    func write(text: String) {
        UIPasteboard.general.string = text
    }

    /// An item provider backed by the file, so a large file isn't read into memory up front; apps that paste
    /// it read it from the provider.
    func write(fileAt url: URL, contentType: String?) {
        guard let provider = NSItemProvider(contentsOf: url) else { return }
        provider.suggestedName = url.lastPathComponent
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
    }
}

/// What the paste button handed over, loaded from its item providers.
enum PastedItem {
    case text(String)
    /// A temporary copy (the provider's own file only lives during its callback), and the name to show.
    case file(URL, name: String)

    static let supportedTypes: [UTType] = [.plainText, .image, .data]

    static func load(_ providers: [NSItemProvider]) async -> PastedItem? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider) {
            return .text(text)
        }
        for type in [UTType.image, .data] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let url = await copyFile(provider, type) {
                return .file(url, name: provider.suggestedName.map { name in
                    url.pathExtension.isEmpty || name.contains(".") ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent)
            }
        }
        return nil
    }

    /// Removes the temporary copy once ClipSync has its own in the blob cache.
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }

    private static func copyFile(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct RootView: View {
    let app: ClipApp

    var body: some View {
        switch app.state {
        case .ready:
            if app.isRemoved {
                RemovedView(app: app)
            } else if let history = app.history {
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
