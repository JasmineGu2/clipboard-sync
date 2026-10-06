import Foundation

/// Every user-facing string in the Apple apps.
///
/// The source of truth is content/app.md (CLAUDE.md: copy lives in content/). Keep the two in sync:
/// `StringsTests.testStringsMatchContentFile` fails when a key or value here differs from content/app.md.
/// Templates use `{name}` placeholders; fill them with `Strings.format(_:_:)`.
public enum Strings {
    // MARK: App
    public static let appName = "ClipSync"

    // MARK: History
    public static let historyTitle = "Clipboard"
    public static let sectionPinned = "Pinned"
    public static let sectionRecent = "Recent"
    public static let searchPrompt = "Search history"
    public static let emptyHistory = "Nothing here yet. Copy something on another device, or send your clipboard."
    public static let noResults = "No matches"
    public static let loadMore = "Load more"
    public static let fromDevice = "From {device}"
    public static let copied = "Copied"
    public static let kindImage = "Image"
    public static let kindFile = "File"
    public static let downloading = "Downloading…"
    public static let clipboardImageName = "Clipboard image.{ext}"

    // MARK: Item actions
    public static let actionCopy = "Copy"
    public static let actionPin = "Pin"
    public static let actionUnpin = "Unpin"
    public static let actionRename = "Rename"
    public static let actionAddTag = "Add tag"
    public static let actionRemoveTag = "Remove tag {tag}"
    public static let actionDelete = "Delete"
    public static let renameTitle = "Rename item"
    public static let renamePlaceholder = "Title"
    public static let tagTitle = "Add a tag"
    public static let tagPlaceholder = "Tag"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let done = "Done"
    public static let ok = "OK"

    // MARK: Sending (iOS)
    public static let sendClipboard = "Send clipboard"

    // MARK: Sync status
    public static let statusSynced = "Synced"
    public static let statusSyncing = "Syncing…"
    public static let statusOffline = "Offline. Changes sync when the server is back."
    public static let statusRemoved = "This device was removed from your vault, so it no longer syncs."
    public static let statusDirect = "Server unreachable. Syncing directly with {count} of your devices."

    // MARK: Sync path (F16)
    public static let syncPathRelay = "Sync path: relay"
    public static let syncPathDirect = "Sync path: direct to {count} device(s), relay unreachable"
    public static let syncPathNone = "Sync path: none, relay and devices unreachable"

    // MARK: Mac menu
    public static let menuPauseCapture = "Pause capture"
    public static let menuResumeCapture = "Resume capture"
    public static let capturePaused = "Capture is paused"
    public static let menuReceiveLatest = "Use copies from other devices"
    public static let menuPairDevice = "Pair new device…"
    public static let menuQuit = "Quit ClipSync"

    // MARK: Expiry (F14)
    public static let settingsTitle = "Settings"
    public static let expiryTitle = "Delete unpinned items after"
    public static let expiryHint = "Older unpinned items are deleted on all your devices. Pinned items stay."
    public static let expiryOff = "Never"
    public static let expiryOneDay = "1 day"
    public static let expiryDays = "{days} days"

    // MARK: Onboarding
    public static let onboardingTitle = "Set up ClipSync"
    public static let onboardingIntro = "Your history is encrypted on this device. The server only stores ciphertext."
    public static let serverLabel = "Server URL"
    public static let serverPlaceholder = "http://relay.your-tailnet.ts.net:8787"
    public static let serverHint = "Use the relay's MagicDNS name, like http://relay.tailnet-name.ts.net:8787, not a 100.x address. iOS blocks plain HTTP to raw IP addresses."
    public static let deviceNameLabel = "Device name"
    public static let deviceNameHint = "Your other devices show this next to what you copy here."
    public static let createVault = "Create a new vault"
    public static let createVaultHint = "Start here on your first device."
    public static let joinVault = "Join with a pairing code"
    public static let joinVaultHint = "Get a code from Pair new device on a device that's already set up."
    public static let codeLabel = "Pairing code"
    public static let codePlaceholder = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
    public static let working = "Connecting…"

