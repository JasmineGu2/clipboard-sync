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
    /// Which vault key generation sealed each blob in `blobs` (entries for blobs no longer held mean nothing).
    /// Only tracked with `RevokeBlobMode`; the first upload of a blob wins, like the relay's first-copy rule.
    var blobGeneration: [BlobID: Int] = [:]
    private var known: Set<OpID> = []

    var latestSeq: Int64 { log.last?.seq ?? 0 }

    /// Returns how many ops were new. A new create op's blob lands with it. With `uploads` (RevokeBlobMode), a
    /// create op's blob lands only when `uploads` says the pusher sends it, also for an op the relay already has:
    /// the upload is separate from the op, so a re-push can bring a wiped blob back.
    mutating func append(_ ops: [Op], uploads: ((Op, BlobID) -> Bool)? = nil, generation: Int = 0) -> Int {
        var inserted = 0
        for op in ops {
            let isNew = known.insert(op.id).inserted
            if case .create(let content) = op.kind, let blob = content.blob,
               uploads.map({ $0(op, blob.id) }) ?? isNew,
               blobs.insert(blob.id).inserted
            {
                blobGeneration[blob.id] = generation
            }
            guard isNew else { continue }
            log.append(Entry(seq: latestSeq + 1, op: op))
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
