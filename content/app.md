# App copy

Every user-facing string in the Apple apps (macOS menu bar app, iOS app, share extension, Shortcuts action).

The code reads these from the `Strings` enum in `Sources/ClipAppCore/Strings.swift`. Change a line here and the same line there; `swift test` fails until both match (`StringsTests`). The five `intent*` strings are also repeated as literals in `apps/Apple/Shared/SendClipboardIntent.swift`, because the App Intents compiler only reads literals; the same test checks them.

`{name}` marks a placeholder the app fills in.

## App

- `appName`: ClipSync

## History

- `historyTitle`: Clipboard
- `sectionPinned`: Pinned
- `sectionRecent`: Recent
- `searchPrompt`: Search history
- `emptyHistory`: Nothing here yet. Copy something on another device, or send your clipboard.
- `noResults`: No matches
- `loadMore`: Load more
- `fromDevice`: From {device}
- `copied`: Copied
- `kindImage`: Image
- `kindFile`: File
- `downloading`: Downloading…
- `clipboardImageName`: Clipboard image.{ext}

## Item actions

- `actionCopy`: Copy
- `actionPin`: Pin
- `actionUnpin`: Unpin
- `actionRename`: Rename
- `actionAddTag`: Add tag
- `actionRemoveTag`: Remove tag {tag}
- `actionDelete`: Delete
- `renameTitle`: Rename item
- `renamePlaceholder`: Title
- `tagTitle`: Add a tag
- `tagPlaceholder`: Tag
- `save`: Save
- `cancel`: Cancel
- `done`: Done
- `ok`: OK

## Sending (iOS)

- `sendClipboard`: Send clipboard

## Sync status

- `statusSynced`: Synced
- `statusSyncing`: Syncing…
- `statusOffline`: Offline. Changes sync when the server is back.
- `statusRemoved`: This device was removed from your vault, so it no longer syncs.
- `statusDirect`: Server unreachable. Syncing directly with {count} of your devices.

## Sync path

Shown in the Mac menu. When the relay (the server) can't be reached, devices on your tailnet sync directly with each other; the relay catches up when it's back.

- `syncPathRelay`: Sync path: relay
- `syncPathDirect`: Sync path: direct to {count} device(s), relay unreachable
- `syncPathNone`: Sync path: none, relay and devices unreachable

## Mac menu

- `menuPauseCapture`: Pause capture
- `menuResumeCapture`: Resume capture
- `capturePaused`: Capture is paused
- `menuReceiveLatest`: Use copies from other devices
- `menuPairDevice`: Pair new device…
- `menuQuit`: Quit ClipSync

## Expiry (F14)

The Mac menu and the iPhone's settings screen. `{days}` is a number above 1.

- `settingsTitle`: Settings
- `expiryTitle`: Delete unpinned items after
- `expiryHint`: Older unpinned items are deleted on all your devices. Pinned items stay.
- `expiryOff`: Never
- `expiryOneDay`: 1 day
- `expiryDays`: {days} days

## Onboarding

- `onboardingTitle`: Set up ClipSync
- `onboardingIntro`: Your history is encrypted on this device. The server only stores ciphertext.
- `serverLabel`: Server URL
- `serverPlaceholder`: http://relay.your-tailnet.ts.net:8787
- `serverHint`: Use the relay's MagicDNS name, like http://relay.tailnet-name.ts.net:8787, not a 100.x address. iOS blocks plain HTTP to raw IP addresses.
- `deviceNameLabel`: Device name
- `deviceNameHint`: Your other devices show this next to what you copy here.
- `createVault`: Create a new vault
- `createVaultHint`: Start here on your first device.
- `joinVault`: Join with a pairing code
- `joinVaultHint`: Get a code from Pair new device on a device that's already set up.
- `codeLabel`: Pairing code
- `codePlaceholder`: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
- `working`: Connecting…

## Pairing

- `pairTitle`: Pair a new device
- `pairInstructions`: On the new device, choose Join with a pairing code and type this code.
- `pairExpiry`: The code works once and expires in 10 minutes.
- `pairNewCode`: New code

## Devices