    // MARK: Pairing
    public static let pairTitle = "Pair a new device"
    public static let pairInstructions = "On the new device, choose Join with a pairing code and type this code."
    public static let pairExpiry = "The code works once and expires in 10 minutes."
    public static let pairNewCode = "New code"

    // MARK: Devices (F13)
    public static let menuDevices = "Devices…"
    public static let devicesTitle = "Devices"
    public static let devicesIntro = "Every device that can read your history. If you lose one, remove it here: it stops syncing and can't read anything copied after that."
    public static let devicesLoading = "Loading devices…"
    public static let devicesMissingHint = "A device only shows here once it has synced with this version. Any device not listed has to pair again after you remove one."
    public static let deviceThis = "This device"
    public static let actionRemoveDevice = "Remove"
    public static let removeDeviceTitle = "Remove {device}?"
    public static let removeDeviceMessage = "It stops syncing and can't read anything copied from now on. Your other devices switch to a new key the next time they sync. Anything already on it stays there. Images and files that only it had keep their preview but can't be downloaded any more."
    public static let removeDeviceConfirm = "Remove device"
    public static let deviceRemoved = "{device} was removed."

    // MARK: Share extension and Shortcuts
    public static let shareSent = "Sent to ClipSync"
    public static let shareSavedOffline = "Saved. It syncs when the server is reachable."
    public static let shareUploadLater = "Saved. The file finishes uploading the next time ClipSync is open."
    // The App Intents compiler needs literal strings, so these five are repeated as literals in
    // apps/Apple/Shared/SendClipboardIntent.swift. `StringsTests.testIntentLiteralsMatchStrings` checks them.
    public static let intentTitle = "Send Clipboard to ClipSync"
    public static let intentDescription = "Adds text to your ClipSync history and syncs it to your other devices."
    public static let intentTextParameter = "Text"
    public static let intentTextPrompt = "What text do you want to send?"
    public static let intentShortTitle = "Send Clipboard"

    // MARK: Errors (see AppMessage)
    public static let errorEmptyText = "There's no text to send."
    public static let errorTooLarge = "That clip is too large to sync."
    public static let errorInvalidCode = "That code isn't valid. Check it and try again."
    public static let errorCodeNotFound = "That code has expired or was already used. Make a new one on the other device."
    public static let errorCodeMismatch = "That code doesn't match. Check it and try again."
    public static let errorInvalidServer = "Enter a server URL, like http://relay:8787."
    public static let errorServerUnreachable = "Can't reach the server. Check Tailscale and the URL."
    public static let errorServer = "The server returned an error. Try again."
    public static let errorUnauthorized = "The server rejected this device's key."
    public static let errorRateLimited = "The server is busy. Try again in a minute."
    public static let errorStorage = "Couldn't read or write the local database."
    public static let errorKeychain = "Couldn't access the Keychain."
    public static let errorNotSetUp = "Open ClipSync and finish setup first."
    public static let errorFileTooLarge = "That file is too large to sync. The limit is {limit}."
    public static let errorUnreadableFile = "Couldn't read that file."
    public static let errorNotUploadedYet = "This isn't on the relay yet. Try again in a moment. If the device that sent it was removed, only the preview is left."
    public static let errorDownloadFailed = "The download didn't match what was sent. Try again."
    public static let errorUnknown = "Something went wrong. Try again."
    public static let errorRemovedFromVault = "This device was removed from your vault, so it no longer syncs."
    public static let errorCannotRemoveThisDevice = "A device can't remove itself. Remove it from another device."
    public static let errorUnknownDevice = "That device isn't in your vault any more."
    public static let errorNotRegistered = "This device isn't in the device list yet. Let it sync once, then try again."

