#if os(Windows)
import ClipAppCore
import WinSDK

/// The notification-area icon (Shell_NotifyIconW). Mouse events arrive at the owner window as `WM_APP_TRAY`,
/// with the mouse message in the low word of lParam (the pre-Vista callback format, which is enough here).
@MainActor
final class TrayIcon {
    static let iconID: UINT = 1

    private let owner: HWND
    private var tooltip = ""

    init(owner: HWND) {
        self.owner = owner
    }

    /// Adds the icon. Call again after Explorer restarts (the "TaskbarCreated" message): the old icon is gone.
    func add(tooltip: String) {
        self.tooltip = tooltip
        var data = baseData()
        data.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        data.uCallbackMessage = WM_APP_TRAY
        data.hIcon = UI.appIcon
        Win32.copy(tooltip, into: &data.szTip)
        _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)
    }

    func setTooltip(_ text: String) {
        guard text != tooltip else { return }
        tooltip = text
        var data = baseData()
        data.uFlags = UINT(NIF_TIP)
        Win32.copy(text, into: &data.szTip)
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    /// A toast-style notification next to the icon.
    func notify(_ text: String) {
        var data = baseData()
        data.uFlags = UINT(NIF_INFO)
        data.dwInfoFlags = DWORD(NIIF_INFO)
        Win32.copy(text, into: &data.szInfo)
        Win32.copy(Strings.appName, into: &data.szInfoTitle)
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    func remove() {
        var data = baseData()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
    }

    private func baseData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = owner
        data.uID = Self.iconID
        return data
    }
}
#endif
