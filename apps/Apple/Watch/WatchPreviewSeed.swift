#if DEBUG
import ClipAppCore

/// Sample pinned items for previews and the `-ClipSyncWatchSeed` launch argument. DEBUG builds only;
/// this is test data, not app copy.
enum WatchPreviewSeed {
    static let payload = WatchPinnedPayload(
        items: [
            WatchPinnedItem(id: "seed-1", title: "Home Wi-Fi", text: "correct-horse-battery-staple", tags: ["home"]),
            WatchPinnedItem(id: "seed-2", title: nil, text: "221B Baker Street\nLondon NW1 6XE", tags: []),
            WatchPinnedItem(id: "seed-3", title: "Gate code", text: "4821#", tags: ["work", "codes"]),
            WatchPinnedItem(
                id: "seed-4", title: "Talk notes",
                text: String(repeating: "Sync is a merge problem, not a transport problem. ", count: 40),
                tags: [], isTruncated: true),
        ],
        omittedCount: 3)
}
#endif
