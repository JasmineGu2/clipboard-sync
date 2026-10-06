# Windows app copy

Strings the Windows tray app (`apps/Windows/ClipSyncWin`) shows that the Apple apps don't. Everything shared with them (history, item actions, sync status, pairing, devices, expiry, onboarding, errors) comes from content/app.md.

The code reads these from the `WinStrings` enum in `Sources/ClipAppCore/WindowsStrings.swift`. Change a line here and the same line there; `swift test` fails until both match (`StringsTests`).

`{name}` marks a placeholder the app fills in.

## Tray

- `trayTooltip`: ClipSync
- `trayTooltipPaused`: ClipSync: capture paused
- `menuShowHistory`: Show history (Ctrl+Shift+V)
- `menuSetUp`: Set up ClipSync…
- `menuExpiry`: Delete unpinned items after
- `menuLaunchAtLogin`: Start when I sign in
- `menuThisDevice`: {device} (this device)
- `menuRemoveDevice`: Remove {device}…
- `menuDevicesLoading`: Loading devices…

## History window

- `historyWindowTitle`: ClipSync history
- `historyHint`: Click an item to copy it. Enter copies and closes. Right-click for more.
- `pinnedMarker`: ★
- `rowFormat`: {time} · {device} · {pin}{text}
- `actionRenameMenu`: Rename…

## Setup window

- `setupDone`: ClipSync is set up. Copy something to try it.

## Messages

- `hotkeyTaken`: Another app already uses Ctrl+Shift+V, so the history shortcut is off. Open the history from the tray icon.
- `launchAtLoginFailed`: Couldn't change the sign-in setting (Windows error {code}).
- `copyFailed`: Couldn't put that on the clipboard. Another app may be holding it; try again.
- `windowsOnly`: ClipSyncWin runs on Windows only. On this computer, use the Mac app or clipctl.
