# ClipSync for Mac and iPhone

Three targets, all thin SwiftUI and UIKit layers over `ClipAppCore` (the shared app model in the root
package, which is built and tested on Windows too):

| Target | What it is |
| --- | --- |
| `ClipSyncMac` | Menu bar app. Watches the clipboard, shows history, search, click to copy. |
| `ClipSynciOS` | iPhone app. History, search, swipe to pin or delete, paste button to send. |
| `ClipShare` | iOS share extension. Sends shared text or a link. |

The iPhone app also adds a Shortcuts action, **Send Clipboard to ClipSync**.


None of this has been compiled yet. It was written on Windows, so expect a first round of small fixes.
See "Check these first" at the bottom.

## What you need

- A Mac on macOS 14 or later with Xcode 16 or later.
- Homebrew.
- An Apple ID added to Xcode (Xcode > Settings > Accounts). A free one works, with the limits below.
- The relay running on the VM, and Tailscale on the Mac and the iPhone.

## Build

```sh
brew install xcodegen
cd apps/Apple
export CLIPSYNC_TEAM_ID=XXXXXXXXXX   # your team ID, see below
xcodegen
open ClipSync.xcodeproj
```

`project.yml` sets `DEVELOPMENT_TEAM: ${CLIPSYNC_TEAM_ID}`, and XcodeGen fills it in from the environment
when it generates the project. Find your team ID in Xcode > Settings > Accounts (select the team), or on
developer.apple.com under Membership. Put the `export` line in your shell profile so every `xcodegen` run
gets it. Without it, the Keychain access group has no team prefix: setup shows "Couldn't access the
Keychain", and the underlying error (`KeychainKeyStore.MissingTeamPrefix`) names `CLIPSYNC_TEAM_ID`.

Run `xcodegen` again whenever you add or move a file. The `.xcodeproj` is generated, so don't edit it by
hand (signing settings you pick in Xcode get wiped too).

The apps are named ClipSync, but their Swift modules are `ClipSyncMac`, `ClipSynciOS` and
`ClipShareExtension` (`PRODUCT_MODULE_NAME`), because the package already has a module called `ClipSync`.

The first build resolves swift-crypto and compiles SQLite from source, so give it a few minutes.

## Signing with a free Apple ID

1. Set `CLIPSYNC_TEAM_ID` to your Personal Team's ID and run `xcodegen` (see Build).
2. In Xcode, check Signing & Capabilities on each target (`ClipSyncMac`, `ClipSynciOS`, `ClipShare`):
   "Automatically manage signing" is on and your Personal Team is picked.
3. If Xcode says a bundle ID is taken, change the prefix in `project.yml` (`dev.jazz.clipsync`) to something
   only you use, and change `group.dev.jazz.clipsync` in `iOS/ClipSynciOS.entitlements`,
   `ShareExtension/ClipShare.entitlements` and `Shared/AppPaths.swift` to match. Then run `xcodegen` again.

Free provisioning profiles last **7 days**. After that the iPhone app won't open until you run it from Xcode
again. That's the plan for development (PRD risks); pay for the developer program before the demo.

If the free team refuses App Groups, the iPhone app still works on its own. The share extension and the
Shortcuts action then can't see its database and say "finish setup first". Paste button still works.

## Run on the Mac

1. Pick the `ClipSyncMac` scheme and "My Mac", then Run.
2. A clipboard icon appears in the menu bar (no Dock icon). Click it.
3. Enter the relay URL, for example `http://relay.your-tailnet.ts.net:8787`, and choose **Create a new
   vault**. This is the first device, so it makes the key. The device name starts as the Mac's name; change
   it if you like. Your other devices show it next to what you copy here.
4. Copy some text in any app. It shows up in the menu within a second.

Pause capture and Pair new device are in the `...` menu at the bottom.

### Quick picker (⌃⌘V)

