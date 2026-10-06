import ClipCore
import ClipStore
import ClipSync
import Foundation
import Observation

/// One history row, ready for display.
public struct ClipItem: Identifiable, Hashable, Sendable {
    public let id: ItemID
    public let text: String
    public let title: String?
    public let tags: [String]
    public let isPinned: Bool
    public let sourceDeviceName: String
    public let createdAt: Date
    public let kind: ContentKind
    /// A small JPEG for image items, synced with the item (F11).
    public let thumbnail: Data?
    /// Images and files: the payload, which downloads on demand (F12).
    public let blobID: BlobID?
    public let fileSize: Int64?
    public let contentType: String?

    /// True for image and file items: copying one downloads it first.
    public var isFile: Bool { blobID != nil }

    /// nil for items that aren't visible (no create op yet, or deleted).
    public init?(_ state: ItemState) {
        guard state.isVisible, let content = state.content else { return nil }
        id = state.id
        text = content.text
        title = state.title.value
        tags = state.visibleTags
        isPinned = state.pinned.value
        sourceDeviceName = content.sourceDeviceName
        createdAt = content.createdAt
        kind = content.kind
        thumbnail = content.thumbnail
        blobID = content.blob?.id
        fileSize = content.blob?.size
        contentType = content.blob?.contentType
    }

    /// The title when set, else the first non-empty line of the text, cut to 200 characters (F4).
    public var headline: String {
        if let title, !title.isEmpty { return title }
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return String(line.prefix(200))
    }
}

/// What the status line shows.
public enum SyncIndicator: Equatable, Sendable {
    case synced(lastSyncedAt: Date?)
    case syncing
    case offline
    /// F13: another device removed this one; syncing has stopped.
    case removed

    public var text: String {
        switch self {
        case .synced: Strings.statusSynced
        case .syncing: Strings.statusSyncing
        case .offline: Strings.statusOffline
        case .removed: Strings.statusRemoved
        }
    }
}

/// The history screen's state and actions, shared by the Mac and iOS apps.
@MainActor
@Observable
public final class HistoryModel {
    public private(set) var pinned: [ClipItem] = []
    public private(set) var recent: [ClipItem] = []
    /// True when the last fetch filled the page, so there may be more.
    public private(set) var canLoadMore = false
    public private(set) var syncStatus: SyncIndicator = .synced(lastSyncedAt: nil)
    /// The last error, as copy. The UI shows it and sets it back to nil.
    public var message: AppMessage?
    /// The item most recently put on the clipboard, for a "Copied" confirmation. Clears itself after
    /// `copiedDuration`; another copy restarts the clock.
    public private(set) var lastCopied: ItemID?
    /// Bumps on every copy. Use it as the haptics trigger: unlike `lastCopied`, it changes even when the
    /// same item is copied twice in a row.
    public private(set) var copyCount = 0
    /// Image and file items downloading for a copy, with progress from 0 to 1.
    public private(set) var downloading: [ItemID: Double] = [:]

