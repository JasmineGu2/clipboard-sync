#if os(Windows)
import Foundation
import WinSDK

// Thin helpers over the raw Win32 API. Everything UI runs on the main thread, which is also the main actor:
// the window procedure below hops into `MainActor.assumeIsolated`, and `MainQueuePump` runs the main actor's
// queued work from the message loop (see docs/decisions.md, "The Windows tray app").

/// Private window messages.
let WM_APP_TRAY = UINT(WM_APP) + 1
let WM_APP_REFRESH = UINT(WM_APP) + 2
let WM_APP_SHOW = UINT(WM_APP) + 3

/// A window this app created. The window procedure looks the object up by HWND and forwards messages to it.
@MainActor
protocol Win32Window: AnyObject {
    /// The result to return, or nil to let `DefWindowProcW` handle the message.
    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT?
}

/// The single window procedure for every class this app registers. A `@convention(c)` function can't capture
/// context, so it finds the Swift object in `WindowRegistry` by HWND. Windows calls it on the thread that made the
/// window, which is always the main thread here.
private func windowProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    let raw = Int(bitPattern: hwnd)
    return MainActor.assumeIsolated {
        WindowRegistry.dispatch(raw, message, wParam, lParam)
    }
}

@MainActor
enum WindowRegistry {
    private static var windows: [Int: any Win32Window] = [:]
    private static var classes: Set<String> = []

    /// Keeps `window` alive and routes `hwnd`'s messages to it until `remove`.
    static func add(_ hwnd: HWND, _ window: any Win32Window) {
        windows[Int(bitPattern: hwnd)] = window
    }

    static func remove(_ hwnd: HWND) {
        windows[Int(bitPattern: hwnd)] = nil
    }

    static func dispatch(_ raw: Int, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        if let window = windows[raw], let result = window.handle(message, wParam, lParam) {
            return result
        }
        return DefWindowProcW(HWND(bitPattern: raw), message, wParam, lParam)
    }

    /// Registers a window class once, with the shared window procedure and the app icon.
    static func registerClass(_ name: String) {
        guard !classes.contains(name) else { return }
        classes.insert(name)
        name.withCString(encodedAs: UTF16.self) { className in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = windowProc
            wc.hInstance = GetModuleHandleW(nil)
            wc.hIcon = UI.appIcon
            wc.hIconSm = UI.appIcon
            wc.hCursor = LoadCursorW(nil, UI.resourceID(32512))  // IDC_ARROW
            wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE)
            wc.lpszClassName = className
            _ = RegisterClassExW(&wc)
        }
    }
}

/// Shared look: DPI scale, font, icon.
@MainActor
enum UI {
    private(set) static var dpi: Int32 = 96
    private(set) static var font: HFONT?
    private(set) static var appIcon: HICON?

    /// Call once, before any window exists.
    static func setUp() {
        // System DPI aware: Windows doesn't blur the windows; layout sizes go through `px`.
        _ = SetProcessDPIAware()
        dpi = Int32(GetDpiForSystem())
        var metrics = NONCLIENTMETRICSW()
        metrics.cbSize = UINT(MemoryLayout<NONCLIENTMETRICSW>.size)
        if SystemParametersInfoW(UINT(SPI_GETNONCLIENTMETRICS), metrics.cbSize, &metrics, 0) {
            font = CreateFontIndirectW(&metrics.lfMessageFont)
        }
        appIcon = LoadIconW(nil, resourceID(32512))  // IDI_APPLICATION; a real icon needs a .rc resource
    }

    /// Scales a 96-DPI length to the screen.
    static func px(_ value: Int32) -> Int32 {
        MulDiv(value, dpi, 96)
    }

    /// MAKEINTRESOURCEW, which Swift can't import (it's a cast macro).
    nonisolated static func resourceID(_ id: UInt16) -> UnsafePointer<WCHAR>? {
        UnsafePointer<WCHAR>(bitPattern: UInt(id))
    }

    static func applyFont(_ hwnd: HWND) {
        guard let font else { return }
        _ = SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), 1)
    }

    /// The desktop minus the taskbar, in screen pixels.
    static var workArea: RECT {
        var rect = RECT()
        if !SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &rect, 0) {
            rect = RECT(left: 0, top: 0, right: GetSystemMetrics(SM_CXSCREEN), bottom: GetSystemMetrics(SM_CYSCREEN))
        }
        return rect
    }
}

@MainActor
enum Win32 {
    /// Creates a top-level window (no parent) or a child control (`parent` set). `id` is the control ID that
    /// WM_COMMAND reports for a child.
    static func createWindow(
        className: String, title: String, style: DWORD, exStyle: DWORD = 0,
        x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0,
        parent: HWND? = nil, id: Int32 = 0
    ) -> HWND? {
        className.withCString(encodedAs: UTF16.self) { classPointer in
            title.withCString(encodedAs: UTF16.self) { titlePointer in
                CreateWindowExW(
                    exStyle, classPointer, titlePointer, style, x, y, width, height, parent,
                    id == 0 ? nil : HMENU(bitPattern: Int(id)), GetModuleHandleW(nil), nil)
            }
        }
    }

