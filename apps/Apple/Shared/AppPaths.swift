import Foundation

/// Where the database and config live.
enum AppPaths {
    static let appGroupID = "group.dev.jazz.clipsync"

    /// iOS: inside the App Group container, so the share extension and the Shortcuts action see the same
    /// history as the app. macOS: Application Support (inside the sandbox container).
    static var home: URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("ClipSync", isDirectory: true)
        }
        // No App Group entitlement (e.g. the signing team can't provide one): the app still works on its own;
        // the share extension then reports "finish setup first".
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("ClipSync", isDirectory: true)
    }
}
