#if os(Windows)
import Foundation

/// Where Windows clients keep config.json, clips.sqlite and the DPAPI-protected keys.
/// clipctl and the tray app share it, so the tray app picks up a clipctl pairing as is.
public enum WindowsPaths {
    /// `%APPDATA%\ClipSync`, or nil when APPDATA isn't set.
    public static var appDataHome: URL? {
        guard let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty else { return nil }
        return URL(fileURLWithPath: appData, isDirectory: true).appendingPathComponent("ClipSync", isDirectory: true)
    }

    /// The vault key file inside a home folder (`key.dpapi`; the device key sits next to it).
    public static func keyURL(home: URL) -> URL {
        home.appendingPathComponent("key.dpapi")
    }
}
#endif
