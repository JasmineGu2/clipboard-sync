import ClipCore

/// What a simulated device folds ops into. With `.none` it is exactly ClipCore's `Replica` (the code under test);
/// any other mutation swaps in a broken fold implemented here, so the harness can prove it detects bad merges.
struct MergeStore: Equatable, Sendable {
    let mutation: MergeMutation
    private var replica = Replica()
    private var mutantItems: [ItemID: ItemState] = [:]
    private var mutantSeen: Set<OpID> = []

    init(mutation: MergeMutation) { self.mutation = mutation }

    var items: [ItemID: ItemState] { mutation == .none ? replica.items : mutantItems }
    var seenOps: Set<OpID> { mutation == .none ? replica.seenOps : mutantSeen }

    @discardableResult
    mutating func apply(_ op: Op) -> Bool {
        if mutation == .none { return replica.apply(op) }
        guard mutantSeen.insert(op.id).inserted else { return false }
        mutantItems[op.itemID, default: ItemState(id: op.itemID)].applyMutated(op, mutation)
        return true
    }

    static func == (a: MergeStore, b: MergeStore) -> Bool {
        a.items == b.items && a.seenOps == b.seenOps
    }
}

extension ItemState {
    fileprivate mutating func applyMutated(_ op: Op, _ mutation: MergeMutation) {
        switch (mutation, op.kind) {
        case (.ignoreTombstones, .delete):
            return
        case (.editRevivesDeleted, .setPinned), (.editRevivesDeleted, .setTitle), (.editRevivesDeleted, .setTag):
            deleted = false
            apply(op)
        case (.lwwReversed, .setPinned(let v)), (.lastArrivalWins, .setPinned(let v)):
            pinned.mutatedMerge(v, at: op.timestamp, mutation)
        case (.lwwReversed, .setTitle(let v)), (.lastArrivalWins, .setTitle(let v)):
            title.mutatedMerge(v, at: op.timestamp, mutation)
        case (.lwwReversed, .setTag(let name, let present)), (.lastArrivalWins, .setTag(let name, let present)):
            tags[name, default: LWW(false)].mutatedMerge(present, at: op.timestamp, mutation)
        default:
            apply(op)
        }
    }
}

extension LWW {
    fileprivate mutating func mutatedMerge(_ newValue: Value, at ts: HLCTimestamp, _ mutation: MergeMutation) {
        if mutation == .lwwReversed, let current = timestamp, ts >= current { return }
        value = newValue
        timestamp = ts
    }
}
