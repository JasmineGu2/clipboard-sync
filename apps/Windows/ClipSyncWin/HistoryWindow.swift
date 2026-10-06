#if os(Windows)
import ClipAppCore
import ClipCore
import Foundation
import WinSDK

/// The history: a search box over a list, newest first (pinned on top), each row with time, device and text.
/// Click copies, Enter or double-click copies and hides, right-click pins, renames or deletes. Closing only hides
/// it; the tray icon and Ctrl+Shift+V bring it back. All state comes from ClipAppCore's HistoryModel.
@MainActor
final class HistoryWindow: Win32Window {
    static let className = "ClipSyncWin.History"
    private enum ID {
        static let search: Int32 = 101
        static let list: Int32 = 102
        static let status: Int32 = 103
        static let hint: Int32 = 104
    }
    private enum Command: Int {
        case copy = 401, pin, rename, delete
    }
    private enum Row: Equatable {
        case item(ClipItem)
        case loadMore
    }

    let hwnd: HWND
    private let history: HistoryModel
    private let onRename: @MainActor (ClipItem) -> Void
    private var search: HWND!
    private var list: HWND!
    private var status: HWND!
    private var hint: HWND!
    private var rows: [Row] = []
    private var labels: [String] = []
    private var contextItem: ClipItem?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init?(history: HistoryModel, onRename: @escaping @MainActor (ClipItem) -> Void) {
        WindowRegistry.registerClass(HistoryWindow.className)
        let width = UI.px(460)
        let height = UI.px(560)
        let work = UI.workArea
        // Bottom right, above the notification area, like other tray apps' popups.
        guard let hwnd = Win32.createWindow(
            className: HistoryWindow.className, title: WinStrings.historyWindowTitle,
            style: DWORD(WS_CAPTION | WS_SYSMENU | WS_THICKFRAME), exStyle: DWORD(WS_EX_TOOLWINDOW),
            x: work.right - width - UI.px(12), y: work.bottom - height - UI.px(12), width: width, height: height)
        else { return nil }
        self.hwnd = hwnd
        self.history = history
        self.onRename = onRename
        WindowRegistry.add(hwnd, self)
        search = Win32.control(
            "EDIT", style: WS_TABSTOP | ES_AUTOHSCROLL, exStyle: WS_EX_CLIENTEDGE, parent: hwnd, id: ID.search)
        list = Win32.control(
            "LISTBOX", style: WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT,
            exStyle: WS_EX_CLIENTEDGE, parent: hwnd, id: ID.list)
        status = Win32.control("STATIC", style: SS_NOPREFIX | SS_ENDELLIPSIS, parent: hwnd, id: ID.status)
        hint = Win32.control("STATIC", WinStrings.historyHint, style: SS_NOPREFIX, parent: hwnd, id: ID.hint)
        guard search != nil, list != nil, status != nil, hint != nil else {
            WindowRegistry.remove(hwnd)
            DestroyWindow(hwnd)
            return nil
        }
        layout()
    }

    var isVisible: Bool { IsWindowVisible(hwnd) }

    func show() {
        _ = ShowWindow(hwnd, SW_SHOW)
        _ = SetForegroundWindow(hwnd)
        _ = SetFocus(search)
        _ = SendMessageW(search, UINT(EM_SETSEL), 0, -1)
        history.setVisible(true)
    }

    func hide() {
        _ = ShowWindow(hwnd, SW_HIDE)
        history.setVisible(false)
    }

    func toggle() {
        if isVisible && GetForegroundWindow() == hwnd { hide() } else { show() }
    }