    /// Every key and value, for the content/app.md sync test.
    static let all: [String: String] = [
        "appName": appName,
        "historyTitle": historyTitle, "sectionPinned": sectionPinned, "sectionRecent": sectionRecent,
        "searchPrompt": searchPrompt, "emptyHistory": emptyHistory, "noResults": noResults, "loadMore": loadMore,
        "fromDevice": fromDevice, "copied": copied,
        "kindImage": kindImage, "kindFile": kindFile, "downloading": downloading,
        "clipboardImageName": clipboardImageName, "shareUploadLater": shareUploadLater,
        "actionCopy": actionCopy, "actionPin": actionPin, "actionUnpin": actionUnpin, "actionRename": actionRename,
        "actionAddTag": actionAddTag, "actionRemoveTag": actionRemoveTag, "actionDelete": actionDelete,
        "renameTitle": renameTitle, "renamePlaceholder": renamePlaceholder, "tagTitle": tagTitle,
        "tagPlaceholder": tagPlaceholder, "save": save, "cancel": cancel, "done": done, "ok": ok,
        "sendClipboard": sendClipboard,
        "statusSynced": statusSynced, "statusSyncing": statusSyncing, "statusOffline": statusOffline,
        "menuPauseCapture": menuPauseCapture, "menuResumeCapture": menuResumeCapture,
        "capturePaused": capturePaused, "menuReceiveLatest": menuReceiveLatest,
        "menuPairDevice": menuPairDevice, "menuQuit": menuQuit,
        "settingsTitle": settingsTitle, "expiryTitle": expiryTitle, "expiryHint": expiryHint,
        "expiryOff": expiryOff, "expiryOneDay": expiryOneDay, "expiryDays": expiryDays,
        "onboardingTitle": onboardingTitle, "onboardingIntro": onboardingIntro, "serverLabel": serverLabel,
        "serverPlaceholder": serverPlaceholder, "serverHint": serverHint,
        "deviceNameLabel": deviceNameLabel, "deviceNameHint": deviceNameHint,
        "createVault": createVault, "createVaultHint": createVaultHint,
        "joinVault": joinVault, "joinVaultHint": joinVaultHint, "codeLabel": codeLabel,
        "codePlaceholder": codePlaceholder, "working": working,
        "pairTitle": pairTitle, "pairInstructions": pairInstructions, "pairExpiry": pairExpiry,
        "pairNewCode": pairNewCode,
        "shareSent": shareSent, "shareSavedOffline": shareSavedOffline,
        "intentTitle": intentTitle, "intentDescription": intentDescription,
        "intentTextParameter": intentTextParameter, "intentTextPrompt": intentTextPrompt,
        "intentShortTitle": intentShortTitle,
        "errorEmptyText": errorEmptyText, "errorTooLarge": errorTooLarge, "errorInvalidCode": errorInvalidCode,
        "errorCodeNotFound": errorCodeNotFound, "errorCodeMismatch": errorCodeMismatch,
        "errorInvalidServer": errorInvalidServer, "errorServerUnreachable": errorServerUnreachable,
        "errorServer": errorServer, "errorUnauthorized": errorUnauthorized, "errorRateLimited": errorRateLimited,
        "errorStorage": errorStorage, "errorKeychain": errorKeychain, "errorNotSetUp": errorNotSetUp,
        "errorFileTooLarge": errorFileTooLarge, "errorUnreadableFile": errorUnreadableFile,
        "errorNotUploadedYet": errorNotUploadedYet, "errorDownloadFailed": errorDownloadFailed,
        "errorUnknown": errorUnknown,
        "statusRemoved": statusRemoved,
        "statusDirect": statusDirect,
        "syncPathRelay": syncPathRelay,
        "syncPathDirect": syncPathDirect,
        "syncPathNone": syncPathNone,
        "menuDevices": menuDevices,
        "devicesTitle": devicesTitle,
        "devicesIntro": devicesIntro,
        "devicesLoading": devicesLoading,
        "devicesMissingHint": devicesMissingHint,
        "deviceThis": deviceThis,
        "actionRemoveDevice": actionRemoveDevice,
        "removeDeviceTitle": removeDeviceTitle,
        "removeDeviceMessage": removeDeviceMessage,
        "removeDeviceConfirm": removeDeviceConfirm,
        "deviceRemoved": deviceRemoved,
        "errorRemovedFromVault": errorRemovedFromVault,
        "errorCannotRemoveThisDevice": errorCannotRemoveThisDevice,
        "errorUnknownDevice": errorUnknownDevice,
        "errorNotRegistered": errorNotRegistered,
    ]

    /// Fills `{name}` placeholders, e.g. `format(fromDevice, ["device": "iPhone"])`.
    public static func format(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