Press ⌃⌘V anywhere for a small floating list of recent items near the pointer (or choose Quick picker in the `...`
menu). Type to search, Up and Down to choose, Return to copy, Escape to close. The shortcut uses Carbon's
`RegisterEventHotKey`, which needs no permission. Return also pastes into the app underneath, but only when
ClipSync is allowed in System Settings > Privacy & Security > Accessibility (the app checks with
`CGPreflightPostEventAccess` and never prompts). Without it the item is copied and the picker says to press ⌘V. If
another app already holds ⌃⌘V, the menu says so and the menu item still works.

## When a device is removed

When another device removes this one (Devices > Remove, or `clipctl revoke`), the app shows "This device was
removed" instead of the history, with a **Set up again** button. That button moves `clips.sqlite` (with its
`-wal`/`-shm`), `blobs/`, `exports/` and `config.json` into `removed-<date>/` inside the same data folder, drops the
dead vault key from the Keychain, makes a new device key, and goes back to onboarding. Nothing is deleted; delete the
`removed-` folder yourself once you don't need the old history.

The Devices screen shows each device's key fingerprint (`Key B486 2DD6 CA02 F69F`) and the date it joined. To
spot a decoy, open Devices on each of your devices and check that the key next to This device matches the key
shown for it everywhere else.

## Measurements (simulator and proxy numbers, not the targets themselves)

DEBUG builds take launch arguments that seed a separate, throwaway vault (`Shared/MeasurementMode.swift`):
`-ClipSyncMeasureItems 10000` (plus optional `-ClipSyncMeasureHome <dir>`, `-ClipSyncMeasureServer <url>`,
`-ClipSyncMeasureOpen devices|picker`). The vault key lives in memory only, so the real vault is never touched.
The app prints `ClipSync measure: ...` lines to stdout.

**N3 on the iOS Simulator, not a device (2026-10-06).** iPhone 16 Pro simulator, iOS 18.3, Debug build, MacBook Air
under heavy load from other builds (load average 10 to 15). Time from the kernel starting the process to the first
history rows on screen, 10,000 items, 10 launches after a seeding launch:

| | median | range |
| --- | --- | --- |
| process start to app model ready | 1.18 s | 0.89 to 1.77 s |
| process start to history on screen | 2.99 s | 2.44 to 4.11 s |

Over the 500 ms target, but this says little about a phone: about 1.2 s passes before any ClipSync code runs
(Debug dylib loading in a busy simulator), and the same launch with a 1-item vault took 2.9 s, so the 10,000 items
aren't what costs the time. Measure on the iPhone with a Release-like build before reading anything into it.
Reproduce: `xcrun simctl launch --console-pty <device> dev.jazz.clipsync.ios -ClipSyncMeasureItems 10000`.

**N4 proxy on the Mac: CPU, not Energy Impact (2026-10-06).** Debug build launched headless (ad-hoc signed, so not
sandboxed) with a 10,000-item measurement vault, long-polling a local relay, clipboard watcher running, menu closed.
After 30 s to settle, over 61 s: 0.07 s of CPU time (`ps -o time`, about 0.1% of one core); `top -l 61 -s 1` averaged
0.06% CPU, 11.4 idle wakeups per second and a power score of 0.07. The PRD target is Activity Monitor's Energy Impact
"Low", which still needs a look in Activity Monitor on the signed app.

## Run on the iPhone

1. Plug the iPhone in (or pair it over Wi-Fi in Xcode > Window > Devices and Simulators).
2. On the iPhone, turn on Developer Mode: Settings > Privacy & Security > Developer Mode, then restart.
3. Pick the `ClipSynciOS` scheme and your iPhone, then Run.
4. The first time, iOS blocks the app. Go to Settings > General > VPN & Device Management, tap your Apple ID,
   and tap Trust.
