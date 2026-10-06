import Foundation
import Observation

/// The Mac's ⌃⌘V picker: a search field over recent items with a keyboard selection. Pure state, so the
/// selection rules are tested here; the panel, hotkey and synthesized paste live in the Mac app.
@MainActor
@Observable
public final class QuickPickModel {
    public private(set) var items: [ClipItem] = []
    /// Index into `items` of the highlighted row. Always valid while `items` isn't empty.
    public private(set) var selection = 0

    /// Bound to the search field. Each change reloads after a short debounce.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleReload()
        }
    }

    public var selectedItem: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    public let limit: Int
    private let history: HistoryModel
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?

    public init(history: HistoryModel, limit: Int = 50, debounce: Duration = .milliseconds(120)) {
        self.history = history
        self.limit = limit
        self.debounce = debounce
    }

    /// Clears the query and loads the newest items. Call each time the picker opens.
    public func reset() async {
        reloadTask?.cancel()
        query = ""
        reloadTask?.cancel()
        await reload()
    }

    /// Re-reads the list for the current query and puts the highlight back on the first row.
    public func reload() async {
        let wanted = query
        let found = await history.lookup(wanted, limit: limit)
        guard wanted == query else { return }  // a newer keystroke's reload wins
        items = found
        selection = 0
    }

    /// Up (-1) or down (+1). Stops at the ends rather than wrapping, like Spotlight.
    public func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    /// Highlights a row the pointer moved to or clicked.
    public func select(_ item: ClipItem) {
        if let index = items.firstIndex(of: item) { selection = index }
    }

    /// Waits for a pending debounced reload. For tests.
    public func waitForReload() async {
        await reloadTask?.value
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        let delay = debounce
        reloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // superseded
            }
            await self?.reload()
        }
    }
}
