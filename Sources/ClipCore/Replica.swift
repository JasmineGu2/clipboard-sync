import Foundation

/// In-memory fold of every op a device has seen. Applying the same op set in any order,
/// with duplicates, yields an equal Replica (see docs/design.md §2).
public struct Replica: Codable, Sendable, Equatable {
    public private(set) var items: [ItemID: ItemState]
    public private(set) var seenOps: Set<OpID>

    public init() {
        self.items = [:]
        self.seenOps = []
    }

    /// Folds `op` into its item. Returns false, changing nothing, if the op was already applied.
    @discardableResult
    public mutating func apply(_ op: Op) -> Bool {
        guard seenOps.insert(op.id).inserted else { return false }
        items[op.itemID, default: ItemState(id: op.itemID)].apply(op)
        return true
    }

    /// Visible items, newest first by create timestamp. Pinned items are not regrouped here; the UI does that.
    public var visibleItems: [ItemState] {
        items.values
            .filter(\.isVisible)
            .sorted { a, b in
                switch (a.createdBy, b.createdBy) {
                case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
                default: return a.id.rawValue.uuidString < b.id.rawValue.uuidString
                }
            }
    }

    public func item(_ id: ItemID) -> ItemState? {
        items[id]
    }
}
