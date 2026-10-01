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

    public var text: String {
        switch self {
        case .synced: Strings.statusSynced
        case .syncing: Strings.statusSyncing
        case .offline: Strings.statusOffline
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
    /// The item most recently put on the clipboard, for a "Copied" confirmation.
    public private(set) var lastCopied: ItemID?

    /// Bound to the search field. Changes are debounced before querying.
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }

    /// Number of fetches that ran a full-text search. Lets tests check the debounce.
    public private(set) var searchQueryCount = 0

    public var isEmpty: Bool { pinned.isEmpty && recent.isEmpty }

    public let pageSize: Int
    private let engine: SyncEngine
    private let db: ClipDatabase
    private let pasteboard: any PasteboardWriter
    private let debounce: Duration
    private var limit: Int
    private var searchTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(
        engine: SyncEngine,
        db: ClipDatabase,
        pasteboard: any PasteboardWriter,
        pageSize: Int = 200,
        debounce: Duration = .milliseconds(250)
    ) {
        self.engine = engine
        self.db = db
        self.pasteboard = pasteboard
        self.pageSize = pageSize
        self.debounce = debounce
        self.limit = pageSize
    }

    // MARK: Lifecycle

    /// Loads the first page and refreshes on every `engine.changes` event. Call once; the stream has one consumer.
    public func start() {
        guard changesTask == nil else { return }
        let changes = engine.changes
        changesTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Stops refreshing. The model can't be restarted (the change stream ends with its consumer).
    public func stop() {
        changesTask?.cancel()
        searchTask?.cancel()
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
        case .success(let states):
            let items = states.compactMap(ClipItem.init)
            pinned = items.filter(\.isPinned)
            recent = items.filter { !$0.isPinned }
            canLoadMore = states.count >= limit
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
    nonisolated private static func fetch(db: ClipDatabase, query: String, limit: Int) async -> Result<[ItemState], any Error> {
        Result {
            query.isEmpty ? try db.items(limit: limit) : try db.search(query, limit: limit)
        }
    }

    private func updateStatus() async {
        let status = await engine.status
        let last = await engine.lastSyncedAt
        switch status {
        case .idle: syncStatus = .synced(lastSyncedAt: last)
        case .syncing: syncStatus = .syncing
        case .offline: syncStatus = .offline
        }
    }

    // MARK: Actions

    /// F3: puts the item's text on this device's clipboard.
    public func copy(_ item: ClipItem) {
        pasteboard.write(text: item.text)
        lastCopied = item.id
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