    /// A child control with the shared font. Visible, so pass styles beyond WS_CHILD | WS_VISIBLE only.
    static func control(
        _ className: String, _ text: String = "", style: Int32 = 0, exStyle: Int32 = 0, parent: HWND, id: Int32
    ) -> HWND? {
        let hwnd = createWindow(
            className: className, title: text, style: DWORD(WS_CHILD | WS_VISIBLE | style), exStyle: DWORD(exStyle),
            parent: parent, id: id)
        if let hwnd { UI.applyFont(hwnd) }
        return hwnd
    }

    static func text(of hwnd: HWND) -> String {
        let length = Int(GetWindowTextLengthW(hwnd))
        guard length > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        let copied = Int(GetWindowTextW(hwnd, &buffer, Int32(buffer.count)))
        return String(decoding: buffer.prefix(max(0, copied)), as: UTF16.self)
    }

    static func setText(_ hwnd: HWND, _ text: String) {
        _ = text.withCString(encodedAs: UTF16.self) { SetWindowTextW(hwnd, $0) }
    }

    /// Sets the text only when it differs, so a static control doesn't flicker on every refresh.
    static func updateText(_ hwnd: HWND, _ text: String) {
        if Self.text(of: hwnd) != text { setText(hwnd, text) }
    }

    static func move(_ hwnd: HWND, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32) {
        _ = MoveWindow(hwnd, x, y, max(0, width), max(0, height), true)
    }

    @discardableResult
    static func messageBox(_ text: String, title: String, flags: Int32, owner: HWND? = nil) -> Int32 {
        text.withCString(encodedAs: UTF16.self) { textPointer in
            title.withCString(encodedAs: UTF16.self) { titlePointer in
                MessageBoxW(owner, textPointer, titlePointer, UINT(flags))
            }
        }
    }

    /// Copies text into a fixed WCHAR array that Swift imports as a tuple (NOTIFYICONDATAW.szTip and friends),
    /// cut to fit and NUL-terminated.
    static func copy<Tuple>(_ text: String, into tuple: inout Tuple) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            let units = raw.bindMemory(to: WCHAR.self)
            guard !units.isEmpty else { return }
            var count = 0
            for unit in text.utf16 {
                if count == units.count - 1 { break }
                units[count] = unit
                count += 1
            }
            units[count] = 0
        }
    }

    // MARK: Menus

    static func appendItem(_ menu: HMENU, id: Int, _ text: String, checked: Bool = false, enabled: Bool = true) {
        var flags = UINT(MF_STRING)
        if checked { flags |= UINT(MF_CHECKED) }
        if !enabled { flags |= UINT(MF_GRAYED) }
        // A single & would underline the next letter (a device name like "R&D PC").
        let label = text.replacingOccurrences(of: "&", with: "&&")
        _ = label.withCString(encodedAs: UTF16.self) { AppendMenuW(menu, flags, UINT_PTR(id), $0) }
    }

    static func appendSeparator(_ menu: HMENU) {
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    static func appendSubmenu(_ menu: HMENU, _ submenu: HMENU, _ text: String) {
        let label = text.replacingOccurrences(of: "&", with: "&&")
        _ = label.withCString(encodedAs: UTF16.self) {
            AppendMenuW(menu, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: submenu)), $0)
        }
    }
}

// MARK: Message parameters (LOWORD, HIWORD, GET_X_LPARAM, MAKELPARAM are macros Swift can't import)

func loWord<T: BinaryInteger>(_ value: T) -> Int {
    Int(truncatingIfNeeded: value) & 0xFFFF
}

func hiWord<T: BinaryInteger>(_ value: T) -> Int {
    (Int(truncatingIfNeeded: value) >> 16) & 0xFFFF
}

/// Signed coordinates packed in an LPARAM (screen coordinates can be negative on a left-hand monitor).
func pointX(_ value: LPARAM) -> Int32 {
    Int32(Int16(truncatingIfNeeded: Int(truncatingIfNeeded: value)))
}

func pointY(_ value: LPARAM) -> Int32 {
    Int32(Int16(truncatingIfNeeded: Int(truncatingIfNeeded: value) >> 16))
}

func makeLParam(_ low: Int32, _ high: Int32) -> LPARAM {
    LPARAM(truncatingIfNeeded: ((Int(high) & 0xFFFF) << 16) | (Int(low) & 0xFFFF))
}

/// Runs the main actor's queued work (Swift tasks, `@MainActor` continuations) from inside a Win32 message loop.
///
/// On Windows the main actor runs on the libdispatch main queue, which only drains when something services it:
/// `dispatchMain()` (which never pumps window messages) or Foundation's RunLoop. One non-blocking RunLoop pass
/// after each message, plus a 50 ms timer so it also runs inside modal loops (menus, message boxes, window drags).
@MainActor
enum MainQueuePump {
    private static var draining = false

    static func drain() {
        // A job that opens a modal loop would otherwise re-enter the queue from the timer.
        guard !draining else { return }
        draining = true
        defer { draining = false }
        _ = RunLoop.main.limitDate(forMode: .default)
    }

    /// The classic GetMessage loop, with keyboard navigation (Tab, Enter, Esc) for whichever of our windows is
    /// active. Returns the exit code from PostQuitMessage.
    static func runMessageLoop() -> Int32 {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if let active = GetActiveWindow(), IsDialogMessageW(active, &message) {
                drain()
                continue
            }
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
            drain()
        }
        return Int32(truncatingIfNeeded: message.wParam)
    }
}
#endif