- `menuDevices`: Devices…
- `devicesTitle`: Devices
- `devicesIntro`: Every device that can read your history. If you lose one, remove it here: it stops syncing and can't read anything copied after that.
- `devicesLoading`: Loading devices…
- `devicesMissingHint`: A device only shows here once it has synced with this version. Any device not listed has to pair again after you remove one.
- `deviceThis`: This device
- `actionRemoveDevice`: Remove
- `removeDeviceTitle`: Remove {device}?
- `removeDeviceMessage`: It stops syncing and can't read anything copied from now on. Your other devices switch to a new key the next time they sync. Anything already on it stays there. Images and files that only it had keep their preview but can't be downloaded any more.
- `removeDeviceConfirm`: Remove device
- `deviceRemoved`: {device} was removed.
- `deviceFingerprint`: Key {fingerprint}
- `deviceJoined`: Joined {date}
- `devicesCheckHint`: To check a device, open Devices on it: the key next to This device should match the key shown for it here. Remove any device you don't recognize.

## Removed from the vault

Shown instead of the history once another device removed this one (F13).

- `removedTitle`: This device was removed
- `removedBody`: Another device removed this one from your vault, so it no longer syncs. Set it up again to join with a pairing code or start a new vault.
- `removedKeepsHistory`: The old history isn't deleted. It moves to a folder named removed- and the date, inside ClipSync's data folder on this device.
- `setUpAgain`: Set up again

## Quick picker (Mac)

The floating list ⌃⌘V opens.

- `menuQuickPick`: Quick picker (⌃⌘V)
- `pickerPrompt`: Search recent clips
- `pickerHintCopy`: ↑↓ to choose · Return to copy · Esc to close
- `pickerHintPaste`: ↑↓ to choose · Return to paste · Esc to close
- `pickerCopiedNoPaste`: Copied. Press ⌘V to paste. To paste with Return, allow ClipSync in System Settings > Privacy & Security > Accessibility.
- `pickerHotkeyUnavailable`: ⌃⌘V is taken by another app, so the quick picker has no shortcut. Open it from this menu.

## Share extension and Shortcuts

- `shareSent`: Sent to ClipSync
- `shareSavedOffline`: Saved. It syncs when the server is reachable.
- `shareUploadLater`: Saved. The file finishes uploading the next time ClipSync is open.
- `intentTitle`: Send Clipboard to ClipSync
- `intentDescription`: Adds text to your ClipSync history and syncs it to your other devices.
- `intentTextParameter`: Text
- `intentTextPrompt`: What text do you want to send?
- `intentShortTitle`: Send Clipboard

## Apple Watch (F17)

The watch shows the iPhone's pinned items. It reuses `sectionPinned` as its title.

- `watchEmpty`: Nothing pinned yet. Pin items in ClipSync on your iPhone and they show up here.
- `watchCopyOnPhone`: Copy on iPhone
- `watchCopiedOnPhone`: On your iPhone's clipboard
- `watchPhoneUnreachable`: Can't reach your iPhone. Open ClipSync on it and try again.
- `watchTruncated`: Shortened for the watch. The full text is on your iPhone.
- `watchOmitted`: {count} more pinned items are only on your iPhone.

## Errors (see AppMessage)

- `errorEmptyText`: There's no text to send.
- `errorTooLarge`: That clip is too large to sync.
- `errorInvalidCode`: That code isn't valid. Check it and try again.
- `errorCodeNotFound`: That code has expired or was already used. Make a new one on the other device.
- `errorCodeMismatch`: That code doesn't match. Check it and try again.
- `errorInvalidServer`: Enter a server URL, like http://relay:8787.
- `errorServerUnreachable`: Can't reach the server. Check Tailscale and the URL.
- `errorServer`: The server returned an error. Try again.
- `errorUnauthorized`: The server rejected this device's key.
- `errorRateLimited`: The server is busy. Try again in a minute.
- `errorStorage`: Couldn't read or write the local database.
- `errorKeychain`: Couldn't access the Keychain.
- `errorNotSetUp`: Open ClipSync and finish setup first.
- `errorFileTooLarge`: That file is too large to sync. The limit is {limit}.
- `errorUnreadableFile`: Couldn't read that file.
- `errorNotUploadedYet`: This isn't on the relay yet. Try again in a moment. If the device that sent it was removed, only the preview is left.
- `errorDownloadFailed`: The download didn't match what was sent. Try again.
- `errorUnknown`: Something went wrong. Try again.
- `errorRemovedFromVault`: This device was removed from your vault, so it no longer syncs.
- `errorCannotRemoveThisDevice`: A device can't remove itself. Remove it from another device.
- `errorUnknownDevice`: That device isn't in your vault any more.
- `errorNotRegistered`: This device isn't in the device list yet. Let it sync once, then try again.
