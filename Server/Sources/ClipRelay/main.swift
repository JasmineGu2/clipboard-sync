import Foundation
import Hummingbird
import Logging
import RelayCore

// ClipRelay: the encrypted clipboard relay. Bind it to the Tailscale IP, never 0.0.0.0 (N10).
//
//   ClipRelay --host 100.x.y.z --port 8787 --db /var/lib/clip-relay/relay.sqlite3
//
// Each flag can also come from the environment: CLIP_RELAY_HOST, CLIP_RELAY_PORT, CLIP_RELAY_DB.

struct Options {
    var host = "127.0.0.1"
    var port = 8787
    var dbPath = "relay.sqlite3"

    static let usage = """
        Usage: ClipRelay [--host <address>] [--port <port>] [--db <path>]
          --host  address to bind (default 127.0.0.1; use the Tailscale IP, never 0.0.0.0)  env CLIP_RELAY_HOST
          --port  port (default 8787)                                                      env CLIP_RELAY_PORT
          --db    SQLite database path (default ./relay.sqlite3)                            env CLIP_RELAY_DB
        """

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var options = Options()
        if let host = environment["CLIP_RELAY_HOST"], !host.isEmpty { options.host = host }
        if let raw = environment["CLIP_RELAY_PORT"], !raw.isEmpty { options.port = try port(raw) }
        if let db = environment["CLIP_RELAY_DB"], !db.isEmpty { options.dbPath = db }

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
            case "-h", "--help":
                print(usage)
                exit(0)
            default: throw OptionError("unknown argument \(argument)")
            }
        }
        return options
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

let storage = try SQLiteRelayStorage(path: options.dbPath)
let app = Application(
    router: buildRelayRouter(storage: storage, notifier: PushNotifier()),
    configuration: .init(address: .hostname(options.host, port: options.port), serverName: "ClipRelay"),
    logger: logger
)

logger.info("ClipRelay starting", metadata: [
    "host": "\(options.host)", "port": "\(options.port)", "db": "\(options.dbPath)",
])
if options.host == "0.0.0.0" || options.host == "::" {
    logger.warning("Listening on every interface. Outside a container, bind the Tailscale IP instead.")
}
try await app.runService()
