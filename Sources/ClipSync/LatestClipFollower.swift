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
public struct LatestClipFollower: Sendable {
    public let device: DeviceID
    private var newest: HLCTimestamp?
    private var hasBaseline = false

    public init(device: DeviceID) {
        self.device = device
    }

    /// Call after each sync change with the newest visible item (`ClipDatabase.items(limit: 1).first`).
    /// Returns the text to put on the clipboard, or nil to leave it alone.
    public mutating func update(newest item: ItemState?) -> String? {
        guard hasBaseline else {
            hasBaseline = true
            newest = item?.createdBy
            return nil
        }
        guard let item, let created = item.createdBy else { return nil }
        if let newest, created <= newest { return nil }
        newest = created
        guard let content = item.content, content.kind == .text, content.sourceDevice != device else {
            return nil
        }
        return content.text
    }
}
