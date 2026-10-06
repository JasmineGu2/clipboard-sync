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
- `removeDeviceMessage`: It stops syncing and can't read anything copied from now on. Your other devices switch to a new key the next time they sync. Anything already on it stays there.
- `removeDeviceConfirm`: Remove device
- `deviceRemoved`: {device} was removed.

## Share extension and Shortcuts

- `shareSent`: Sent to ClipSync
- `shareSavedOffline`: Saved. It syncs when the server is reachable.
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
- `errorUnknown`: Something went wrong. Try again.
- `errorRemovedFromVault`: This device was removed from your vault, so it no longer syncs.
- `errorCannotRemoveThisDevice`: A device can't remove itself. Remove it from another device.
- `errorUnknownDevice`: That device isn't in your vault any more.
- `errorNotRegistered`: This device isn't in the device list yet. Let it sync once, then try again.
