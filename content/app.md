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

## Mac menu

- `menuPauseCapture`: Pause capture
- `menuResumeCapture`: Resume capture
- `capturePaused`: Capture is paused
- `menuReceiveLatest`: Use copies from other devices
- `menuPairDevice`: Pair new device…
- `menuQuit`: Quit ClipSync

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

## Share extension and Shortcuts

- `shareSent`: Sent to ClipSync
- `shareSavedOffline`: Saved. It syncs when the server is reachable.
- `shareUploadLater`: Saved. The file finishes uploading the next time ClipSync is open.
- `intentTitle`: Send Clipboard to ClipSync
- `intentDescription`: Adds text to your ClipSync history and syncs it to your other devices.
- `intentTextParameter`: Text
- `intentTextPrompt`: What text do you want to send?
- `intentShortTitle`: Send Clipboard

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
- `errorFileTooLarge`: That file is too large to sync. The limit is 512 MB.
- `errorUnreadableFile`: Couldn't read that file.
- `errorNotUploadedYet`: This is still uploading from the other device. Try again in a moment.
- `errorDownloadFailed`: The download didn't match what was sent. Try again.
- `errorUnknown`: Something went wrong. Try again.
