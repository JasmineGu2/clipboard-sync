# ClipSync for Windows

`ClipSyncWin` is the tray app for the PC (milestone M3). It sits in the notification area, saves what you copy, and shows your history in a small window. It talks to Windows directly through Swift's `WinSDK` module, with no UI framework, and the app logic is the same `ClipAppCore` the Mac and iPhone apps use.

It was written on the Mac and has never been compiled on Windows. CI's Windows job is the first compile, and nobody has run it yet. See "Check these first" at the bottom.

## What it does

- Saves text you copy (it listens with `AddClipboardFormatListener`, so there's no polling). It skips anything a password manager marks as concealed, and its own writes, which carry the same marker.
- Puts the newest copy from another device on the clipboard, unless you untick "Use copies from other devices".
- **Ctrl+Shift+V** or a left click on the tray icon opens the history: newest first, pinned items on top, each row with time, device and text. Type to search. Click a row to copy it, or press Enter or double-click to copy and close the window. Right-click a row to pin, rename or delete it. Esc hides the window.
- The right-click tray menu has pause capture, use copies from other devices, the expiry setting, pair a new device (it shows a code), devices (remove a lost one), start when I sign in, and quit.
- First run opens a setup window. You can create a new vault, or join one with a code from Pair new device on another device.

## Build and run on the PC

```sh
. scripts/swiftenv.sh           # Swift 6.4 on PATH, SDKROOT set (Git Bash)
swift build --product ClipSyncWin
.build/out/Products/Debug-windows-x86_64/ClipSyncWin.exe
```

The exe is linked as a GUI app (`/SUBSYSTEM:WINDOWS`), so no console window opens and `print` goes nowhere. A second launch just opens the first one's history window.

For a release build, use `swift build -c release --product ClipSyncWin` and run it from `Release-windows-x86_64`. The Swift runtime DLLs need to be on PATH, and they are on a PC with the Swift toolchain installed. "Start when I sign in" saves the path of the exe you ran, so turn it on from the build you mean to keep.

## Where things live

- `%APPDATA%\ClipSync`: `config.json`, `clips.sqlite`, and the keys `key.dpapi` and `device.dpapi`, which DPAPI protects for your Windows user. This is the same folder clipctl uses, so a PC already paired with clipctl opens straight into its history. Don't run `clipctl watch` and the tray app at the same time, or both will capture every copy.
- Start when I sign in is a `ClipSync` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Windows also lists it in Settings > Apps > Startup.
- Copy lives in content/windows.md. Strings shared with the Apple apps come from content/app.md.

## Code

| File | What it is |
| --- | --- |
| `main.swift` | Entry point. On macOS and Linux it only prints that it's Windows only, so `swift build` passes everywhere. |
| `TrayApp.swift` | The root object: ClipApp, the hidden host window, tray menu, hotkey, clipboard listener. |
| `HistoryWindow.swift` | Search box, list and status line over `HistoryModel`. |
| `SetupWindow.swift` | Create or join a vault. |
| `PromptWindow.swift` | Rename an item, show a pairing code. |
| `TrayIcon.swift` | `Shell_NotifyIconW`: the icon, tooltip and notifications. |
| `LaunchAtLogin.swift` | The Run registry value. |
| `WindowsPasteboard.swift` | `PasteboardWriter` over `WindowsClipboard`. |
| `Win32.swift` | Window procedure, window registry, message loop, DPI and font, small helpers. |

The clipboard reader and writer and the DPAPI key store live in `Sources/ClipWindows`, which clipctl uses too.

## Check these first

These are the parts most likely to go wrong, since none of them has been compiled or run yet:

1. **The main actor never runs.** Swift tasks on the main actor run from the libdispatch main queue, and the app drains that queue with `RunLoop.main.limitDate(forMode:)` after each window message and every 50 ms. If buttons do nothing and the history never fills, this is why. Look at `MainQueuePump` in Win32.swift first.
2. **The linker flags.** `/SUBSYSTEM:WINDOWS` and `/ENTRY:mainCRTStartup` are set in Package.swift. If linking fails, remove the `unsafeFlags` line to get a console app, then fix it.
3. **Ctrl+Shift+V.** Chrome, Edge, Slack and VS Code use it for paste without formatting, and this app takes it from them while it's running. If another app already owns it, you get a notification and the tray icon still works. The key is set in `TrayApp.start()`.
4. **Looks.** There's no manifest yet, so the controls use the old Windows look, and the icon is the generic app icon. A manifest and an `.rc` icon are the next polish step.
5. **The DPI scale is read once at launch.** Moving the window to a monitor with different scaling makes it look slightly blurry.
