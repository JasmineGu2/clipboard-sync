import ClipWire
import Foundation
import Hummingbird
import Logging
import RelayCore

// ClipRelay: the encrypted clipboard relay. Bind it to the Tailscale IP, never 0.0.0.0 (N10).
//
//   ClipRelay --host 100.x.y.z --port 8787 --db /var/lib/clip-relay/relay.sqlite3
//
// Each flag can also come from the environment: CLIP_RELAY_HOST, CLIP_RELAY_PORT, CLIP_RELAY_DB,
// CLIP_RELAY_TOKEN_SHA256, CLIP_RELAY_ALLOW_NON_TAILNET, CLIP_RELAY_BLOB_MAX_AGE_DAYS. Without a token hash the
// relay adopts the first bearer token it sees. It refuses a --host outside loopback and the tailnet unless
// --allow-non-tailnet is given (BindPolicy).

struct Options {
    var host = "127.0.0.1"
    var port = 8787
    var dbPath = "relay.sqlite3"
    /// SHA-256 of the bearer token, lowercase hex. nil means trust on first use.
    var tokenSHA256: String?
    /// Explicit opt-in to bind an address outside loopback and the tailnet (N10).
    var allowNonTailnet = false
    /// Incomplete blob uploads untouched this long are purged.
    var blobMaxAgeDays = Int(BlobPurger.defaultMaxAgeSeconds / 86_400)

    static let usage = """
        Usage: ClipRelay [--host <address>] [--port <port>] [--db <path>] [--token-sha256 <hex>]
                         [--allow-non-tailnet] [--blob-max-age-days <days>]
          --host               address to bind (default 127.0.0.1; use the Tailscale IP). Must be loopback
                               (127.0.0.0/8, ::1) or Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48)
                               unless --allow-non-tailnet is given.                env CLIP_RELAY_HOST
          --port               port (default 8787)                                  env CLIP_RELAY_PORT
          --db                 SQLite database path (default ./relay.sqlite3)        env CLIP_RELAY_DB
          --token-sha256       SHA-256 of the bearer token, 64 hex chars. Turns off trust on first use.
                               env CLIP_RELAY_TOKEN_SHA256
          --allow-non-tailnet  bind any address, 0.0.0.0 included. Only when something else keeps the port
                               off the internet (docker -p <tailscale ip>:8787:8787).
                               env CLIP_RELAY_ALLOW_NON_TAILNET=1
          --blob-max-age-days  purge image and file uploads that never finished after this many days
                               without a new chunk (default 7)            env CLIP_RELAY_BLOB_MAX_AGE_DAYS
        """

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var options = Options()
        if let host = environment["CLIP_RELAY_HOST"], !host.isEmpty { options.host = host }
        if let raw = environment["CLIP_RELAY_PORT"], !raw.isEmpty { options.port = try port(raw) }
        if let db = environment["CLIP_RELAY_DB"], !db.isEmpty { options.dbPath = db }
        if let hash = environment["CLIP_RELAY_TOKEN_SHA256"], !hash.isEmpty { options.tokenSHA256 = try tokenHash(hash) }
        if let raw = environment["CLIP_RELAY_ALLOW_NON_TAILNET"], !raw.isEmpty { options.allowNonTailnet = try flag(raw) }
        if let raw = environment["CLIP_RELAY_BLOB_MAX_AGE_DAYS"], !raw.isEmpty { options.blobMaxAgeDays = try days(raw) }

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard let next = iterator.next() else { throw OptionError("\(name) needs a value") }
                return next
            }
            switch name {
            case "--host": options.host = try value()
            case "--port": options.port = try port(try value())
            case "--db": options.dbPath = try value()
            case "--token-sha256": options.tokenSHA256 = try tokenHash(try value())
            case "--allow-non-tailnet":
                options.allowNonTailnet = try inlineValue.map(flag) ?? true
            case "--blob-max-age-days": options.blobMaxAgeDays = try days(try value())
            case "-h", "--help":
                print(usage)
                exit(0)
            default: throw OptionError("unknown argument \(argument)")
            }
        }
        return options
    }

    private static func tokenHash(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WireLimits.isValidSHA256Hex(trimmed) else {
            throw OptionError("--token-sha256 must be 64 hex characters (SHA-256 of the token, not the token)")
        }
        return trimmed.lowercased()
    }

    private static func flag(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw OptionError("expected 1 or 0, got \(raw)")
        }
    }

    private static func days(_ raw: String) throws -> Int {
        guard let days = Int(raw), (1...3650).contains(days) else {
            throw OptionError("--blob-max-age-days must be 1...3650")
        }
        return days
    }

    private static func port(_ raw: String) throws -> Int {
        guard let port = Int(raw), (1...65535).contains(port) else { throw OptionError("invalid port \(raw)") }
        return port
    }
}

struct OptionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(Options.usage)\n".utf8))
    exit(2)
}

var logger = Logger(label: "ClipRelay")
logger.logLevel = .info

// N10: refuse an address outside loopback and the tailnet before opening anything.
switch BindPolicy.decide(host: options.host, allowNonTailnet: options.allowNonTailnet) {
case .allow: break
case .warn(let message): logger.warning("\(message)")
case .refuse(let message):
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

let storage = try SQLiteRelayStorage(path: options.dbPath)
var config = RelayConfig()
config.authTokenSHA256 = options.tokenSHA256
if let hash = options.tokenSHA256 {
    // Apply the pin now so a bad database fails at startup, not on the first request.
    _ = try await storage.seedAuthTokenHash(hash)
}
let app = Application(
    router: buildRelayRouter(storage: storage, notifier: PushNotifier(), config: config),
    configuration: .init(address: .hostname(options.host, port: options.port), serverName: "ClipRelay"),
    logger: logger
)

let epoch = try await storage.epoch()
logger.info("ClipRelay starting", metadata: [
    "host": "\(options.host)", "port": "\(options.port)", "db": "\(options.dbPath)",
    "epoch": "\(epoch)",
    "auth": "\(options.tokenSHA256 == nil ? "trust on first use" : "pinned token hash")",
])
// Stale blob uploads: one pass at startup (before serving, so a crash loop can't skip it), then hourly.
let purger = BlobPurger(storage: storage, maxAgeSeconds: Int64(options.blobMaxAgeDays) * 86_400)
let purged = try await purger.runOnce()
logger.info("Stale blob purge at startup", metadata: [
    "maxAgeDays": "\(options.blobMaxAgeDays)", "blobs": "\(purged.blobs)", "bytes": "\(purged.bytes)",
])
Task {
    try? await Task.sleep(for: .seconds(BlobPurger.defaultIntervalSeconds))
    await purger.run(every: .seconds(BlobPurger.defaultIntervalSeconds), logger: logger)
}
try await app.runService()