5. Turn on Tailscale on the iPhone.
6. On the Mac, open the menu and choose **Pair new device**. A code shows up.
7. On the iPhone, enter the same relay URL and the code, then **Join with a pairing code**. The history
   from the Mac appears. Use the MagicDNS name (`http://relay.your-tailnet.ts.net:8787`), not a raw `100.x`
   Tailscale IP: iOS blocks plain HTTP to raw IP addresses. Give the iPhone a name too; the field starts as
   "iPhone" because iOS no longer tells apps the name you gave the phone.

To send from the iPhone:
- Tap the paste button at the top right. It's the system paste button, so iOS doesn't ask for permission.
- Or share text or a link to ClipSync from any app's share sheet.
- Or make a Shortcut: **Get Clipboard**, then **Send Clipboard to ClipSync** with Text set to the clipboard.
  Put it on the Back Tap (Settings > Accessibility > Touch > Back Tap) for a two-tap send.

## Where things live

| Folder | Contents |
| --- | --- |
| `Shared/` | Keychain key store, file paths, the shared SwiftUI views, the App Intent. In both apps. |
| `macOS/` | Menu bar app, pasteboard reader and writer, clipboard watcher. |
| `iOS/` | iPhone app and history screen. |
| `ShareExtension/` | Share extension. It only gets `KeychainKeyStore.swift` and `AppPaths.swift` from `Shared/`. |

All copy comes from `Strings` in `Sources/ClipAppCore/Strings.swift`, which mirrors `content/app.md`.

Data lives in `ClipSync/` under Application Support (Mac, inside the sandbox container) or the App Group
container (iPhone): `clips.sqlite` and `config.json` (server URL, device ID, device name, pause flag). The vault key is
only in the Keychain.

## Check these first

The parts most likely to need a fix on the first build, roughly in order:

1. **Keychain on the Mac.** `KeychainKeyStore` sets `kSecUseDataProtectionKeychain`, which needs the app to
   be signed with a provisioning profile. If saving the key fails with -34018, check the
   `keychain-access-groups` entitlement got a real team prefix. On iOS, an access group that starts with
   "." means `$(AppIdentifierPrefix)` was empty; `KeychainKeyStore` throws `MissingTeamPrefix` for that
   instead of trying (set `CLIPSYNC_TEAM_ID` and run `xcodegen` again).
2. **App Groups with a free team.** See above.
3. **`$(AppIdentifierPrefix)` in Info.plist.** `ClipSyncKeychainGroup` must expand to `TEAMID.dev.jazz.clipsync.shared`.
   If it doesn't, the app and the extension use different keychain groups and the extension can't find the key.
4. **App Intents.** `SendClipboardIntent` declares `description` and `openAppWhenRun` as `static let`.
   If Xcode complains, make them `static var`.
5. **Menu bar visibility.** The Mac history refreshes its status only while the menu window is key
   (`WindowKeyObserver` in `MenuContentView.swift`). If the status line looks stale while the menu is open,
   check the window gets `NSWindow.didBecomeKeyNotification`.
6. **Concurrency warnings** in the UI layer (it builds in Swift 5 mode with complete checking).
7. **Clipboard privacy prompts on newer macOS.** If macOS asks the user before an app reads the clipboard,
   the watcher's reads will trigger it. Allow ClipSync in System Settings > Privacy & Security.

## First-build checklist (risks noted before anything was compiled)
1. **App Groups on a free Apple ID** may not be allowed. If not, the iPhone app still works, but the share extension and Shortcut say "finish setup first".
2. **Mac keychain** uses the data-protection keychain, which needs a provisioning profile. Error -34018 means the profile or team is missing.
3. **App Intent:** if Xcode rejects `static let description` / `openAppWhenRun`, change them to `static var`.
4. **Compiler:** the shared code was tested with Swift 6.4; Xcode 16's compiler hasn't been tried.
5. **Concurrency:** expect warnings, not errors, in the UI code (Swift 5 mode with complete checking).
6. **Eyeball:** text fields and alerts inside the menu bar window; how the iOS PasteButton looks in the toolbar.
7. **Clipboard privacy prompt:** newer macOS may ask before the app reads the pasteboard, even though it only reads when the change count moves.
