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

    // MARK: Mac menu
    public static let menuPauseCapture = "Pause capture"
    public static let menuResumeCapture = "Resume capture"
    public static let capturePaused = "Capture is paused"
    public static let menuPairDevice = "Pair new device…"
    public static let menuQuit = "Quit ClipSync"

    // MARK: Onboarding
    public static let onboardingTitle = "Set up ClipSync"
    public static let onboardingIntro = "Your history is encrypted on this device. The server only stores ciphertext."
    public static let serverLabel = "Server URL"
    public static let serverPlaceholder = "http://relay.your-tailnet.ts.net:8787"
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

    // MARK: Share extension and Shortcuts
    public static let shareSent = "Sent to ClipSync"
    public static let shareSavedOffline = "Saved. It syncs when the server is reachable."
    // The App Intents compiler needs literal strings, so these four are repeated as literals in
    // apps/Apple/Shared/SendClipboardIntent.swift. `StringsTests.testIntentLiteralsMatchStrings` checks them.
    public static let intentTitle = "Send Clipboard to ClipSync"
    public static let intentDescription = "Adds text to your ClipSync history and syncs it to your other devices."
    public static let intentTextParameter = "Text"
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
    public static let errorUnknown = "Something went wrong. Try again."

    /// Every key and value, for the content/app.md sync test.
    static let all: [String: String] = [
        "appName": appName,
        "historyTitle": historyTitle, "sectionPinned": sectionPinned, "sectionRecent": sectionRecent,
        "searchPrompt": searchPrompt, "emptyHistory": emptyHistory, "noResults": noResults, "loadMore": loadMore,
        "fromDevice": fromDevice, "copied": copied,
        "actionCopy": actionCopy, "actionPin": actionPin, "actionUnpin": actionUnpin, "actionRename": actionRename,
        "actionAddTag": actionAddTag, "actionRemoveTag": actionRemoveTag, "actionDelete": actionDelete,
        "renameTitle": renameTitle, "renamePlaceholder": renamePlaceholder, "tagTitle": tagTitle,
        "tagPlaceholder": tagPlaceholder, "save": save, "cancel": cancel, "done": done, "ok": ok,
        "sendClipboard": sendClipboard,
        "statusSynced": statusSynced, "statusSyncing": statusSyncing, "statusOffline": statusOffline,
        "menuPauseCapture": menuPauseCapture, "menuResumeCapture": menuResumeCapture,
        "capturePaused": capturePaused, "menuPairDevice": menuPairDevice, "menuQuit": menuQuit,
        "onboardingTitle": onboardingTitle, "onboardingIntro": onboardingIntro, "serverLabel": serverLabel,
        "serverPlaceholder": serverPlaceholder, "createVault": createVault, "createVaultHint": createVaultHint,
        "joinVault": joinVault, "joinVaultHint": joinVaultHint, "codeLabel": codeLabel,
        "codePlaceholder": codePlaceholder, "working": working,
        "pairTitle": pairTitle, "pairInstructions": pairInstructions, "pairExpiry": pairExpiry,
        "pairNewCode": pairNewCode,
        "shareSent": shareSent, "shareSavedOffline": shareSavedOffline,
        "intentTitle": intentTitle, "intentDescription": intentDescription,
        "intentTextParameter": intentTextParameter, "intentShortTitle": intentShortTitle,
        "errorEmptyText": errorEmptyText, "errorTooLarge": errorTooLarge, "errorInvalidCode": errorInvalidCode,
        "errorCodeNotFound": errorCodeNotFound, "errorCodeMismatch": errorCodeMismatch,
        "errorInvalidServer": errorInvalidServer, "errorServerUnreachable": errorServerUnreachable,
        "errorServer": errorServer, "errorUnauthorized": errorUnauthorized, "errorRateLimited": errorRateLimited,
        "errorStorage": errorStorage, "errorKeychain": errorKeychain, "errorNotSetUp": errorNotSetUp,
        "errorUnknown": errorUnknown,
    ]

    /// Fills `{name}` placeholders, e.g. `format(fromDevice, ["device": "iPhone"])`.
    public static func format(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
