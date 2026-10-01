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
xcodegen
open ClipSync.xcodeproj
```

Run `xcodegen` again whenever you add or move a file. The `.xcodeproj` is generated, so don't edit it by
hand (signing settings you pick in Xcode get wiped too; put `DEVELOPMENT_TEAM` in `project.yml` to keep it).

The first build resolves swift-crypto and compiles SQLite from source, so give it a few minutes.

## Signing with a free Apple ID

1. In Xcode, select the project, then each target (`ClipSyncMac`, `ClipSynciOS`, `ClipShare`) in turn.
2. Signing & Capabilities: tick "Automatically manage signing" and pick your Personal Team.
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
   vault**. This is the first device, so it makes the key.
4. Copy some text in any app. It shows up in the menu within a second.

Pause capture and Pair new device are in the `...` menu at the bottom.

## Run on the iPhone

1. Plug the iPhone in (or pair it over Wi-Fi in Xcode > Window > Devices and Simulators).
2. On the iPhone, turn on Developer Mode: Settings > Privacy & Security > Developer Mode, then restart.
3. Pick the `ClipSynciOS` scheme and your iPhone, then Run.
4. The first time, iOS blocks the app. Go to Settings > General > VPN & Device Management, tap your Apple ID,
   and tap Trust.
5. Turn on Tailscale on the iPhone.
6. On the Mac, open the menu and choose **Pair new device**. A code shows up.
7. On the iPhone, enter the same relay URL and the code, then **Join with a pairing code**. The history
   from the Mac appears.

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
container (iPhone): `clips.sqlite` and `config.json` (server URL, device ID, pause flag). The vault key is
only in the Keychain.

## Check these first

The parts most likely to need a fix on the first build, roughly in order:

1. **Keychain on the Mac.** `KeychainKeyStore` sets `kSecUseDataProtectionKeychain`, which needs the app to
   be signed with a provisioning profile. If saving the key fails with -34018, check the
   `keychain-access-groups` entitlement got a real team prefix.
2. **App Groups with a free team.** See above.
3. **`$(AppIdentifierPrefix)` in Info.plist.** `ClipSyncKeychainGroup` must expand to `TEAMID.dev.jazz.clipsync.shared`.
   If it doesn't, the app and the extension use different keychain groups and the extension can't find the key.
4. **App Intents.** `SendClipboardIntent` declares `description` and `openAppWhenRun` as `static let`.
   If Xcode complains, make them `static var`.
5. **Concurrency warnings** in the UI layer (it builds in Swift 5 mode with complete checking).
6. **Clipboard privacy prompts on newer macOS.** If macOS asks the user before an app reads the clipboard,
   the watcher's reads will trigger it. Allow ClipSync in System Settings > Privacy & Security.
