import Foundation

/// Per-device settings, stored as JSON next to the database. Holds no secrets: the vault key lives in the
/// platform KeyStore (N9).
public struct AppConfig: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var deviceID: UUID
    public var deviceName: String
    /// F15: the Mac watcher stops capturing while true.
    public var capturePaused: Bool
    /// Puts the newest copy from another device on this device's clipboard (`LatestClipFollower`).
    public var receivesLatest: Bool
    /// F14: unpinned items older than this many days are deleted on every device. nil keeps them forever.
    public var expiryDays: Int?

    public init(
        serverURL: URL, deviceID: UUID = UUID(), deviceName: String, capturePaused: Bool = false,
        receivesLatest: Bool = true, expiryDays: Int? = nil
    ) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.capturePaused = capturePaused
        self.receivesLatest = receivesLatest
        self.expiryDays = expiryDays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        capturePaused = try container.decodeIfPresent(Bool.self, forKey: .capturePaused) ?? false
        receivesLatest = try container.decodeIfPresent(Bool.self, forKey: .receivesLatest) ?? true
        expiryDays = try container.decodeIfPresent(Int.self, forKey: .expiryDays)
    }

    /// nil when the file doesn't exist yet.
    public static func load(from url: URL) throws -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads what the user typed: trims it, adds `http://` when there's no scheme, and requires http(s) and a host.
    public static func parseServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
