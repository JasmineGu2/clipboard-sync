import ClipAppCore
import Foundation
import Observation

/// The watch's side of the iPhone link: gets pinned-item payloads and asks the iPhone to copy one.
/// WatchConnectivity lives behind this so the store (and previews) don't depend on it.
@MainActor
protocol PhoneLink: AnyObject {
    /// Called with each payload the iPhone sends (raw, still to be decoded).
    var onPayload: ((Data) -> Void)? { get set }
    func activate()
    /// Asks the iPhone to put a pinned item on its clipboard. False when it can't be reached or refused.
    func requestCopy(id: String) async -> Bool
}

/// F17: the pinned items on the watch. It holds plain text of pinned items only, never the vault key.
@MainActor
@Observable
final class WatchStore {
    enum CopyState: Equatable {
        case sending(String)
        case copied(String)
        case failed(String)
    }

    private(set) var payload: WatchPinnedPayload
    private(set) var copyState: CopyState?

    @ObservationIgnored private let link: (any PhoneLink)?
    @ObservationIgnored private let fileURL: URL?

    init(link: (any PhoneLink)?, fileURL: URL?, initial: WatchPinnedPayload? = nil) {
        self.link = link
        self.fileURL = fileURL
        self.payload = initial ?? fileURL.flatMap(Self.load) ?? .empty
        link?.onPayload = { [weak self] data in self?.receive(data) }
        link?.activate()
    }

    /// The live store: WatchConnectivity plus a file in Application Support.
    static func live() -> WatchStore {
        #if DEBUG
        // `-ClipSyncWatchSeed` (scheme argument) shows sample items without a phone, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-ClipSyncWatchSeed") {
            return WatchStore(link: nil, fileURL: nil, initial: WatchPreviewSeed.payload)
        }
        #endif
        let file = URL.applicationSupportDirectory
            .appendingPathComponent("ClipSync", isDirectory: true)
            .appendingPathComponent("pinned.json")
        return WatchStore(link: WCPhoneLink(), fileURL: file)
    }

    func receive(_ data: Data) {
        // A payload from a newer or older phone app that this watch can't read is ignored, not shown wrong.
        guard let decoded = WatchPinnedPayload.decode(data) else { return }
        payload = decoded
        if let fileURL { Self.save(data, to: fileURL) }
    }

    func copyOnPhone(_ item: WatchPinnedItem) async {
        guard let link else { return }
        copyState = .sending(item.id)
        copyState = await link.requestCopy(id: item.id) ? .copied(item.id) : .failed(item.id)
    }

    private static func load(from url: URL) -> WatchPinnedPayload? {
        (try? Data(contentsOf: url)).flatMap(WatchPinnedPayload.decode)
    }

    /// Data protection: readable only while the watch is unlocked (after the passcode), but a payload that
    /// arrives while it's locked can still be written.
    private static func save(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
