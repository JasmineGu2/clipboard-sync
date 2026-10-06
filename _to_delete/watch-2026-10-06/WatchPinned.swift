import Foundation

/// F17: one pinned item as the Apple Watch sees it. Plain text: the watch never gets the vault key.
public struct WatchPinnedItem: Codable, Hashable, Identifiable, Sendable {
    /// The item's ID (`ItemID.description`). The watch sends it back to ask the iPhone to copy the item.
    public let id: String
    public let title: String?
    /// The text, cut to `WatchPayloadLimits.maxTextCharacters`.
    public let text: String
    public let tags: [String]
    /// True when `text` was cut.
    public let isTruncated: Bool

    public init(id: String, title: String?, text: String, tags: [String], isTruncated: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.tags = tags
        self.isTruncated = isTruncated
    }

    /// Same rule as the phone's list (F4): the title, else the first non-empty line.
    public var headline: String { ClipItem.headline(title: title, text: text) }
}

/// Caps that keep the payload small enough for WatchConnectivity's application context and a watch screen.
public struct WatchPayloadLimits: Sendable, Equatable {
    public var maxItems: Int
    /// Per item. Longer text is cut and marked `isTruncated`; the full text stays on the phone.
    public var maxTextCharacters: Int
    /// Upper bound on `WatchPinnedPayload.encoded()`. Items that don't fit are left out and counted.
    public var maxTotalBytes: Int

    public init(maxItems: Int, maxTextCharacters: Int, maxTotalBytes: Int) {
        self.maxItems = maxItems
        self.maxTextCharacters = maxTextCharacters
        self.maxTotalBytes = maxTotalBytes
    }

    /// 50 items, 2,000 characters each, 48 KB in all. Apple doesn't publish a hard limit for the application
    /// context; 48 KB stays under the 64 KB that `sendMessage` allows, with room to spare.
    public static let standard = WatchPayloadLimits(maxItems: 50, maxTextCharacters: 2_000, maxTotalBytes: 48_000)
}

/// What the iPhone sends the watch whenever its pinned items change: the newest pinned items, capped.
public struct WatchPinnedPayload: Codable, Hashable, Sendable {
    /// Bumped on any change the watch couldn't read. A watch that gets another version ignores the payload.
    public static let currentVersion = 1
    /// The key the payload goes under in the WatchConnectivity dictionary.
    public static let contextKey = "pinned"
    /// The key a watch's "copy on iPhone" message carries the item ID under.
    public static let copyRequestKey = "copy"
    /// The key the iPhone's reply carries the result under (a Bool).
    public static let copyReplyKey = "ok"

    public let version: Int
    /// Newest first, like the phone's Pinned section.
    public let items: [WatchPinnedItem]
    /// Pinned items left out by the caps.
    public let omittedCount: Int

    public init(items: [WatchPinnedItem], omittedCount: Int = 0) {
        self.version = Self.currentVersion
        self.items = items
        self.omittedCount = omittedCount
    }

    public static let empty = WatchPinnedPayload(items: [])

    /// Builds the payload from the phone's pinned items, in the order given. Unpinned items are skipped.
    public static func build(from pinned: [ClipItem], limits: WatchPayloadLimits = .standard) -> WatchPinnedPayload {
        let candidates = pinned.filter(\.isPinned)
        let encoder = Self.encoder
        // The empty payload's size covers the wrapper; each item adds its own encoding plus a comma.
        var used = (try? encoder.encode(WatchPinnedPayload(items: [], omittedCount: candidates.count)).count) ?? 64
        var items: [WatchPinnedItem] = []
        for item in candidates {
            guard items.count < limits.maxItems else { break }
            let cut = item.text.count > limits.maxTextCharacters
            let watchItem = WatchPinnedItem(
                id: item.id.description,
                title: item.title,
                text: cut ? String(item.text.prefix(limits.maxTextCharacters)) : item.text,
                tags: item.tags,
                isTruncated: cut)
            guard let size = try? encoder.encode(watchItem).count else { continue }
            // Keep going after one too-big item: a smaller one further down may still fit.
            guard used + size + 1 <= limits.maxTotalBytes else { continue }
            used += size + 1
            items.append(watchItem)
        }
        return WatchPinnedPayload(items: items, omittedCount: candidates.count - items.count)
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// nil for anything that isn't a payload of the current version.
    public static func decode(_ data: Data) -> WatchPinnedPayload? {
        guard let payload = try? JSONDecoder().decode(WatchPinnedPayload.self, from: data),
              payload.version == currentVersion
        else { return nil }
        return payload
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Where `HistoryModel` sends the pinned items whenever they change. On iOS this is WatchConnectivity
/// (apps/Apple/iOS/WatchLink.swift); tests use a fake.
@MainActor
public protocol PinnedItemsMirror: AnyObject {
    func publish(_ payload: WatchPinnedPayload)
}