    /// Bound to the search field. Changes are debounced before querying.
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }

    /// When true, the newest copy from another device goes on this device's clipboard as it arrives.
    public var receivesLatest = true

    /// Number of fetches that ran a full-text search. Lets tests check the debounce.
    public private(set) var searchQueryCount = 0

    public var isEmpty: Bool { pinned.isEmpty && recent.isEmpty }

    public let pageSize: Int
    private let engine: SyncEngine
    private let db: ClipDatabase
    private let pasteboard: any PasteboardWriter
    private let debounce: Duration
    private let copiedDuration: Duration
    private var limit: Int
    private var searchTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var copiedResetTask: Task<Void, Never>?
    private var follower: LatestClipFollower
    private let thumbnails: any ThumbnailMaker
    /// Copies of downloaded files named like their items, for the clipboard (the cache names files by blob ID).
    public let exportsDirectory: URL

    public init(
        engine: SyncEngine,
        db: ClipDatabase,
        pasteboard: any PasteboardWriter,
        pageSize: Int = 200,
        debounce: Duration = .milliseconds(250),
        copiedDuration: Duration = .milliseconds(1500),
        thumbnails: any ThumbnailMaker = NoThumbnails(),
        exportsDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ClipSyncExports")
    ) {
        self.engine = engine
        self.db = db
        self.pasteboard = pasteboard
        self.thumbnails = thumbnails
        self.exportsDirectory = exportsDirectory
        self.pageSize = pageSize
        self.debounce = debounce
        self.copiedDuration = copiedDuration
        self.limit = pageSize
        self.follower = LatestClipFollower(device: engine.device)
    }

    // MARK: Lifecycle

    /// Loads the first page and refreshes on every `engine.changes` event. Call once; the stream has one consumer.
    public func start() {
        guard changesTask == nil else { return }
        let changes = engine.changes
        changesTask = Task { [weak self] in
            // The baseline comes first, so what is already in the history never overwrites the clipboard.
            await self?.receiveLatest()
            for await _ in changes {
                guard let self else { return }
                await self.refresh()
                await self.receiveLatest()
            }
        }
        Task { await refresh() }
    }

    /// Stops refreshing. The model can't be restarted (the change stream ends with its consumer).
    public func stop() {
        changesTask?.cancel()
        searchTask?.cancel()
        copiedResetTask?.cancel()
        statusTask?.cancel()
        statusTask = nil
    }

    /// While the history is on screen, re-reads the sync status every few seconds, so "Offline" clears
    /// when the run loop reconnects even if nothing new arrived. Off-screen it costs nothing (N4).
    public func setVisible(_ visible: Bool) {
        statusTask?.cancel()
        statusTask = nil
        guard visible else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Loading

    /// Re-reads the current page (or search results) and the sync status. Refreshes run one after another,
    /// so when this returns the lists reflect the database as of this call or later.
    public func refresh() async {
        let previous = refreshTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.load()
        }
        refreshTask = task
        await task.value
    }

    private func load() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { searchQueryCount += 1 }
        switch await Self.fetch(db: db, query: query, limit: limit) {
        case .success(let result):
            let items = result.page.compactMap(ClipItem.init)
            if let pinnedStates = result.pinned {
                // Browsing: the pinned section comes from its own query, so an old pinned item still shows.
                pinned = pinnedStates.compactMap(ClipItem.init)
            } else {
                pinned = items.filter(\.isPinned)
            }
            recent = items.filter { !$0.isPinned }
            canLoadMore = result.page.count >= limit
        case .failure(let error):
            message = AppMessage(error)
        }
        await updateStatus()
    }

    /// Shows another page.
    public func loadMore() async {
        guard canLoadMore else { return }
        limit += pageSize
        await refresh()
    }

    /// Items for another view of the history (the Mac's quick picker), independent of `searchText`: the newest
    /// `limit` items, pinned ones included, or the matches for `query`. Errors give an empty list.
    public func lookup(_ query: String, limit: Int) async -> [ClipItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = self.db
        let result = await Task.detached { () -> Result<[ItemState], any Error> in
            Result { query.isEmpty ? try db.items(limit: limit) : try db.search(query, limit: limit) }
        }.value
        return ((try? result.get()) ?? []).compactMap(ClipItem.init)
    }

    /// Waits for a pending debounced search. For tests.
    public func waitForSearch() async {
        await searchTask?.value
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        limit = pageSize
        let delay = debounce
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // Superseded by a newer keystroke.
            }
            await self?.refresh()
        }
    }

    /// Runs the query off the main actor. The database serializes its own calls.
    /// `pinned` is nil for searches, which keep splitting their own results.
    nonisolated private static func fetch(
        db: ClipDatabase, query: String, limit: Int
    ) async -> Result<(page: [ItemState], pinned: [ItemState]?), any Error> {
        Result {
            if query.isEmpty {
                return (try db.items(limit: limit), try db.pinnedItems())
            }
            return (try db.search(query, limit: limit), nil)
        }
    }

    private func updateStatus() async {
        let status = await engine.status
        let last = await engine.lastSyncedAt
        switch status {
        case .idle: syncStatus = .synced(lastSyncedAt: last)
        case .syncing: syncStatus = .syncing
        case .offline: syncStatus = .offline
        case .revoked: syncStatus = .removed
        }
    }

    // MARK: Actions

    /// F3: puts the item on this device's clipboard. Text goes at once; an image or file downloads first
    /// (resuming an earlier try), then goes on as a file named like the item.
    public func copy(_ item: ClipItem) {
        if item.isFile {
            Task { await copyFile(item) }
            return
        }
        pasteboard.write(text: item.text)
        markCopied(item.id)
    }

    /// The image-or-file half of `copy`, awaitable for tests. A second tap while it downloads does nothing.
    public func copyFile(_ item: ClipItem) async {
        guard item.isFile, downloading[item.id] == nil else { return }
        downloading[item.id] = 0
        defer { downloading[item.id] = nil }
        let id = item.id
        do {
            let cached = try await engine.fetchBlob(for: id) { [weak self] progress in
                let fraction = Double(progress.done) / Double(max(1, progress.total))
                Task { @MainActor in
                    // Only while still downloading: a late update mustn't bring the entry back.
                    if self?.downloading[id] != nil { self?.downloading[id] = fraction }
                }
            }
            let exported = try Self.export(cached, as: item, to: exportsDirectory)
            pasteboard.write(fileAt: exported, contentType: item.contentType)
            markCopied(id)
        } catch {
            message = AppMessage(error)
        }
    }

    /// `<exports>/<item ID>/<item name>`: a copy (a clone on APFS, so no extra space), written to a temporary
    /// name and renamed, so a half-finished copy is never reused. Not a hard link: an app editing the pasted file
    /// in place would change the cached blob, and a later re-upload would no longer match its SHA-256.
    nonisolated static func export(_ cached: URL, as item: ClipItem, to exports: URL) throws -> URL {
        let folder = exports.appendingPathComponent(item.id.description, isDirectory: true)
        let name = FileTypes.safeFileName(item.text, fallback: item.id.description)
        let destination = folder.appendingPathComponent(name)
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) { return destination }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        try files.copyItem(at: cached, to: temp)
        do {
            try files.moveItem(at: temp, to: destination)
        } catch {
            try? files.removeItem(at: temp)
            if !files.fileExists(atPath: destination.path) { throw error }
        }
        return destination
    }

    /// Removes exported copies older than `age`; called at launch. By then nothing still needs them on the
    /// clipboard, and the cache keeps the real copy.
    nonisolated public static func cleanExports(in exports: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let files = FileManager.default
        for folder in (try? files.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)) ?? [] {
            let modified = (try? files.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
            if let modified, now.timeIntervalSince(modified) > age { try? files.removeItem(at: folder) }
        }
    }

    private func markCopied(_ id: ItemID) {
        lastCopied = id
        copyCount += 1
        copiedResetTask?.cancel()
        let delay = copiedDuration
        copiedResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // A newer copy restarted the clock.
            }
            self?.lastCopied = nil
        }
    }

    // MARK: Images and files (F11, F12)

    /// The Mac watcher's path for anything it captured. Like `capture(_ text:)`, problems are quiet: the user
    /// didn't ask to send this, so an alert about a too-large file later would be confusing.
    @discardableResult
    public func capture(_ clip: Clip) async -> Bool {
        switch clip {
        case .text(let text):
            return await capture(text)
        case .image(let image):
            return await addImage(image, quietly: true)
        case .files(let urls):
            var added = false
            for url in urls where await addFile(url, name: nil, quietly: true) { added = true }
            return added
        }
    }

    /// F2 for images and files on iOS (paste button, share sheet in the app): adds it and syncs once.
    /// The upload itself runs in the background; the item shows on other devices straight away.
    @discardableResult
    public func sendFile(_ url: URL, name: String? = nil) async -> Bool {
        guard await addFile(url, name: name, quietly: false) else { return false }
        try? await engine.syncOnce()
        await updateStatus()
        return true
    }

    @discardableResult
    public func sendImage(_ image: PasteboardImage) async -> Bool {
        guard await addImage(image, quietly: false) else { return false }
        try? await engine.syncOnce()
        await updateStatus()
        return true
    }

    private func addImage(_ image: PasteboardImage, quietly: Bool) async -> Bool {
        let ext = FileTypes.fileExtension(forContentType: image.contentType) ?? "png"
        let thumbnails = self.thumbnails
        let data = image.data
        let thumbnail = await Task.detached {
            thumbnails.thumbnail(for: data, maxBytes: ItemContent.maxThumbnailBytes)
        }.value
        let name = Strings.format(Strings.clipboardImageName, ["ext": ext])
        return await addBlob(quietly: quietly) {
            try await $0.addData(data, kind: .image, name: name, contentType: image.contentType, thumbnail: thumbnail)
        }
    }

    private func addFile(_ url: URL, name: String?, quietly: Bool) async -> Bool {
        let shown = name ?? url.lastPathComponent
        let type = FileTypes.contentType(forName: shown)
        let kind = FileTypes.kind(forContentType: type)
        let thumbnails = self.thumbnails
        // ImageIO can take a while on a large photo, so not on the main actor.
        let thumbnail = kind == .image
            ? await Task.detached { thumbnails.thumbnail(forFileAt: url, maxBytes: ItemContent.maxThumbnailBytes) }.value
            : nil
        return await addBlob(quietly: quietly) {
            try await $0.addFile(at: url, kind: kind, name: shown, contentType: type, thumbnail: thumbnail)
        }
    }

    private func addBlob(quietly: Bool, _ body: (SyncEngine) async throws -> ItemID) async -> Bool {
        do {
            _ = try await body(engine)
        } catch {
            if !quietly { message = AppMessage(error) }
            return false
        }
        await refresh()
        return true
    }

    /// Puts the newest item on the clipboard when another device just made it (see `LatestClipFollower`).
    /// The follower keeps tracking while `receivesLatest` is off, so turning it back on doesn't replay
    /// an old item.
    private func receiveLatest() async {
        guard case .success(let newest) = await Self.newest(db: db) else { return }
        guard let text = follower.update(newest: newest), receivesLatest else { return }
        pasteboard.write(text: text)
    }

    /// The newest visible item, read off the main actor.
    nonisolated private static func newest(db: ClipDatabase) async -> Result<ItemState?, any Error> {
        Result { try db.items(limit: 1).first }
    }

    /// Waits until the "Copied" confirmation clears. For tests.
    public func waitForCopiedReset() async {
        await copiedResetTask?.value
    }

    /// F2: adds text to the history, then syncs once. Offline is fine: the item is saved and syncs later.
    /// Returns false (and sets `message`) when the text can't be added.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        guard await add(text) else { return false }
        try? await engine.syncOnce()
        await updateStatus()
        return true
    }

    /// F1: the Mac watcher's path. The run loop pushes it right away, so no extra sync here.
    /// Text the relay can't take (over the per-op cap) is skipped quietly: the user didn't ask to send it,
    /// so an alert about it later would be confusing.
    @discardableResult
    public func capture(_ text: String) async -> Bool {
        await add(text, quietly: [.tooLarge, .emptyText])
    }

    public func syncNow() async {
        try? await engine.syncOnce()
        await refresh()
    }

    public func togglePin(_ item: ClipItem) async {
        await perform { try await $0.setPinned(item.id, !item.isPinned) }
    }

    /// An empty or whitespace title clears it.
    public func rename(_ item: ClipItem, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform { try await $0.setTitle(item.id, trimmed.isEmpty ? nil : trimmed) }
    }

    public func addTag(_ item: ClipItem, _ tag: String) async {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try await $0.setTag(item.id, trimmed, present: true) }
    }

    public func removeTag(_ item: ClipItem, _ tag: String) async {
        await perform { try await $0.setTag(item.id, tag, present: false) }
    }

    public func delete(_ item: ClipItem) async {
        await perform { try await $0.delete(item.id) }
    }

    private func add(_ text: String, quietly: Set<AppMessage> = []) async -> Bool {
        do {
            try await engine.addText(text)
        } catch {
            let mapped = AppMessage(error)
            if !quietly.contains(mapped) { message = mapped }
            return false
        }
        await refresh()
        return true
    }

    private func perform(_ body: (SyncEngine) async throws -> Void) async {
        do {
            try await body(engine)
        } catch {
            message = AppMessage(error)
        }
        await refresh()
    }
}
