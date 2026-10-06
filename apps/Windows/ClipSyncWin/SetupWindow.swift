#if os(Windows)
import ClipAppCore
import WinSDK

/// First-run setup: server URL and device name, then either create a new vault or join one with a pairing code
/// from another device. Mirrors the Mac's OnboardingView; ClipApp does the work.
@MainActor
final class SetupWindow: Win32Window {
    static let className = "ClipSyncWin.Setup"
    private enum ID {
        static let server: Int32 = 311
        static let name: Int32 = 312
        static let code: Int32 = 313
        static let create: Int32 = 321
        static let join: Int32 = 322
        static let staticText: Int32 = 330
    }

    let hwnd: HWND
    private let app: ClipApp
    private let onClose: @MainActor () -> Void
    private var serverField: HWND!
    private var nameField: HWND!
    private var codeField: HWND!
    private var createButton: HWND!
    private var joinButton: HWND!
    private var messageLabel: HWND!
    /// Every control in top-to-bottom order with its height, for `layout`.
    private var rows: [(HWND, Int32)] = []

    init?(app: ClipApp, onClose: @escaping @MainActor () -> Void) {
        WindowRegistry.registerClass(SetupWindow.className)
        let width = UI.px(480)
        let height = UI.px(600)
        let work = UI.workArea
        guard let hwnd = Win32.createWindow(
            className: SetupWindow.className, title: Strings.onboardingTitle,
            style: DWORD(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX),
            x: work.left + (work.right - work.left - width) / 2, y: work.top + (work.bottom - work.top - height) / 2,
            width: width, height: height)
        else { return nil }
        self.hwnd = hwnd
        self.app = app
        self.onClose = onClose
        WindowRegistry.add(hwnd, self)

        let text = UI.px(18)
        let hint = UI.px(34)
        let field = UI.px(24)
        let button = UI.px(30)
        addStatic(Strings.onboardingIntro, height: hint)
        addStatic(Strings.serverLabel, height: text)
        serverField = addField(id: ID.server, text: "", height: field)
        addStatic(Strings.serverHint, height: UI.px(50))
        addStatic(Strings.deviceNameLabel, height: text)
        nameField = addField(id: ID.name, text: app.deviceName, height: field)
        addStatic(Strings.deviceNameHint, height: hint)
        createButton = addButton(Strings.createVault, id: ID.create, height: button)
        addStatic(Strings.createVaultHint, height: text)
        addStatic(Strings.codeLabel, height: text)
        codeField = addField(id: ID.code, text: "", height: field)
        joinButton = addButton(Strings.joinVault, id: ID.join, height: button)
        addStatic(Strings.joinVaultHint, height: hint)
        messageLabel = addStatic("", height: hint)
        layout()
        render()
        show()
    }

    func show() {
        _ = ShowWindow(hwnd, SW_SHOW)
        _ = SetForegroundWindow(hwnd)
        _ = SetFocus(serverField)
    }

    func close() {
        _ = DestroyWindow(hwnd)
    }

    /// Reflects ClipApp's state: buttons off while working, the last error or "Connecting…" underneath.
    func render() {
        let working = app.state == .working
        _ = EnableWindow(createButton, !working)
        _ = EnableWindow(joinButton, !working)
        Win32.updateText(messageLabel, working ? Strings.working : (app.message?.text ?? ""))
    }

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case UINT(WM_COMMAND):
            switch Int32(loWord(wParam)) {
            case ID.create: create()
            case ID.join: join()
            // Enter joins only from the code field: creating a vault by accident is worse than a missed Enter.
            case IDOK: if GetFocus() == codeField { join() }
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

    private func create() {
        guard app.state == .needsSetup else { return }
        let server = Win32.text(of: serverField)
        let name = Win32.text(of: nameField)
        let app = self.app
        Task { await app.createVault(server: server, deviceName: name) }
    }

    private func join() {
        guard app.state == .needsSetup else { return }
        let server = Win32.text(of: serverField)
        let name = Win32.text(of: nameField)
        let code = Win32.text(of: codeField)
        let app = self.app
        Task { await app.joinVault(server: server, code: code, deviceName: name) }
    }

    // MARK: Building

    @discardableResult
    private func addStatic(_ text: String, height: Int32) -> HWND? {
        let control = Win32.control("STATIC", text, style: SS_NOPREFIX, parent: hwnd, id: ID.staticText)
        if let control { rows.append((control, height)) }
        return control
    }

    private func addField(id: Int32, text: String, height: Int32) -> HWND? {
        let control = Win32.control(
            "EDIT", text, style: WS_TABSTOP | ES_AUTOHSCROLL, exStyle: WS_EX_CLIENTEDGE, parent: hwnd, id: id)
        if let control { rows.append((control, height)) }
        return control
    }

    private func addButton(_ text: String, id: Int32, height: Int32) -> HWND? {
        let control = Win32.control("BUTTON", text, style: WS_TABSTOP | BS_PUSHBUTTON, parent: hwnd, id: id)
        if let control { rows.append((control, height)) }
        return control
    }

    private func layout() {
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let width = client.right - client.left
        let margin = UI.px(12)
        let gap = UI.px(4)
        var y = margin
        for (control, height) in rows {
            Win32.move(control, margin, y, width - 2 * margin, height)
            y += height + gap
        }
    }
}
#endif
