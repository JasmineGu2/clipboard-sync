import ClipCore

/// In-memory model of the relay (Server/Sources/RelayCore): an append-only log with server-assigned seq numbers.
/// Push is idempotent (an op ID already in the log is ignored, like `INSERT OR IGNORE`), and pull returns
/// entries with seq > cursor, ascending, at most `limit`, plus `hasMore`.
struct SimRelay {
    struct Entry {
        var seq: Int64
        var op: Op
    }

    struct Page {
        var entries: [Entry]
        var hasMore: Bool
        var latestSeq: Int64
    }

    private(set) var log: [Entry] = []
    /// Blobs the relay holds: a create op's blob arrives with the op and leaves only by garbage collection.
    var blobs: Set<BlobID> = []
    private var known: Set<OpID> = []

    var latestSeq: Int64 { log.last?.seq ?? 0 }

    /// Returns how many ops were new.
    mutating func append(_ ops: [Op]) -> Int {
        var inserted = 0
        for op in ops where known.insert(op.id).inserted {
            log.append(Entry(seq: latestSeq + 1, op: op))
            if case .create(let content) = op.kind, let blob = content.blob { blobs.insert(blob.id) }
            inserted += 1
        }
        return inserted
    }

    func page(after cursor: Int64, limit: Int) -> Page {
        let limit = max(1, limit)
        // seq is 1-based and dense, so seq n lives at index n-1.
        let start = Int(max(0, cursor))
        let end = min(log.count, start + limit)
        let entries = start < end ? Array(log[start..<end]) : []
        return Page(entries: entries, hasMore: end < log.count, latestSeq: latestSeq)
    }

    func contains(_ id: OpID) -> Bool { known.contains(id) }
}
