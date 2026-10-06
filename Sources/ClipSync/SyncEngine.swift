import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case offline(lastError: String)
}

public enum SyncError: Error, Equatable, Sendable {
    /// addText got empty or whitespace-only text.
    case emptyText
    /// The encrypted op would exceed WireLimits.maxCiphertextBytes, so the relay would never accept it.
    case opTooLarge(bytes: Int)
    /// The relay sent an envelope without a seq.
    case missingSeq
    /// The pairing code doesn't parse (wrong length or characters).
    case invalidPairingCode
    /// No blob for this code: never created, already used, or expired (10 minutes).
    case pairingNotFound
    /// The blob didn't open with this code.
    case pairingDecryptionFailed
    /// An expiry sweep found the same items twice: the local deletes didn't take.
    case expiryStalled
    /// Images and files need a blob cache and a transport with blob routes; this engine has neither.
    case blobsUnavailable
    /// The file is over `WireLimits.maxBlobBytes`.
    case fileTooLarge(bytes: Int64)
    /// The file couldn't be read.
    case unreadableFile
}

/// Records local changes as ops, pushes them, pulls everyone else's, and keeps the local database current.
/// See docs/design.md §4.
public actor SyncEngine {
    public nonisolated let device: DeviceID
    public let deviceName: String
    public private(set) var status: SyncStatus = .idle
    public private(set) var lastSyncedAt: Date?

    /// Fires after local records and after remote ops are applied. Single consumer (the UI).
    public nonisolated let changes: AsyncStream<Void>

    private let db: ClipDatabase
    private let cipher: OpCipher
    private let transport: any SyncTransport
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let changesContinuation: AsyncStream<Void>.Continuation
    private var clock: HybridClock
    /// Highest timestamp issued or observed; persisted so the clock survives restarts.
    private var highWater: (wall: UInt64, counter: UInt32)

    /// The local copies of image and file payloads (nil: this engine syncs text only).
    public nonisolated let blobCache: BlobCache?
    /// Moves blobs to and from the relay; nil without a blob cache or a transport with blob routes.
    public nonisolated let transferer: BlobTransferer?
    private var uploadTask: Task<Int, Error>?
    private var blobWaiter: CheckedContinuation<Void, Never>?
    private var blobWorkPending = false

    private var syncTask: Task<Void, Error>?
    private var longPollTask: Task<PullResponse, Error>?
    private var wakePending = false
    /// How the current sync already recovered from a relay reset, if it did. At most one recovery per sync.
    private var resetInSync: ResetInSync = .none

    private enum ResetInSync {
        case none
        /// After `cursorAhead`: the next epoch seen is the relay this sync recovered against.
        case byCursorAhead
        /// After an epoch change: a second change in the same sync waits for the next sync.
        case byEpoch
    }

    static let clockKey = "hlc_high_water"
    static let undecryptableKey = "undecryptable"
    /// The last relay epoch this device saw (see `PullResponse.epoch`).
    static let relayEpochKey = "relay_epoch"
    static let maxUndecryptableRecorded = 1000
    static let longPollWait = 25

    public init(
        db: ClipDatabase,
        vaultKey: VaultKey,
        transport: any SyncTransport,
        device: DeviceID,
        deviceName: String,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = SyncEngine.logToStandardError,
        blobCache: BlobCache? = nil,
        transferMeter: TransferMeter = TransferMeter()
    ) throws {
        self.db = db
        self.blobCache = blobCache
        if let blobCache, let blobTransport = transport as? any BlobTransport {
            self.transferer = BlobTransferer(cache: blobCache, transport: blobTransport, vaultKey: vaultKey, meter: transferMeter)
        } else {
            self.transferer = nil
        }
        self.cipher = OpCipher(vaultKey: vaultKey)
        self.transport = transport
        self.device = device
        self.deviceName = deviceName
        self.now = now
        self.log = log
        (changes, changesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))

        let stored = try db.meta(Self.clockKey).flatMap(Self.parseClock)
        self.clock = HybridClock(
            device: device,
            resumingAfter: stored.map { HLCTimestamp(wallMillis: $0.wall, counter: $0.counter, device: device) },
            now: { Self.millis(now()) }
        )
        self.highWater = stored ?? (0, 0)
    }

    public static let logToStandardError: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data("[ClipSync] \(message)\n".utf8))
    }

    // MARK: Local changes

    /// Records a new text item. Returns the newest item's ID instead when its text is identical,
    /// because clipboard watchers fire repeatedly for the same copy.
    /// - Throws: `SyncError.emptyText` for empty or whitespace-only text.
    @discardableResult
    public func addText(_ text: String) throws -> ItemID {
        guard !text.allSatisfy(\.isWhitespace) else { throw SyncError.emptyText }
        if let newest = try db.items(limit: 1).first, newest.content?.text == text {
            return newest.id
        }
        let item = ItemID()
        let content = ItemContent(
            kind: .text, text: text, sourceDevice: device, sourceDeviceName: deviceName,
            createdAt: Date(timeIntervalSince1970: Double(Self.millis(now())) / 1000)
        )
        try record(item, .create(content))
        return item
    }

    public func setPinned(_ item: ItemID, _ pinned: Bool) throws {
        try record(item, .setPinned(pinned))
    }

    public func setTitle(_ item: ItemID, _ title: String?) throws {
        try record(item, .setTitle(title))
    }

    public func setTag(_ item: ItemID, _ tag: String, present: Bool) throws {
        try record(item, .setTag(tag, present: present))
    }

    public func delete(_ item: ItemID) throws {
        try record(item, .delete)
    }

    /// F14: deletes every visible, unpinned item created more than `age` ago. Returns how many.
    ///
    /// Expiry is an ordinary synced `delete`, not a local filter, so every device ends up with the same
    /// history whatever its own setting (the harness's `ExpiryMode.hideLocally` shows the alternative
    /// diverging). Deletes are sticky, so a pin made on another device at the same moment loses;
    /// see docs/decisions.md.
    @discardableResult
    public func expireItems(olderThan age: Duration) async throws -> Int {
        let (ageMillis, overflow) = UInt64(max(0, age.components.seconds)).multipliedReportingOverflow(by: 1000)
        let nowMillis = Self.millis(now())
        guard !overflow, nowMillis > ageMillis else { return 0 }
        var expired = 0
        var previous: [ItemID] = []
        // Each delete hides its item, so the next batch starts where this one ended.
        while case let batch = try db.expiredItemIDs(createdBeforeMillis: nowMillis - ageMillis), !batch.isEmpty {
            // A batch that didn't change means the deletes didn't take; stop rather than spin.
            guard batch != previous else { throw SyncError.expiryStalled }
            for item in batch { try record(item, .delete) }
            expired += batch.count
            previous = batch
            await Task.yield()  // let sync and UI calls in between batches of a large backlog
        }
        return expired
    }

    /// The longest expiry the apps and clipctl accept: 100 years. Keeps `days * 86_400` far from overflow.
    public static let maxExpiryDays = 36_500

    private func record(_ item: ItemID, _ kind: OpKind, blobUploads: [BlobUpload] = []) throws {
        let op = Op(itemID: item, timestamp: clock.tick(), kind: kind)
        let size = try cipher.seal(op, device: device).ciphertext.count
        guard size <= WireLimits.maxCiphertextBytes else { throw SyncError.opTooLarge(bytes: size) }
        // Clock first: if we crash between the two writes, the stored clock is ahead, which is safe.
        try advanceHighWater(op.timestamp)
        try db.insert([op], outbound: true, blobUploads: blobUploads)
        changesContinuation.yield()
        wake()
        if !blobUploads.isEmpty || kind == .delete { wakeBlobs() }
    }

    // MARK: Images and files (F11, F12; design §6)

    /// Records an image or file item. The file is copied into the blob cache (hashed on the way, one chunk at a
    /// time), the create op carries its blob reference and thumbnail, and the upload is queued in the same
    /// transaction. The bytes go to the relay later, by `uploadPendingBlobs` or the run loop.
    /// Copying the same file again right after returns the newest item instead, like `addText`.
    /// - Parameters:
    ///   - name: the name shown in the history and used when saving; defaults to the file's name.
    ///   - thumbnail: a small JPEG for images. Dropped when over `ItemContent.maxThumbnailBytes`.
    @discardableResult
    public func addFile(
        at url: URL, kind: ContentKind = .file, name: String? = nil, contentType: String? = nil, thumbnail: Data? = nil
    ) throws -> ItemID {
        guard let blobCache else { throw SyncError.blobsUnavailable }
        let blob = BlobID()
        let imported: BlobCache.Imported
        do {
            imported = try blobCache.importFile(at: url, as: blob, maxBytes: WireLimits.maxBlobBytes)
        } catch BlobCacheError.tooLarge(let bytes) {
            throw SyncError.fileTooLarge(bytes: bytes)
        } catch {
            throw SyncError.unreadableFile
        }
        return try recordBlob(blob, imported, kind: kind, name: name ?? url.lastPathComponent,
                              contentType: contentType, thumbnail: thumbnail)
    }

    /// Records an image or file from bytes in memory, such as an image on the clipboard.
    @discardableResult
    public func addData(
        _ data: Data, kind: ContentKind = .image, name: String, contentType: String? = nil, thumbnail: Data? = nil
    ) throws -> ItemID {
        guard let blobCache else { throw SyncError.blobsUnavailable }
        let blob = BlobID()
        let imported: BlobCache.Imported
        do {
            imported = try blobCache.importData(data, as: blob, maxBytes: WireLimits.maxBlobBytes)
        } catch BlobCacheError.tooLarge(let bytes) {
            throw SyncError.fileTooLarge(bytes: bytes)
        } catch {
            throw SyncError.unreadableFile
        }
        return try recordBlob(blob, imported, kind: kind, name: name, contentType: contentType, thumbnail: thumbnail)
    }

    private func recordBlob(
        _ blob: BlobID, _ imported: BlobCache.Imported, kind: ContentKind, name: String, contentType: String?,
        thumbnail: Data?
    ) throws -> ItemID {
        if let newest = try db.items(limit: 1).first, let ref = newest.content?.blob,
           ref.sha256 == imported.sha256, ref.size == imported.size {
            blobCache?.remove(blob)
            return newest.id
        }
        let ref = BlobRef(id: blob, size: imported.size, sha256: imported.sha256, contentType: contentType)
        let item = ItemID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = ItemContent(
            kind: kind, text: String((trimmed.isEmpty ? blob.description : trimmed).prefix(255)),
            sourceDevice: device, sourceDeviceName: deviceName,
            createdAt: Date(timeIntervalSince1970: Double(Self.millis(now())) / 1000),
            blob: ref,
            thumbnail: thumbnail.flatMap { $0.count <= ItemContent.maxThumbnailBytes ? $0 : nil })
        do {
            try record(item, .create(content), blobUploads: [BlobUpload(blob: blob, item: item)])
        } catch {
            blobCache?.remove(blob)
            throw error
        }
        return item
    }

    /// The local file of an image or file item, once it's in the cache (sent from here, or downloaded).
    public func localFile(for item: ItemID) throws -> URL? {
        guard let blobCache, let ref = try db.item(item)?.content?.blob, blobCache.contains(ref.id) else { return nil }
        return blobCache.url(for: ref.id)
    }

    /// F12: downloads an image or file item's payload on demand (resuming an earlier attempt) and returns its
    /// file in the cache.
    public func fetchBlob(for item: ItemID, progress: BlobProgressHandler? = nil) async throws -> URL {
        guard let transferer else { throw SyncError.blobsUnavailable }
        guard let state = try db.item(item), state.isVisible, let ref = state.content?.blob else {
            throw BlobTransferError.notABlobItem
        }
        return try await transferer.download(ref, item: item, progress: progress)
    }

    /// Uploads every queued blob, each resuming from what the relay already has. Returns how many were sent.
    /// Runs one at a time; a second call waits for the first. Network errors are thrown and the jobs stay queued.
    @discardableResult
    public func uploadPendingBlobs(progress: BlobProgressHandler? = nil) async throws -> Int {
        guard let transferer else { return 0 }
        while let running = uploadTask { _ = await running.result }
        let task = Task { try await self.performUploads(transferer, progress: progress) }
        uploadTask = task
        defer { uploadTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performUploads(_ transferer: BlobTransferer, progress: BlobProgressHandler?) async throws -> Int {
        var uploaded = 0
        while let job = try db.pendingBlobUploads(limit: 1).first {
            try Task.checkCancellation()
            guard let state = try db.item(forBlob: job.blob), let ref = state.content?.blob else {
                try db.finishBlobUpload(job.blob)  // the item was deleted: nothing to send
                continue
            }
            do {
                if case .uploaded = try await transferer.upload(ref, item: state.id, progress: progress) { uploaded += 1 }
            } catch let error as BlobTransferError {
                // Not a network problem: retrying won't help, so drop the job rather than block the queue.
                log("dropping upload of blob \(job.blob): \(error)")
            }
            try db.finishBlobUpload(job.blob)
            // Deleted while uploading: garbage collection may already have run, so remove what just landed.
            if try db.item(forBlob: job.blob) == nil, let transport = transport as? any BlobTransport {
                try? await transport.deleteBlob(blobID: job.blob.description)
            }
        }
        return uploaded
    }

    public struct GarbageCollection: Equatable, Sendable {
        /// Files removed from the local blob cache.
        public var localFiles = 0
        /// Blobs deleted from the relay.
        public var relayBlobs = 0
    }

    /// How long a cache file nothing points at is kept before it's removed (an import whose item was never
    /// recorded, or a crashed write).
    public static let orphanBlobAge: TimeInterval = 24 * 60 * 60

    /// Frees the payloads of deleted and expired items. Locally: their cache files, plus old orphans. On the
    /// relay: each dead blob once (best effort; offline just means later). Only blobs of items this device knows
    /// are deleted ever leave the relay. Deletes are sticky, so those can't be needed again; an item this device
    /// hasn't heard of yet is never touched (the harness's `--blob-gc` modes check that rule).
    @discardableResult
    public func collectGarbage() async -> GarbageCollection {
        var result = GarbageCollection()
        guard let blobCache else { return result }
        do {
            let live = try db.liveBlobIDs()
            let dead = Set(try db.deadBlobIDs(limit: Int(Int32.max)))
            result.localFiles = blobCache.collectGarbage(live: live, dead: dead, orphanAge: Self.orphanBlobAge, now: now())
            guard let transport = transport as? any BlobTransport else { return result }
            for blob in try db.deadBlobIDs(uncollectedOnly: true, limit: 100) {
                try await transport.deleteBlob(blobID: blob.description)
                try db.markRelayCollected([blob])
                result.relayBlobs += 1
            }
        } catch {
            log("garbage collection stopped: \(error)")
        }
        return result
    }

    /// Background blob work for `run()`: uploads, then garbage collection, then waits for new work or a minute.
    private func runBlobWork() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await uploadPendingBlobs()
                await collectGarbage()
                failures = 0
                await waitForBlobWork(timeout: .seconds(60))
            } catch {
                if Task.isCancelled { return }
                failures += 1
                let delay = Self.backoff(failures: failures)
                log("blob upload failed (attempt \(failures)), retrying in \(String(format: "%.1f", delay)) s: \(error)")
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func wakeBlobs() {
        blobWorkPending = true
        blobWaiter?.resume()
        blobWaiter = nil
    }

    private func waitForBlobWork(timeout: Duration) async {
        if blobWorkPending {
            blobWorkPending = false
            return
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.wakeBlobs()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                blobWaiter = continuation
            }
        } onCancel: {
            Task { await self.wakeBlobs() }
        }
        timer.cancel()
        blobWorkPending = false
    }

    // MARK: Sync

    /// Pushes every pending op, then pulls until caught up. Concurrent calls run one after another.
    public func syncOnce() async throws {
        while let running = syncTask { _ = await running.result }
        let task = Task { try await self.performSync() }
        syncTask = task
        defer { syncTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSync() async throws {
        status = .syncing
        resetInSync = .none
        do {
            try await pushPending()
            while true {
                try Task.checkCancellation()
                let page: PullResponse
                do {
                    page = try await transport.pull(
                        after: try db.syncCursor(), limit: WireLimits.defaultPullLimit, wait: 0)
                } catch TransportError.cursorAhead(let latestSeq) where resetInSync == .none {
                    // Second line of defense, for a relay that sends no epoch or was restored from a backup (which
                    // keeps its epoch). Once per sync: a second cursorAhead right after resetting to 0 would mean
                    // a broken relay, so it is thrown instead of looping.
                    try recoverFromCursorAhead(relayLatestSeq: latestSeq)
                    resetInSync = .byCursorAhead
                    try await pushPending()
                    continue
                }
                if try handleEpochInSync(page.epoch) {
                    // This page came from a relay that lost ops; skip it, push everything, pull again from 0.
                    try await pushPending()
                    continue
                }
                try apply(page)
                if !page.hasMore || page.envelopes.isEmpty { break }
            }
            status = .idle
            lastSyncedAt = now()
        } catch {
            status = .offline(lastError: String(describing: error))
            throw error
        }
    }

    private func pushPending() async throws {
        while true {
            try Task.checkCancellation()
            let pending = try db.pendingOutbound(limit: WireLimits.maxEnvelopesPerPush)
            if pending.isEmpty { return }
            let envelopes = try pending.map { try cipher.seal($0, device: device) }
            var relayWasReset = false
            for batch in try Self.batches(envelopes) {
                let response = try await transport.push(PushRequest(envelopes: batch))
                try db.markSent(batch.compactMap { UUID(uuidString: $0.opID).map(OpID.init) })
                if try handleEpochInSync(response.epoch) {
                    // Everything is queued again; go back and push it all to the new relay.
                    relayWasReset = true
                    break
                }
            }
            if !relayWasReset, pending.count < WireLimits.maxEnvelopesPerPush { return }
        }
    }

    /// Splits envelopes into pushes of at most `maxCount` envelopes and `maxBytes` of JSON body.
    static func batches(
        _ envelopes: [Envelope],
        maxCount: Int = WireLimits.maxEnvelopesPerPush,
        maxBytes: Int = WireLimits.maxPushBodyBytes
    ) throws -> [[Envelope]] {
        let encoder = JSONEncoder()
        let overhead = try encoder.encode(PushRequest(envelopes: [])).count
        var batches: [[Envelope]] = []
        var current: [Envelope] = []
        var bytes = overhead
        for envelope in envelopes {
            let size = try encoder.encode(envelope).count + 1  // + the separating comma
            if !current.isEmpty, current.count >= maxCount || bytes + size > maxBytes {
                batches.append(current)
                current = []
                bytes = overhead
            }
            current.append(envelope)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Opens and stores one pulled page, and moves the cursor to its last envelope.
    ///
    /// An envelope that fails to open is skipped (and its opID recorded in meta "undecryptable"), and the
    /// cursor still moves past it. Otherwise one corrupt or foreign envelope would stop this device from ever
    /// syncing again. The trade-off: that op is lost to this device, but no honest device can produce one,
    /// since every device holds the same vault key.
    private func apply(_ page: PullResponse) throws {
        guard let last = page.envelopes.last else { return }
        guard let lastSeq = last.seq else { throw SyncError.missingSeq }

        var ops: [Op] = []
        var undecryptable: [String] = []
        for envelope in page.envelopes {
            do {
                ops.append(try cipher.open(envelope))
            } catch {
                undecryptable.append(envelope.opID)
                log("skipping undecryptable envelope seq \(envelope.seq ?? -1) op \(envelope.opID): \(error)")
            }
        }
        if !undecryptable.isEmpty { try recordUndecryptable(undecryptable) }

        if let newest = ops.map(\.timestamp).max() {
            clock.observe(newest)
            try advanceHighWater(newest)
        }
        // max: a long-poll page and a syncOnce page can overlap; never move the cursor backwards.
        let cursor = max(try db.syncCursor(), lastSeq)
        let inserted = try db.insertRemote(ops, newCursor: cursor)
        if !inserted.isEmpty { changesContinuation.yield() }
        if inserted.contains(where: { $0.kind == .delete }) { wakeBlobs() }
    }

    // MARK: Relay reset
    //
    // When the relay loses its log (database deleted, replaced, or restored from an old backup), ops that lived
    // only there are gone. Recovery: queue every stored op for push again and reset the cursor to 0, in one
    // transaction (`markAllOutbound`), then push and pull. Every device re-pushes what it holds and the relay
    // dedupes by opID; re-pulling is safe because applying an op this device already has is a no-op.
    //
    // Detection: mainly the relay epoch. A response with a different epoch than the stored one means a new
    // relay database, even when other devices already refilled it past this device's cursor. `cursorAhead`
    // stays as a second line of defense.

    /// The relay's log ends before our cursor, so it lost data.
    private func recoverFromCursorAhead(relayLatestSeq: Int64) throws {
        let cursor = try db.syncCursor()
        log("relay log ends at seq \(relayLatestSeq), before our cursor \(cursor); re-pushing all ops, re-pulling from 0")
        try db.markAllOutbound()
        wakeBlobs()
    }

    /// Checks a response's epoch during a sync. Returns true when it revealed a relay reset that was just
    /// recovered from (everything queued, cursor at 0); the caller then pushes and pulls again.
    private func handleEpochInSync(_ epoch: String?) throws -> Bool {
        guard let epoch, let stored = try changedEpoch(epoch) else { return false }
        switch resetInSync {
        case .none:
            try recoverFromEpochChange(from: stored, to: epoch)
            resetInSync = .byEpoch
            return true
        case .byCursorAhead:
            // This sync already re-pushed everything after cursorAhead, to this relay: just remember it.
            try db.setMeta(Self.relayEpochKey, epoch)
            return false
        case .byEpoch:
            // A second reset within one sync. Leave the stored epoch alone, so the next sync (or long-poll)
            // sees the change and recovers; no loop within this one.
            log("relay epoch changed again during one sync (now \(epoch)); recovering on the next sync")
            return false
        }
    }

    /// Compares a response's epoch with the stored one and returns the stored one when they differ.
    /// On first contact (nothing stored yet) it stores the epoch and returns nil.
    private func changedEpoch(_ epoch: String) throws -> String? {
        guard let stored = try db.meta(Self.relayEpochKey) else {
            try db.setMeta(Self.relayEpochKey, epoch)
            return nil
        }
        return stored == epoch ? nil : stored
    }

    /// Queues everything for push again (cursor to 0), then stores the new epoch. In that order: a crash in
    /// between only means the next sync recovers once more, which is harmless.
    private func recoverFromEpochChange(from stored: String, to epoch: String) throws {
        log("relay epoch changed from \(stored) to \(epoch), so it lost its log; re-pushing all ops, re-pulling from 0")
        try db.markAllOutbound()
        try db.setMeta(Self.relayEpochKey, epoch)
        wakeBlobs()
    }

    private func recordUndecryptable(_ opIDs: [String]) throws {
        let existing = try db.meta(Self.undecryptableKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let all = Array((existing + opIDs).suffix(Self.maxUndecryptableRecorded))
        let json = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        try db.setMeta(Self.undecryptableKey, json)
    }

    /// Op IDs this device skipped because they didn't decrypt.
    public func undecryptableOpIDs() throws -> [String] {
        try db.meta(Self.undecryptableKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    // MARK: Run loop

    /// Syncs, then long-polls; backs off on errors. Returns when the calling task is cancelled.
    public func run() async {
        // Blob uploads run beside the op loop, so a large file never holds up text.
        let blobWork = transferer == nil ? nil : Task { await self.runBlobWork() }
        defer { blobWork?.cancel() }
        var failures = 0
        while !Task.isCancelled {
            do {
                wakePending = false
                try await syncOnce()
                failures = 0
                if wakePending { continue }
                try await longPoll()
            } catch {
                if Task.isCancelled { break }
                failures += 1
                let delay = Self.backoff(failures: failures)
                log("sync failed (attempt \(failures)), retrying in \(String(format: "%.1f", delay)) s: \(error)")
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
    }

    /// 0.5 s doubling to 30 s, with "equal jitter": a random point in the upper half of the window.
    static func backoff(failures: Int, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> Double {
        let ceiling = min(30, 0.5 * pow(2, Double(max(0, failures - 1))))
        return random(ceiling / 2...ceiling)
    }

    private func longPoll() async throws {
        let cursor = try db.syncCursor()
        let transport = self.transport
        let task = Task {
            try await transport.pull(after: cursor, limit: WireLimits.defaultPullLimit, wait: Self.longPollWait)
        }
        longPollTask = task
        defer { longPollTask = nil }
        let page: PullResponse
        do {
            page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch TransportError.cursorAhead(let latestSeq) {
            // Not a failure: the next syncOnce re-pushes everything and pulls from 0.
            try recoverFromCursorAhead(relayLatestSeq: latestSeq)
            return
        } catch {
            // Cut short by a local op: not a failure, go push it.
            if wakePending, !Task.isCancelled { return }
            throw error
        }
        if let epoch = page.epoch, let stored = try changedEpoch(epoch) {
            // Same as cursorAhead: queue everything; the next syncOnce pushes it and pulls from 0.
            try recoverFromEpochChange(from: stored, to: epoch)
            return
        }
        try apply(page)
        lastSyncedAt = now()
    }

    /// Ends a pending long-poll so the run loop pushes right away.
    private func wake() {
        wakePending = true
        longPollTask?.cancel()
    }

    // MARK: Clock persistence

    private func advanceHighWater(_ ts: HLCTimestamp) throws {
        guard (ts.wallMillis, ts.counter) > highWater else { return }
        highWater = (ts.wallMillis, ts.counter)
        try db.setMeta(Self.clockKey, "\(ts.wallMillis):\(ts.counter)")
    }

    private static func parseClock(_ value: String) -> (wall: UInt64, counter: UInt32)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let wall = UInt64(parts[0]), let counter = UInt32(parts[1]) else { return nil }
        return (wall, counter)
    }

    static func millis(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1000))
    }
}
