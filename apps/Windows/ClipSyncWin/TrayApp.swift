#if os(Windows)
import ClipAppCore
import ClipPeerSocket
import ClipSync
import ClipWindows
import Foundation
import Observation
import WinSDK

/// The tray app's root: owns ClipApp, a hidden host window (tray callbacks, hotkey, clipboard listener, timers),
/// the tray icon and menu, and the history, setup and prompt windows. The Windows counterpart of
/// MacAppController + MenuContentView.
@MainActor
final class TrayApp: Win32Window {
    static let hostClassName = "ClipSyncWin.Host"
    private static let singleInstanceName = "Local\\ClipSyncWin.SingleInstance"
    private static let hotkeyID: Int32 = 1
    private static let pumpTimerID: UINT_PTR = 1
    private static let captureRetryTimerID: UINT_PTR = 2
    /// How often the main actor's queue is serviced when no window message arrives (see MainQueuePump).
    private static let pumpIntervalMS: UINT = 50
    private static let captureRetryMS: UINT = 250

    private enum MenuID: Int {
        case showHistory = 100, setUp, pause, receiveLatest, pair, launchAtLogin, quit
    }
    private static let expiryMenuBase = 200
    private static let deviceMenuBase = 300

    /// Keeps the app alive for the life of the process.
    private static var current: TrayApp?

    let app: ClipApp
    let host: HWND
    private let tray: TrayIcon
    /// Explorer broadcasts this when it (re)starts; the tray icon must be added again.
    private let taskbarCreated: UINT
    private var historyWindow: HistoryWindow?
    private var setupWindow: SetupWindow?
    private var pairWindow: PromptWindow?
    private var renameWindow: PromptWindow?
    private var listening = false
    private var hotkeyRegistered = false
    private var readyHandled = false
    /// The choices behind the menu IDs of the menu last shown.
    private var menuExpiryOptions: [Int?] = []
    private var menuDevices: [VaultDevice] = []

    // MARK: Launch

