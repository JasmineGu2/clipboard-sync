// ClipSyncWin: the Windows tray app (M3). See apps/Windows/README.md.
#if os(Windows)
import Foundation

// Top-level code without `await` isn't main-actor isolated, but it does run on the main thread.
exit(MainActor.assumeIsolated { TrayApp.run() })
#else
import ClipAppCore

// Keeps `swift build` green on macOS and Linux; the app itself is Win32 only.
print(WinStrings.windowsOnly)
#endif
