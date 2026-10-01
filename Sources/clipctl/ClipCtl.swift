import ArgumentParser
import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation

// Help strings are inline because ArgumentParser needs them in code; the longer guide is content/clipctl.md.

struct ClipCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipctl",
        abstract: "End-to-end encrypted clipboard history, from the command line.",
        discussion: "Full guide: content/clipctl.md",
        subcommands: [
            Init.self, Pair.self, Add.self, List.self, Search.self, Copy.self,
            Pin.self, Unpin.self, Rename.self, Tag.self, Untag.self, Delete.self, Expire.self,
            Sync.self, Status.self, Watch.self,
        ]
    )

    @OptionGroup var global: GlobalOptions
}

// MARK: - Setup

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new vault on this device.")

    @OptionGroup var global: GlobalOptions
    @Option(help: "Relay URL, e.g. http://relay.tailnet:8080") var server: String
    @Option(help: "Name shown on other devices (default: the computer name).") var name: String?

    func run() async throws {
        let home = global.homeFolder
        let url = try relayURL(server)
        guard !home.hasConfig else {
            throw CLIError("\(home.url.path) already has a client. Use another --home, or move that folder away first.")
        }
        let store = try makeKeyStore(home: home, insecureFileKey: global.insecureFileKey)
        guard try store.loadVaultKey() == nil else {
            throw CLIError("\(home.url.path) already holds a vault key. Move it away before creating a new vault.")
        }
        try home.create()
        try store.saveVaultKey(VaultKey.generate())
        let config = Config(serverURL: url.absoluteString, deviceID: UUID(), deviceName: name ?? defaultDeviceName())
        try home.save(config)
        print("Created a new vault in \(home.url.path)")
        print("Device: \(config.deviceName). Server: \(config.serverURL)")
        print("To add another device, run `clipctl pair start` here.")
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the vault key to another device with a one-time code.",
        subcommands: [Start.self, Join.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a pairing code on this (already set up) device.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let client = try Client.open(global)
            let code = try await SyncEngine.startPairing(vaultKey: client.key, transport: client.transport)
            print("Pairing code: \(code.display)")
            print("Type it on the new device with `clipctl pair join --server \(client.config.serverURL) <code>`.")
            print("It expires in 10 minutes and works once.")
        }
    }

    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Join an existing vault with a pairing code.")
        @OptionGroup var global: GlobalOptions
        @Option(help: "Relay URL (the same one the other device uses).") var server: String
        @Option(help: "Name shown on other devices (default: the computer name).") var name: String?
        @Argument(help: "The code shown by `clipctl pair start` (dashes and case don't matter).") var code: String

        func run() async throws {
            let home = global.homeFolder
            let url = try relayURL(server)
            guard !home.hasConfig else {
                throw CLIError("\(home.url.path) already has a client. Use another --home, or move that folder away first.")
            }
            let store = try makeKeyStore(home: home, insecureFileKey: global.insecureFileKey)
            let key: VaultKey
            do {
                key = try await SyncEngine.completePairing(code: code, transport: HTTPTransport(baseURL: url, token: nil))
            } catch {
                throw CLIError("Pairing failed: \(describe(error))")
            }
            try home.create()
            try store.saveVaultKey(key)
            let config = Config(serverURL: url.absoluteString, deviceID: UUID(), deviceName: name ?? defaultDeviceName())
            try home.save(config)
            print("Joined the vault. Device: \(config.deviceName)")
            let client = try Client.open(global)
            await client.syncAfterChange()
            print("\(try client.db.count()) items")
        }
    }
}

// MARK: - Items

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add text to the history (`-` reads stdin).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The text, or - to read it from stdin.") var text: String

    func run() async throws {
        var value = text
        if text == "-" {
            value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            // Pipes add one line ending; keep everything else as typed.
            // One Character covers both "\n" and "\r\n" (a single grapheme cluster in Swift).
            if value.last?.isNewline == true { value.removeLast() }
            // Windows PowerShell pipes can start with a UTF-8 byte order mark; it's never part of the text.
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        let client = try Client.open(global)
        let id: ItemID
        do {
            id = try await client.engine.addText(value)
        } catch {
            throw CLIError("Not added: \(describe(error))")
        }
        print("added \(shortID(id))")
        await client.syncAfterChange()
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent items, newest first.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "How many items.") var limit = 20
    @Flag(help: "Print JSON instead of lines.") var json = false

    func run() async throws {
        let client = try Client.open(global)
        try printItems(client.db.items(limit: max(1, limit)), json: json, emptyMessage: "No items yet.")
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search text, titles and tags (each word is a prefix).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Words to find.") var query: String
    @Option(help: "How many results.") var limit = 20
    @Flag(help: "Print JSON instead of lines.") var json = false

    func run() async throws {
        let client = try Client.open(global)
        try printItems(client.db.search(query, limit: max(1, limit)), json: json, emptyMessage: "No matches.")
    }
}

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Put an item's text on the clipboard.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String

    func run() async throws {
        let client = try Client.open(global)
        let text = try client.item(prefix: id).content?.text ?? ""
        #if os(Windows)
        try WindowsClipboard.write(text)
        print("copied \(preview(text))")
        #else
        print(text)
        #endif
    }
}

