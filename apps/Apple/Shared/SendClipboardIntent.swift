import AppIntents
import ClipAppCore
import Foundation

/// F2: "Send Clipboard to ClipSync" for Shortcuts. A Shortcut passes Get Clipboard as `text`,
/// so the app never reads the pasteboard itself (no paste prompt).
///
/// The App Intents compiler reads titles from literals only, so the strings below repeat
/// `Strings.intentTitle`, `.intentDescription`, `.intentTextParameter` and `.intentShortTitle`
/// (content/app.md). `StringsTests.testIntentLiteralsMatchStrings` fails if they drift.
struct SendClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Clipboard to ClipSync"
    static let description = IntentDescription("Adds text to your ClipSync history and syncs it to your other devices.")
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await ClipApp.sendOnce(text, home: AppPaths.home, keyStore: KeychainKeyStore.appDefault)
        if case .failed = result {
            throw SendFailed(text: result.text)
        }
        return .result(dialog: "\(result.text)")
    }

    struct SendFailed: Error, CustomLocalizedStringResourceConvertible {
        let text: String
        var localizedStringResource: LocalizedStringResource { "\(text)" }
    }
}

struct ClipSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendClipboardIntent(),
            phrases: ["Send clipboard to \(.applicationName)"],
            shortTitle: "Send Clipboard",
            systemImageName: "doc.on.clipboard"
        )
    }
}