    /// Sets everything up and runs the message loop. Returns the process exit code.
    static func run() -> Int32 {
        UI.setUp()

        // One copy per user session: a second launch shows the first one's history and exits.
        let mutex = singleInstanceName.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, false, $0) }
        if GetLastError() == DWORD(183) /* ERROR_ALREADY_EXISTS */ {
            let other = hostClassName.withCString(encodedAs: UTF16.self) { FindWindowW($0, nil) }
            if let other {
                // Only the foreground process may hand foreground rights on; without this the first copy's
                // history window opens behind whatever is active.
                var otherProcess: DWORD = 0
                _ = GetWindowThreadProcessId(other, &otherProcess)
                _ = AllowSetForegroundWindow(otherProcess)
                _ = PostMessageW(other, WM_APP_SHOW, 0, 0)
            }
            return 0
        }
        defer { if let mutex { CloseHandle(mutex) } }

        let home = WindowsPaths.appDataHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClipSync", isDirectory: true)
        let pasteboard = WindowsPasteboard()
        let environment = ProcessInfo.processInfo.environment
        let app = ClipApp.bootstrap(
            home: home,
            keyStore: DPAPIKeyStore(url: WindowsPaths.keyURL(home: home)),
            deviceName: environment["COMPUTERNAME"] ?? ProcessInfo.processInfo.hostName,
            pasteboard: pasteboard,
            peerSupport: peerSupport)
        if case .failed(let message) = app.state {
            Win32.messageBox(message.text, title: Strings.appName, flags: MB_OK | MB_ICONERROR)
            return 1
        }
        guard let trayApp = TrayApp(app: app) else { return 1 }
        pasteboard.onFailure = { [weak trayApp] in trayApp?.tray.notify(WinStrings.copyFailed) }
        // Files (not images) from other devices land in Downloads (docs/decisions.md, 2026-10-08).
        app.receivedFilesDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? environment["USERPROFILE"].map { URL(fileURLWithPath: $0).appendingPathComponent("Downloads") }
        app.onFileSaved = { [weak trayApp] url in
            trayApp?.tray.notify(Strings.format(WinStrings.fileSaved, ["name": url.lastPathComponent]))
        }
        current = trayApp
        trayApp.start()
        return MainQueuePump.runMessageLoop()
    }

    /// F16: listen on the Tailscale address (same port as the Mac app, any free one if taken) and dial, while the
    /// relay is unreachable. No listener when Tailscale is off at launch.
    private static let peerSupport = PeerSupport(dialer: SocketPeerDialer(), makeListener: {
        guard let host = TailnetAddress.detect() else { return nil }
        return (try? SocketPeerListener(host: host, port: 8790)) ?? (try? SocketPeerListener(host: host, port: 0))
    })

    private init?(app: ClipApp) {
        WindowRegistry.registerClass(TrayApp.hostClassName)
        // A top-level window that is never shown (not message-only, so a second launch can FindWindow it).
        guard let host = Win32.createWindow(
            className: TrayApp.hostClassName, title: Strings.appName, style: DWORD(WS_OVERLAPPED))
        else { return nil }
        self.app = app
        self.host = host
        self.tray = TrayIcon(owner: host)
        self.taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        WindowRegistry.add(host, self)
    }

    private func start() {
        tray.add(tooltip: tooltip)
        _ = SetTimer(host, Self.pumpTimerID, Self.pumpIntervalMS, nil)
        // Ctrl+Shift+V ("V" is 0x56). MOD_NOREPEAT: holding the keys doesn't toggle the window repeatedly.
        hotkeyRegistered = RegisterHotKey(host, Self.hotkeyID, UINT(MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT), 0x56)
        if !hotkeyRegistered { tray.notify(WinStrings.hotkeyTaken) }
        switch app.state {
        case .ready: becomeReadyIfNeeded()
        case .needsSetup: showSetup()
        case .working, .failed: break
        }
        showPendingMessages()
        observe()
    }

    // MARK: Model → UI

    /// Renders now and posts WM_APP_REFRESH on the next change to anything `render` read.
    private func observe() {
        let raw = Int(bitPattern: host)
        withObservationTracking {
            render()
        } onChange: {
            // Runs inside the model's willSet: post, so the render happens after the new value lands.
            _ = PostMessageW(HWND(bitPattern: raw), WM_APP_REFRESH, 0, 0)
        }
    }

    private func render() {
        tray.setTooltip(tooltip)
        // Read even when no window shows them, so a new message triggers a refresh (see showPendingMessages).
        _ = app.message
        _ = app.history?.message
        setupWindow?.render()
        if let historyWindow {
            historyWindow.render(capturePaused: app.capturePaused)
        } else if let history = app.history {
            // No window yet: still track the list, so the window is current the moment it opens.
            _ = (history.pinned, history.recent, history.canLoadMore, history.syncStatus, history.lastCopied)
        }
    }

    private var tooltip: String {
        app.capturePaused ? WinStrings.trayTooltipPaused : WinStrings.trayTooltip
    }

    /// Once set up, errors go to a notification and are cleared (the UI's half of the AppMessage contract).
    /// During setup the setup window shows `app.message` itself.
    private func showPendingMessages() {
        guard app.state == .ready else { return }
        if let message = app.message {
            tray.notify(message.text)
            app.message = nil
        }
        if let history = app.history, let message = history.message {
            tray.notify(message.text)
            history.message = nil
        }
    }

    private func becomeReadyIfNeeded() {
        guard app.state == .ready, !readyHandled else { return }
        readyHandled = true
        startCapture()
        if let setupWindow {
            setupWindow.close()
            tray.notify(WinStrings.setupDone)
        }
        refreshDevicesQuietly()
    }

    // MARK: Messages

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if taskbarCreated != 0, message == taskbarCreated {  // 0 (registration failed) would match WM_NULL
            tray.add(tooltip: tooltip)
            return 0
        }
        switch message {
        case WM_APP_TRAY:
            switch Int32(loWord(lParam)) {
            case WM_LBUTTONUP: showHistoryOrSetup()
            case WM_RBUTTONUP, WM_CONTEXTMENU: showTrayMenu()
            default: break
            }
            return 0
        case WM_APP_REFRESH:
            becomeReadyIfNeeded()
            showPendingMessages()
            observe()
            return 0
        case WM_APP_SHOW:
            showHistoryOrSetup()
            return 0
        case UINT(WM_HOTKEY):
            if Int32(truncatingIfNeeded: wParam) == Self.hotkeyID { toggleHistory() }
            return 0
        case UINT(WM_CLIPBOARDUPDATE):
            captureClipboard(isRetry: false)
            return 0
        case UINT(WM_TIMER):
            if wParam == Self.pumpTimerID {
                MainQueuePump.drain()
            } else if wParam == Self.captureRetryTimerID {
                _ = KillTimer(host, Self.captureRetryTimerID)
                captureClipboard(isRetry: true)
            }
            return 0
        case UINT(WM_COMMAND):
            menuCommand(loWord(wParam))
            return 0
        case UINT(WM_CLOSE):
            // `taskkill` (without /F) and installers close top-level windows. DefWindowProc would destroy the host
            // and leave the process running with no tray icon, hotkey or capture.
            quit()
            return 0
        default:
            return nil
        }
    }

    // MARK: Capture (F1, F9, F15)

    private func startCapture() {
        guard !listening else { return }
        listening = AddClipboardFormatListener(host)
    }

    /// WM_CLIPBOARDUPDATE: something was copied. Concealed content (password managers) and our own writes carry
    /// a marker format, so `readForCapture` reports them as `.concealed` without reading the text.
    private func captureClipboard(isRetry: Bool) {
        guard app.state == .ready, !app.capturePaused, let history = app.history else { return }
        switch WindowsClipboard.readForCapture() {
        case .busy:
            // Another app still has the clipboard open; one more try shortly.
            if !isRetry { _ = SetTimer(host, Self.captureRetryTimerID, Self.captureRetryMS, nil) }
        case .text(let text):
            // The shared rule drops blank text and anything over the size cap.
            if case .capture(let text) = CaptureFilter.decide(types: [], text: text) {
                Task { await history.capture(text) }
            }
        case .concealed, .tooLarge, .noText:
            break
        }
    }

    // MARK: Windows

    private func showHistoryOrSetup() {
        guard app.state == .ready else {
            showSetup()
            return
        }
        historyWindowCreatingIfNeeded()?.show()
    }

    private func toggleHistory() {
        guard app.state == .ready else {
            showSetup()
            return
        }
        historyWindowCreatingIfNeeded()?.toggle()
    }

    private func historyWindowCreatingIfNeeded() -> HistoryWindow? {
        if let historyWindow { return historyWindow }
        guard let history = app.history else { return nil }
        historyWindow = HistoryWindow(history: history) { [weak self] item in self?.showRename(item) }
        // render() already tracks the list (see there), so drawing it once is enough.
        historyWindow?.render(capturePaused: app.capturePaused)
        return historyWindow
    }

    private func showSetup() {
        if let setupWindow {
            setupWindow.show()
            return
        }
        guard app.state == .needsSetup || app.state == .working else { return }
        setupWindow = SetupWindow(app: app) { [weak self] in self?.setupWindow = nil }
    }

    private func showRename(_ item: ClipItem) {
        renameWindow?.close()
        guard let history = app.history else { return }
        renameWindow = PromptWindow(
            title: Strings.renameTitle, message: Strings.renamePlaceholder, text: item.title ?? "", readOnly: false,
            primary: Strings.save, secondary: Strings.cancel,
            onPrimary: { [weak self] title in
                Task { await history.rename(item, to: title) }
                self?.renameWindow?.close()
            },
            onSecondary: { [weak self] in self?.renameWindow?.close() },
            onClose: { [weak self] in self?.renameWindow = nil })
    }

    // MARK: Pairing (F10)

    private func startPairing() {
        Task { [weak self] in
            guard let self, let code = await self.app.startPairing() else { return }  // errors: showPendingMessages
            self.showPairCode(code)
        }
    }

    private func showPairCode(_ code: String) {
        if let pairWindow {
            pairWindow.setText(code)
            pairWindow.show()
            return
        }
        pairWindow = PromptWindow(
            title: Strings.pairTitle, message: Strings.pairInstructions + "\n\n" + Strings.pairExpiry, text: code,
            readOnly: true, primary: Strings.done, secondary: Strings.pairNewCode,
            onPrimary: { [weak self] _ in self?.pairWindow?.close() },
            onSecondary: { [weak self] in self?.startPairing() },
            onClose: { [weak self] in self?.pairWindow = nil })
    }

    // MARK: Devices (F13)

    /// Refreshes the device list for the menu. Offline is normal here, so a failure isn't reported.
    private func refreshDevicesQuietly() {
        Task { [weak self] in
            guard let self else { return }
            let before = self.app.message
            await self.app.loadDevices()
            if before == nil { self.app.message = nil }
        }
    }

    private func confirmRemove(_ device: VaultDevice) {
        let title = Strings.format(Strings.removeDeviceTitle, ["device": device.name])
        let answer = Win32.messageBox(
            Strings.removeDeviceMessage, title: title, flags: MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)
        guard answer == IDOK else { return }
        Task { [weak self] in
            guard let self, await self.app.removeDevice(device) else { return }
            self.tray.notify(Strings.format(Strings.deviceRemoved, ["device": device.name]))
        }
    }

    // MARK: Tray menu

    private func showTrayMenu() {
        guard let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }  // also destroys the submenus appended to it

        switch app.state {
        case .ready:
            Win32.appendItem(menu, id: MenuID.showHistory.rawValue, WinStrings.menuShowHistory)
            _ = SetMenuDefaultItem(menu, UINT(MenuID.showHistory.rawValue), 0)
            Win32.appendSeparator(menu)
            Win32.appendItem(
                menu, id: MenuID.pause.rawValue,
                app.capturePaused ? Strings.menuResumeCapture : Strings.menuPauseCapture)
            Win32.appendItem(
                menu, id: MenuID.receiveLatest.rawValue, Strings.menuReceiveLatest, checked: app.receivesLatest)
            if let expiry = CreatePopupMenu() {
                menuExpiryOptions = ExpiryChoices.options(current: app.expiryDays)
                for (index, days) in menuExpiryOptions.enumerated() {
                    Win32.appendItem(
                        expiry, id: Self.expiryMenuBase + index, ExpiryChoices.label(days),
                        checked: days == app.expiryDays)
                }
                Win32.appendSeparator(expiry)
                Win32.appendItem(expiry, id: 0, Strings.expiryHint, enabled: false)
                Win32.appendSubmenu(menu, expiry, WinStrings.menuExpiry)
            }
            Win32.appendSeparator(menu)
            Win32.appendItem(menu, id: MenuID.pair.rawValue, Strings.menuPairDevice)
            if let devices = CreatePopupMenu() {
                menuDevices = app.devices
                if menuDevices.isEmpty {
                    Win32.appendItem(devices, id: 0, WinStrings.menuDevicesLoading, enabled: false)
                }
                for (index, device) in menuDevices.enumerated() {
                    if device.isThisDevice {
                        Win32.appendItem(
                            devices, id: 0, Strings.format(WinStrings.menuThisDevice, ["device": device.name]),
                            enabled: false)
                    } else {
                        Win32.appendItem(
                            devices, id: Self.deviceMenuBase + index,
                            Strings.format(WinStrings.menuRemoveDevice, ["device": device.name]))
                    }
                }
                Win32.appendSubmenu(menu, devices, Strings.devicesTitle)
            }
            refreshDevicesQuietly()  // for the next time the menu opens
        case .needsSetup, .working:
            Win32.appendItem(menu, id: MenuID.setUp.rawValue, WinStrings.menuSetUp)
            _ = SetMenuDefaultItem(menu, UINT(MenuID.setUp.rawValue), 0)
        case .failed:
            break
        }
        Win32.appendSeparator(menu)
        Win32.appendItem(
            menu, id: MenuID.launchAtLogin.rawValue, WinStrings.menuLaunchAtLogin, checked: LaunchAtLogin.isEnabled)
        Win32.appendSeparator(menu)
        Win32.appendItem(menu, id: MenuID.quit.rawValue, Strings.menuQuit)

        // The documented tray-menu dance: foreground first so the menu closes when clicking elsewhere,
        // and a WM_NULL after so a second click works.
        var cursor = POINT()
        _ = GetCursorPos(&cursor)
        _ = SetForegroundWindow(host)
        _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON | TPM_BOTTOMALIGN), cursor.x, cursor.y, 0, host, nil)
        _ = PostMessageW(host, UINT(WM_NULL), 0, 0)
    }

    private func menuCommand(_ id: Int) {
        if id >= Self.deviceMenuBase, menuDevices.indices.contains(id - Self.deviceMenuBase) {
            confirmRemove(menuDevices[id - Self.deviceMenuBase])
            return
        }
        if id >= Self.expiryMenuBase, menuExpiryOptions.indices.contains(id - Self.expiryMenuBase) {
            let days = menuExpiryOptions[id - Self.expiryMenuBase]
            let app = self.app
            Task { await app.setExpiryDays(days) }
            return
        }
        switch MenuID(rawValue: id) {
        case .showHistory: showHistoryOrSetup()
        case .setUp: showSetup()
        case .pause: app.setCapturePaused(!app.capturePaused)
        case .receiveLatest: app.setReceivesLatest(!app.receivesLatest)
        case .pair: startPairing()
        case .launchAtLogin:
            if let code = LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) {
                tray.notify(Strings.format(WinStrings.launchAtLoginFailed, ["code": String(code)]))
            }
        case .quit: quit()
        case nil: break
        }
    }

    private func quit() {
        if hotkeyRegistered { _ = UnregisterHotKey(host, Self.hotkeyID) }
        if listening { _ = RemoveClipboardFormatListener(host) }
        _ = KillTimer(host, Self.pumpTimerID)
        tray.remove()
        app.stop()
        PostQuitMessage(0)
    }
}
#endif