    /// Re-reads the model. Called inside the app's observation tracking, so it reads every property it shows.
    /// The list is only rebuilt when a row changed, which keeps the selection and scroll position steady while
    /// the sync status ticks.
    func render(capturePaused: Bool) {
        var newRows = (history.pinned + history.recent).map(Row.item)
        if history.canLoadMore { newRows.append(.loadMore) }
        let newLabels = newRows.map(label)
        if newLabels != labels || newRows != rows {
            rebuildList(newRows, newLabels)
        }
        Win32.updateText(status, statusText(capturePaused: capturePaused))
    }

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case UINT(WM_SIZE):
            layout()
            return 0
        case UINT(WM_CLOSE):
            hide()
            return 0
        case UINT(WM_SETFOCUS):
            // Activated with no focused control (Alt+Tab back): typing goes to the search box.
            _ = SetFocus(search)
            return 0
        case UINT(WM_COMMAND):
            return command(id: Int32(loWord(wParam)), code: Int32(hiWord(wParam)))
        case UINT(WM_PARENTNOTIFY):
            // Sent for a click on any child, including one on the row that is already selected (which LBN_SELCHANGE
            // misses). lParam is the point in this window's client coordinates.
            if loWord(wParam) == Int(WM_LBUTTONDOWN) {
                clicked(at: POINT(x: pointX(lParam), y: pointY(lParam)))
            }
            return nil
        case UINT(WM_CONTEXTMENU):
            guard Int(truncatingIfNeeded: wParam) == Int(bitPattern: list) else { return nil }
            showContextMenu(screenPoint: POINT(x: pointX(lParam), y: pointY(lParam)))
            return 0
        default:
            return nil
        }
    }

    // MARK: Input

    private func command(id: Int32, code: Int32) -> LRESULT? {
        switch id {
        case ID.search where code == EN_CHANGE:
            let text = Win32.text(of: search)
            if history.searchText != text { history.searchText = text }
        case ID.list where code == LBN_DBLCLK:
            activate(row: selectedIndex, hideAfter: true)
        case IDOK:
            // Enter: the selected row, or the top one when typing in the search box.
            activate(row: selectedIndex ?? (rows.isEmpty ? nil : 0), hideAfter: true)
        case IDCANCEL:
            hide()
        case Int32(Command.copy.rawValue):
            if let item = contextItem { history.copy(item) }
        case Int32(Command.pin.rawValue):
            if let item = contextItem {
                let history = self.history
                Task { await history.togglePin(item) }
            }
        case Int32(Command.rename.rawValue):
            if let item = contextItem { onRename(item) }
        case Int32(Command.delete.rawValue):
            if let item = contextItem {
                let history = self.history
                Task { await history.delete(item) }
            }
        default:
            return nil
        }
        return 0
    }

    private func clicked(at point: POINT) {
        var screen = point
        _ = ClientToScreen(hwnd, &screen)
        guard let index = rowIndex(atScreen: screen) else { return }
        activate(row: index, hideAfter: false)
    }

    /// The row under a screen point, or nil when the point isn't over a row (the scroll bar, empty space).
    private func rowIndex(atScreen point: POINT) -> Int? {
        var local = point
        _ = ScreenToClient(list, &local)
        var client = RECT()
        _ = GetClientRect(list, &client)
        guard local.x >= client.left, local.x < client.right, local.y >= client.top, local.y < client.bottom else {
            return nil
        }
        let result = SendMessageW(list, UINT(LB_ITEMFROMPOINT), 0, makeLParam(local.x, local.y))
        guard hiWord(result) == 0 else { return nil }  // high word 1: below the last row
        let index = loWord(result)
        return rows.indices.contains(index) ? index : nil
    }

    private func activate(row index: Int?, hideAfter: Bool) {
        guard let index, rows.indices.contains(index) else { return }
        switch rows[index] {
        case .loadMore:
            let history = self.history
            Task { await history.loadMore() }
        case .item(let item):
            history.copy(item)
            if hideAfter { hide() }
        }
    }

    private var selectedIndex: Int? {
        let index = Int(truncatingIfNeeded: SendMessageW(list, UINT(LB_GETCURSEL), 0, 0))
        return rows.indices.contains(index) ? index : nil
    }

    private func showContextMenu(screenPoint: POINT) {
        var point = screenPoint
        let index: Int?
        if point.x == -1 && point.y == -1 {
            // From the keyboard (Shift+F10 or the menu key): the selected row, menu at the list's corner.
            index = selectedIndex
            var frame = RECT()
            _ = GetWindowRect(list, &frame)
            point = POINT(x: frame.left + UI.px(24), y: frame.top + UI.px(24))
        } else {
            index = rowIndex(atScreen: point)
            if let index { _ = SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(index), 0) }
        }
        guard let index, case .item(let item) = rows[index], let menu = CreatePopupMenu() else { return }
        contextItem = item
        Win32.appendItem(menu, id: Command.copy.rawValue, Strings.actionCopy)
        Win32.appendItem(menu, id: Command.pin.rawValue, item.isPinned ? Strings.actionUnpin : Strings.actionPin)
        Win32.appendItem(menu, id: Command.rename.rawValue, WinStrings.actionRenameMenu)
        Win32.appendSeparator(menu)
        Win32.appendItem(menu, id: Command.delete.rawValue, Strings.actionDelete)
        _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, hwnd, nil)
        _ = DestroyMenu(menu)
    }

    // MARK: Drawing

    private func label(_ row: Row) -> String {
        switch row {
        case .loadMore:
            return Strings.loadMore
        case .item(let item):
            let filled = Strings.format(WinStrings.rowFormat, [
                "time": dateFormatter.string(from: item.createdAt),
                "device": item.sourceDeviceName,
                "pin": item.isPinned ? WinStrings.pinnedMarker + " " : "",
            ])
            // Text last, so a clip that happens to contain "{time}" isn't filled in.
            return filled.replacingOccurrences(of: "{text}", with: String(item.headline.prefix(160)))
        }
    }

    private func rebuildList(_ newRows: [Row], _ newLabels: [String]) {
        let selectedID: ItemID? = selectedIndex.flatMap { index in
            if case .item(let item) = rows[index] { return item.id }
            return nil
        }
        let top = SendMessageW(list, UINT(LB_GETTOPINDEX), 0, 0)
        _ = SendMessageW(list, UINT(WM_SETREDRAW), 0, 0)
        _ = SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0)
        for label in newLabels {
            _ = label.withCString(encodedAs: UTF16.self) { pointer in
                SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: pointer)))
            }
        }
        rows = newRows
        labels = newLabels
        if let selectedID, let index = rows.firstIndex(where: {
            if case .item(let item) = $0 { return item.id == selectedID }
            return false
        }) {
            _ = SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(index), 0)
        }
        _ = SendMessageW(list, UINT(LB_SETTOPINDEX), WPARAM(truncatingIfNeeded: max(0, Int(truncatingIfNeeded: top))), 0)
        _ = SendMessageW(list, UINT(WM_SETREDRAW), 1, 0)
        _ = InvalidateRect(list, nil, true)
    }

    private func statusText(capturePaused: Bool) -> String {
        if history.lastCopied != nil { return Strings.copied }
        if history.isEmpty {
            return history.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? Strings.emptyHistory : Strings.noResults
        }
        switch history.syncStatus {
        case .synced where capturePaused: return Strings.capturePaused
        default: return history.syncStatus.text
        }
    }

    private func layout() {
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let width = client.right - client.left
        let height = client.bottom - client.top
        let margin = UI.px(8)
        let fieldHeight = UI.px(24)
        let textHeight = UI.px(18)
        let hintHeight = UI.px(34)
        let listTop = margin + fieldHeight + margin
        let statusTop = height - margin - hintHeight - textHeight
        Win32.move(search, margin, margin, width - 2 * margin, fieldHeight)
        Win32.move(list, margin, listTop, width - 2 * margin, statusTop - margin - listTop)
        Win32.move(status, margin, statusTop, width - 2 * margin, textHeight)
        Win32.move(hint, margin, statusTop + textHeight, width - 2 * margin, hintHeight)
    }
}
#endif
