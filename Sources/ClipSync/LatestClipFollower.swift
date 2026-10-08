import ClipCore

/// Decides when another device's copy goes on this device's clipboard: whenever the newest item in the
/// whole history changes and that item came from another device. Like Universal Clipboard, across every
/// device in the vault.
///
/// - The first update only records a baseline, so starting the app never overwrites the clipboard.
/// - A local copy becoming newest writes nothing (it's already on the clipboard), but it does become the
///   new baseline, so an older remote item that arrives late never replaces it.
/// - A backlog after being offline writes once: only the newest item counts.
/// - Edits (pin, rename, tag) don't change which item is newest, so they never write.
/// - Deleting (or expiring) the newest item doesn't restore the one before it: only an item created after
///   the newest one seen so far counts, by the same create timestamp the history is sorted by.
/// - Text and images are delivered (a screenshot behaves like text). Other files are not: they download in
///   the background and go on the clipboard when picked from the history (docs/decisions.md, 2026-10-08).
public struct LatestClipFollower: Sendable {
    /// What to put on the clipboard.
    public enum Delivery: Equatable, Sendable {
        case text(String)
        /// An image item: its payload downloads first (`SyncEngine.fetchBlob`), then goes on as a file. Write it
        /// only if `isNewest` still holds once the download ends.
        case image(ItemID)

        public var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }
    }

    public let device: DeviceID
    private var newest: HLCTimestamp?
    private var newestItem: ItemID?
    private var hasBaseline = false

    public init(device: DeviceID) {
        self.device = device
    }

    /// Call after each sync change with the newest visible item (`ClipDatabase.items(limit: 1).first`).
    /// Returns what to put on the clipboard, or nil to leave it alone.
    public mutating func update(newest item: ItemState?) -> Delivery? {
        guard hasBaseline else {
            hasBaseline = true
            newest = item?.createdBy
            newestItem = item?.id
            return nil
        }
        guard let item, let created = item.createdBy else { return nil }
        if let newest, created <= newest { return nil }
        newest = created
        newestItem = item.id
        guard let content = item.content, content.sourceDevice != device else { return nil }
        switch content.kind {
        case .text: return .text(content.text)
        case .image: return content.blob == nil ? nil : .image(item.id)
        case .file: return nil
        }
    }

    /// True while `item` is still the newest item seen: nothing newer, here or elsewhere, came during its download.
    public func isNewest(_ item: ItemID) -> Bool {
        newestItem == item
    }
}
