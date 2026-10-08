/// User-facing strings only the Windows tray app shows. Shared copy stays in `Strings`.
///
/// The source of truth is content/windows.md. `StringsTests.testWindowsStringsMatchContentFile` fails when a key
/// or value here differs from that file. Lives in ClipAppCore (not the Windows-only target) so the test runs on
/// every OS. Templates use `{name}` placeholders; fill them with `Strings.format(_:_:)`.
public enum WinStrings {
    // MARK: Tray
    public static let trayTooltip = "ClipSync"
    public static let trayTooltipPaused = "ClipSync: capture paused"
    public static let menuShowHistory = "Show history (Ctrl+Shift+V)"
    public static let menuSetUp = "Set up ClipSync…"
    public static let menuExpiry = "Delete unpinned items after"
    public static let menuLaunchAtLogin = "Start when I sign in"
    public static let menuThisDevice = "{device} (this device)"
    public static let menuRemoveDevice = "Remove {device}…"
    public static let menuDevicesLoading = "Loading devices…"

    // MARK: History window
    public static let historyWindowTitle = "ClipSync history"
    public static let historyHint = "Click an item to copy it. Enter copies and closes. Right-click for more."
    public static let pinnedMarker = "★"
    public static let rowFormat = "{time} · {device} · {pin}{text}"
    public static let actionRenameMenu = "Rename…"

    // MARK: Setup window
    public static let setupDone = "ClipSync is set up. Copy something to try it."

    // MARK: Messages
    public static let hotkeyTaken = "Another app already uses Ctrl+Shift+V, so the history shortcut is off. Open the history from the tray icon."
    public static let launchAtLoginFailed = "Couldn't change the sign-in setting (Windows error {code})."
    public static let copyFailed = "Couldn't put that on the clipboard. Another app may be holding it; try again."
    public static let fileSaved = "Saved {name} to Downloads."
    public static let windowsOnly = "ClipSyncWin runs on Windows only. On this computer, use the Mac app or clipctl."

    /// Every key and value, for the content/windows.md sync test.
    static let all: [String: String] = [
        "trayTooltip": trayTooltip, "trayTooltipPaused": trayTooltipPaused, "menuShowHistory": menuShowHistory,
        "menuSetUp": menuSetUp, "menuExpiry": menuExpiry, "menuLaunchAtLogin": menuLaunchAtLogin,
        "menuThisDevice": menuThisDevice, "menuRemoveDevice": menuRemoveDevice,
        "menuDevicesLoading": menuDevicesLoading,
        "historyWindowTitle": historyWindowTitle, "historyHint": historyHint, "pinnedMarker": pinnedMarker,
        "rowFormat": rowFormat, "actionRenameMenu": actionRenameMenu,
        "setupDone": setupDone,
        "hotkeyTaken": hotkeyTaken, "launchAtLoginFailed": launchAtLoginFailed, "copyFailed": copyFailed,
        "fileSaved": fileSaved,
        "windowsOnly": windowsOnly,
    ]
}
