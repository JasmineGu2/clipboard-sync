#if os(Windows)
import WinSDK

/// A small window with a message, one text field and two buttons. Used to rename an item (editable field) and to
/// show a pairing code (read-only field, so the code can be selected and copied). Not modal: it lives until closed,
/// kept alive by `WindowRegistry`.
@MainActor
final class PromptWindow: Win32Window {
    static let className = "ClipSyncWin.Prompt"
    private static let labelID: Int32 = 201
    private static let fieldID: Int32 = 202
    private static let secondaryID: Int32 = 203

    let hwnd: HWND
    private let label: HWND
    private let field: HWND
    private let primaryButton: HWND
    private let secondaryButton: HWND
    private let onPrimary: @MainActor (String) -> Void
    private let onSecondary: @MainActor () -> Void
    private let onClose: @MainActor () -> Void

    /// - Parameters:
    ///   - onPrimary: the button or Enter, with the field's text. Close the window from here if that's wanted.
    ///   - onSecondary: the second button. Esc and the close box only close.
    ///   - onClose: after the window is gone, whatever closed it.
    init?(
        title: String, message: String, text: String, readOnly: Bool, primary: String, secondary: String,
        onPrimary: @escaping @MainActor (String) -> Void, onSecondary: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        WindowRegistry.registerClass(PromptWindow.className)
        let width = UI.px(440)
        let height = UI.px(230)
        let work = UI.workArea
        guard let hwnd = Win32.createWindow(
            className: PromptWindow.className, title: title,
            style: DWORD(WS_CAPTION | WS_SYSMENU), exStyle: DWORD(WS_EX_TOOLWINDOW),
            x: work.left + (work.right - work.left - width) / 2, y: work.top + (work.bottom - work.top - height) / 2,
            width: width, height: height)
        else { return nil }
        guard let label = Win32.control("STATIC", message, style: SS_NOPREFIX, parent: hwnd, id: PromptWindow.labelID),
              let field = Win32.control(
                  "EDIT", text, style: WS_TABSTOP | ES_AUTOHSCROLL | (readOnly ? ES_READONLY : 0),
                  exStyle: WS_EX_CLIENTEDGE, parent: hwnd, id: PromptWindow.fieldID),
              let primaryButton = Win32.control(
                  "BUTTON", primary, style: WS_TABSTOP | BS_DEFPUSHBUTTON, parent: hwnd, id: IDOK),
              let secondaryButton = Win32.control(
                  "BUTTON", secondary, style: WS_TABSTOP | BS_PUSHBUTTON, parent: hwnd, id: PromptWindow.secondaryID)
        else {
            DestroyWindow(hwnd)
            return nil
        }
        self.hwnd = hwnd
        self.label = label
        self.field = field
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onClose = onClose
        WindowRegistry.add(hwnd, self)
        layout()
        show()
    }

    func show() {
        _ = ShowWindow(hwnd, SW_SHOW)
        _ = SetForegroundWindow(hwnd)
        _ = SetFocus(field)
        _ = SendMessageW(field, UINT(EM_SETSEL), 0, -1)  // select all, ready to copy or retype
    }

    func setText(_ text: String) {
        Win32.setText(field, text)
        _ = SendMessageW(field, UINT(EM_SETSEL), 0, -1)
    }

    func close() {
        _ = DestroyWindow(hwnd)
    }

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case UINT(WM_COMMAND):
            switch Int32(loWord(wParam)) {
            case IDOK: onPrimary(Win32.text(of: field))
            case Self.secondaryID: onSecondary()
            case IDCANCEL: close()
            default: return nil
            }
            return 0
        case UINT(WM_CLOSE):
            close()
            return 0
        case UINT(WM_DESTROY):
            WindowRegistry.remove(hwnd)
            onClose()
            return 0
        default:
            return nil
        }
    }

    private func layout() {
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let width = client.right - client.left
        let height = client.bottom - client.top
        let margin = UI.px(12)
        let buttonWidth = UI.px(100)
        let buttonHeight = UI.px(28)
        let fieldHeight = UI.px(24)
        let buttonsTop = height - margin - buttonHeight
        let fieldTop = buttonsTop - margin - fieldHeight
        Win32.move(label, margin, margin, width - 2 * margin, fieldTop - 2 * margin)
        Win32.move(field, margin, fieldTop, width - 2 * margin, fieldHeight)
        Win32.move(primaryButton, width - margin - buttonWidth, buttonsTop, buttonWidth, buttonHeight)
        Win32.move(secondaryButton, width - 2 * margin - 2 * buttonWidth, buttonsTop, buttonWidth, buttonHeight)
    }
}
#endif
