import ClipAppCore
import ClipCore
import ClipSync
import Foundation

/// First 8 characters of the item ID, lower case. Enough to type back into `copy`, `pin`, etc.
func shortID(_ id: ItemID) -> String {
    String(id.description.lowercased().prefix(8))
}

/// "now", "42s ago", "5m ago", "3h ago", "6d ago", then a date.
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    switch seconds {
    case ..<5: return "now"
    case ..<60: return "\(seconds)s ago"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86_400: return "\(seconds / 3600)h ago"
    case ..<(30 * 86_400): return "\(seconds / 86_400)d ago"
    default:
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Collapses whitespace to single spaces and cuts at `limit` characters.
func preview(_ text: String, limit: Int = 60) -> String {
    let oneLine = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    return oneLine.count > limit ? String(oneLine.prefix(limit - 3)) + "..." : oneLine
}

/// One line per item: pin marker, short ID, age, source device, tags, then the title or a preview.
func itemLine(_ item: ItemState, now: Date = Date()) -> String {
    let pin = item.pinned.value ? "*" : " "
    let age = item.content.map { relativeTime($0.createdAt, now: now) } ?? "?"
    let device = item.content?.sourceDeviceName ?? "?"
    let tags = item.visibleTags.map { "#\($0)" }.joined(separator: " ")
    var label = item.title.value.map { "\"\(preview($0))\"" } ?? preview(item.content?.text ?? "")
    if let content = item.content, let blob = content.blob {
        label = "[\(content.kind.rawValue) \(FileTypes.sizeText(blob.size))] " + label
    }
    let padded = age.padding(toLength: max(age.count, 8), withPad: " ", startingAt: 0)
    return [pin + " " + shortID(item.id), padded, device, tags, label]
        .filter { !$0.isEmpty }
        .joined(separator: "  ")
}

/// The `--json` shape of an item.
struct ItemJSON: Encodable {
    let id: String
    let shortID: String
    let text: String
    let title: String?
    let pinned: Bool
    let tags: [String]
    let sourceDevice: String?
    let sourceDeviceName: String?
    let createdAt: Date?
    let kind: String?
    /// Images and files: the payload's size, SHA-256 (hex) and type.
    let size: Int64?
    let sha256: String?
    let contentType: String?
    let hasThumbnail: Bool

    init(_ item: ItemState) {
        id = item.id.description.lowercased()
        shortID = clipctl.shortID(item.id)
        text = item.content?.text ?? ""
        title = item.title.value
        pinned = item.pinned.value
        tags = item.visibleTags
        sourceDevice = item.content?.sourceDevice.description.lowercased()
        sourceDeviceName = item.content?.sourceDeviceName
        createdAt = item.content?.createdAt
        kind = item.content?.kind.rawValue
        size = item.content?.blob?.size
        sha256 = item.content?.blob.map { $0.sha256.map { String(format: "%02x", $0) }.joined() }
        contentType = item.content?.blob?.contentType
        hasThumbnail = item.content?.thumbnail != nil
    }
}

/// Prints transfer progress to stderr, one line per chunk, so scripts can follow (and interrupt) a transfer.
func chunkProgress(_ verb: String) -> BlobProgressHandler {
    { progress in
        let short = String(progress.blob.description.lowercased().prefix(8))
        let resumed = progress.resumedFrom > 0 ? " (resumed at chunk \(progress.resumedFrom))" : ""
        FileHandle.standardError.write(Data("\(verb) \(short) \(progress.done)/\(progress.total)\(resumed)\n".utf8))
    }
}

func printItems(_ items: [ItemState], json: Bool, emptyMessage: String) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(items.map(ItemJSON.init)), as: UTF8.self))
        return
    }
    if items.isEmpty {
        print(emptyMessage)
        return
    }
    let now = Date()
    for item in items { print(itemLine(item, now: now)) }
}