/// Shared shape of the commands that change one item and then sync.
protocol ItemCommand: AsyncParsableCommand {
    var global: GlobalOptions { get }
    var id: String { get }
    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String
}

extension ItemCommand {
    func run() async throws {
        let client = try Client.open(global)
        let item = try client.item(prefix: id)
        print(try await change(item, client.engine))
        await client.syncAfterChange()
    }
}

struct Pin: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Pin an item.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        try await engine.setPinned(item.id, true)
        return "pinned \(shortID(item.id))"
    }
}

struct Unpin: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Unpin an item.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        try await engine.setPinned(item.id, false)
        return "unpinned \(shortID(item.id))"
    }
}

struct Rename: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Give an item a title (or --clear it).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String
    @Argument(help: "The new title.") var title: String?
    @Flag(help: "Remove the title.") var clear = false

    func validate() throws {
        if clear, title != nil { throw ValidationError("Give a title or --clear, not both.") }
        if !clear, title == nil { throw ValidationError("Give a new title, or --clear to remove it.") }
        if let title, title.allSatisfy(\.isWhitespace) { throw ValidationError("The title is empty; use --clear to remove it.") }
    }

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        let newTitle = clear ? nil : title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await engine.setTitle(item.id, newTitle)
        return newTitle.map { "renamed \(shortID(item.id)) to \"\($0)\"" } ?? "cleared the title of \(shortID(item.id))"
    }
}

func normalizedTag(_ tag: String) throws -> String {
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    let clean = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard !clean.isEmpty else { throw ValidationError("The tag is empty.") }
    return clean
}

struct Tag: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Add a tag to an item.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String
    @Argument(help: "The tag.") var tag: String

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        let tag = try normalizedTag(tag)
        try await engine.setTag(item.id, tag, present: true)
        return "tagged \(shortID(item.id)) #\(tag)"
    }
}

struct Untag: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a tag from an item.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String
    @Argument(help: "The tag.") var tag: String

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        let tag = try normalizedTag(tag)
        try await engine.setTag(item.id, tag, present: false)
        return "untagged \(shortID(item.id)) #\(tag)"
    }
}

struct Delete: ItemCommand {
    static let configuration = CommandConfiguration(abstract: "Delete an item on every device.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String

    func change(_ item: ItemState, _ engine: SyncEngine) async throws -> String {
        try await engine.delete(item.id)
        return "deleted \(shortID(item.id))"
    }
}

struct Expire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete unpinned items older than --days, on every device, then sync.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Age in days. Items created longer ago than this, and not pinned, are deleted.") var days: Int

    func validate() throws {
        guard (1...SyncEngine.maxExpiryDays).contains(days) else {
            throw ValidationError("--days must be between 1 and \(SyncEngine.maxExpiryDays).")
        }
    }

    func run() async throws {
        let client = try Client.open(global)
        let count = try await client.engine.expireItems(olderThan: .seconds(days * 86_400))
        print("expired \(count) item(s) older than \(days) days")
        do {
            try await client.sync(timeout: Client.syncTimeout)
        } catch {
            warn("not synced yet (\(describe(error))); the deletes go out on the next sync")
        }
    }
}

// MARK: - Sync

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push local changes and pull everyone else's, once.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = try Client.open(global)
        do {
            try await client.sync(timeout: Client.syncTimeout)
        } catch {
            throw CLIError("Sync failed: \(describe(error))")
        }
        print("synced. \(try client.db.count()) items, cursor \(try client.db.syncCursor())")
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show this client's setup and sync state.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = try Client.open(global)
        let db = client.db
        let pending = try db.pendingOutbound(limit: Int(Int32.max)).count
        let rows: [(String, String)] = [
            ("Home", client.home.url.path),
            ("Server", client.config.serverURL),
            ("Device", "\(client.config.deviceName) (\(client.config.deviceID.uuidString.lowercased()))"),
            ("Key", keyStoreLabel()),
            ("Items", String(try db.count())),
            ("Pending", "\(pending) change\(pending == 1 ? "" : "s") waiting to push"),
            ("Cursor", String(try db.syncCursor())),
            ("Last sync", try db.meta(Client.lastSyncKey) ?? "never"),
            ("Last error", try db.meta(Client.lastErrorKey) ?? "none"),
            ("Relay pin", client.key.authTokenSHA256),
            ("Capture", client.home.isPaused ? "paused (\(client.home.pausedURL.path) exists)" : "on"),
        ]
        for (label, value) in rows {
            print(label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }
    }
}
