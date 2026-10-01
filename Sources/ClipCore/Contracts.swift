import Foundation

// Shared model contract. Every other module builds against these types.
// Behavior (merge, clock ticking) lives in the other ClipCore files; see docs/design.md.

public struct DeviceID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
    public static func < (a: DeviceID, b: DeviceID) -> Bool { a.rawValue.uuidString < b.rawValue.uuidString }
}

public struct ItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct OpID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Hybrid logical clock timestamp. Total order: (wallMillis, counter, device).
/// The device tiebreak makes every timestamp unique, so last-writer-wins never ties.
public struct HLCTimestamp: Hashable, Comparable, Codable, Sendable {
    public var wallMillis: UInt64
    public var counter: UInt32
    public var device: DeviceID

    public init(wallMillis: UInt64, counter: UInt32, device: DeviceID) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.device = device
    }

    public static func < (a: HLCTimestamp, b: HLCTimestamp) -> Bool {
        (a.wallMillis, a.counter) != (b.wallMillis, b.counter)
            ? (a.wallMillis, a.counter) < (b.wallMillis, b.counter)
            : a.device < b.device
    }
}

public enum ContentKind: String, Codable, Sendable {
    case text
    case image   // P1
    case file    // P1
}

/// Immutable content captured once, at creation.
public struct ItemContent: Hashable, Codable, Sendable {
    public var kind: ContentKind
    /// Text for `.text`; for images/files a display name. Blob payloads travel separately (M4).
    public var text: String
    public var sourceDevice: DeviceID
    public var sourceDeviceName: String
    public var createdAt: Date

    public init(kind: ContentKind = .text, text: String, sourceDevice: DeviceID, sourceDeviceName: String, createdAt: Date) {
        self.kind = kind
        self.text = text
        self.sourceDevice = sourceDevice
        self.sourceDeviceName = sourceDeviceName
        self.createdAt = ClipCoding.normalized(createdAt)
    }
}

public enum OpKind: Hashable, Codable, Sendable {
    case create(ItemContent)
    case setPinned(Bool)
    case setTitle(String?)
    case setTag(String, present: Bool)
    case delete
}

/// One change to one item. Ops are the unit of sync, storage and encryption.
public struct Op: Hashable, Codable, Sendable, Identifiable {
    public var id: OpID
    public var itemID: ItemID
    public var timestamp: HLCTimestamp
    public var kind: OpKind

    public init(id: OpID = OpID(), itemID: ItemID, timestamp: HLCTimestamp, kind: OpKind) {
        self.id = id
        self.itemID = itemID
        self.timestamp = timestamp
        self.kind = kind
    }
}

/// A last-writer-wins register.
public struct LWW<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var value: Value
    public var timestamp: HLCTimestamp?
    public init(_ value: Value, timestamp: HLCTimestamp? = nil) {
        self.value = value
        self.timestamp = timestamp
    }
}

/// Materialized state of one item: the fold of every op for that item.
public struct ItemState: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    /// nil until the create op arrives (field ops may arrive first).
    public var content: ItemContent?
    public var createdBy: HLCTimestamp?
    public var pinned: LWW<Bool>
    public var title: LWW<String?>
    /// Per-tag LWW presence. A tag is shown when its register is true.
    public var tags: [String: LWW<Bool>]
    /// Sticky tombstone: once deleted, always deleted (delete wins over concurrent edits).
    public var deleted: Bool

    public init(id: ItemID) {
        self.id = id
        self.content = nil
        self.createdBy = nil
        self.pinned = LWW(false)
        self.title = LWW(nil)
        self.tags = [:]
        self.deleted = false
    }

    public var isVisible: Bool { content != nil && !deleted }
    public var visibleTags: [String] { tags.filter { $0.value.value }.keys.sorted() }
}
