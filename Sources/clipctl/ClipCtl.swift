import ArgumentParser
import ClipAppCore
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
            Init.self, Pair.self, Add.self, SendFile.self, List.self, Search.self, Copy.self, Get.self,
            Pin.self, Unpin.self, Rename.self, Tag.self, Untag.self, Delete.self, Expire.self,
            Sync.self, Status.self, Watch.self, Devices.self, Revoke.self,
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
            // Sync first: if another device revoked one since, this picks up the new vault key, and the code must
            // carry that one, not the key loaded from disk.
            try? await client.sync(timeout: Client.afterChangeTimeout)
            let key = await client.engine.currentVaultKey
            let transport = HTTPTransport(baseURL: try relayURL(client.config.serverURL), token: key.authToken)
            let code = try await SyncEngine.startPairing(vaultKey: key, transport: transport)
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

struct SendFile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-file",
        abstract: "Add an image or file to the history and upload it (encrypted, in 1 MiB chunks).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The file to send.") var path: String
    @Option(help: "Name shown on other devices (default: the file's name).") var name: String?

    func run() async throws {
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw CLIError("No file at \(path).")
        }
        let client = try Client.open(global)
        let shownName = name ?? url.lastPathComponent
        let type = FileTypes.contentType(forName: shownName)
        let kind = FileTypes.kind(forContentType: type)
        let thumbnail = kind == .image
            ? platformThumbnailMaker().thumbnail(forFileAt: url, maxBytes: ItemContent.maxThumbnailBytes) : nil
        let id: ItemID
        do {
            id = try await client.engine.addFile(at: url, kind: kind, name: shownName, contentType: type, thumbnail: thumbnail)
        } catch {
            throw CLIError("Not added: \(describe(error))")
        }
        let blob = try client.db.item(id)?.content?.blob
        print("added \(shortID(id)) [\(kind.rawValue) \(FileTypes.sizeText(blob?.size ?? 0))]"
              + (thumbnail.map { " with a \($0.count)-byte thumbnail" } ?? ""))
        await client.syncAfterChange()
        do {
            let sent = try await client.uploadPending()
            print("uploaded \(sent) file\(sent == 1 ? "" : "s")")
        } catch {
            warn("upload stopped (\(describe(error))); it resumes on the next `clipctl sync` or `watch`")
        }
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download an image or file (resuming an earlier try) and save it, or print a text item.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The start of the item's ID.") var id: String
    @Option(help: "Where to save it (default: the item's name, in the current folder).") var out: String?
    @Flag(help: "Replace the file at --out if it exists.") var force = false

    func run() async throws {
        let client = try Client.open(global)
        let item = try client.item(prefix: id)
        guard let content = item.content, let blob = content.blob else {
            let text = item.content?.text ?? ""
            if let out {
                try Data(text.utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
                print("saved \(out)")
            } else {
                print(text)
            }
            return
        }
        let destination = URL(fileURLWithPath: out ?? FileTypes.safeFileName(content.text, fallback: shortID(item.id)))
        if FileManager.default.fileExists(atPath: destination.path), !force {
            throw CLIError("\(destination.path) exists. Pass --force to replace it, or choose another --out.")
        }
        let cached: URL
        do {
            cached = try await client.engine.fetchBlob(for: item.id, progress: chunkProgress("download"))
        } catch {
            throw CLIError("Download failed: \(describe(error))")
        }
        try client.engine.blobCache?.export(blob.id, to: destination)
        let hex = blob.sha256.map { String(format: "%02x", $0) }.joined()
        print("saved \(destination.path) (\(FileTypes.sizeText(blob.size)), SHA-256 \(hex.prefix(16))… verified)")
        _ = cached
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
        let item = try client.item(prefix: id)
        if item.content?.blob != nil {
            throw CLIError("That's an image or file. Save it with `clipctl get \(shortID(item.id)) --out <path>`.")
        }
        let text = item.content?.text ?? ""
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
        let pending = try client.db.pendingBlobUploads().count
        if pending > 0 {
            do {
                let sent = try await client.uploadPending()
                print("uploaded \(sent) file\(sent == 1 ? "" : "s")")
            } catch {
                throw CLIError("Upload failed: \(describe(error)). It resumes on the next sync.")
            }
        }
        let collected = await client.engine.collectGarbage()
        if collected.localFiles + collected.relayBlobs > 0 {
            print("freed \(collected.localFiles) local file(s) and \(collected.relayBlobs) relay blob(s) of deleted items")
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show this client's setup and sync state.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = try Client.open(global)
        let db = client.db
        let pending = try db.pendingOutbound(limit: Int(Int32.max)).count
        let uploads = try db.pendingBlobUploads(limit: Int(Int32.max)).count
        let rows: [(String, String)] = [
            ("Home", client.home.url.path),
            ("Server", client.config.serverURL),
            ("Device", "\(client.config.deviceName) (\(client.config.deviceID.uuidString.lowercased()))"),
            ("Key", keyStoreLabel()),
            ("Items", String(try db.count())),
            ("Pending", "\(pending) change\(pending == 1 ? "" : "s") waiting to push"),
            ("Uploads", "\(uploads) file\(uploads == 1 ? "" : "s") waiting to upload"),
            ("Cursor", String(try db.syncCursor())),
            ("Last sync", try db.meta(Client.lastSyncKey) ?? "never"),
            ("Last error", try db.meta(Client.lastErrorKey) ?? "none"),
            // The engine's key: a revoke on another device may have replaced the one on disk at open.
            ("Relay pin", await client.engine.currentVaultKey.authTokenSHA256),
            ("Capture", client.home.isPaused ? "paused (\(client.home.pausedURL.path) exists)" : "on"),
        ]
        for (label, value) in rows {
            print(label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }
    }
}

// MARK: - Devices (F13)

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the devices in this vault.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = try Client.open(global)
        do {
            try await client.sync(timeout: Client.afterChangeTimeout)
        } catch {
            throw CLIError("Can't read the device list: \(describe(error))")
        }
        let devices: [VaultDevice]
        do {
            devices = try await client.engine.devices()
        } catch {
            throw CLIError("Can't read the device list: \(describe(error))")
        }
        for device in devices {
            print("\(shortDeviceID(device.id))  \(device.name)\(device.isThisDevice ? "  (this device)" : "")")
        }
        print("A device shows here once it has synced with this version. Any device not listed has to pair again after a revoke.")
    }
}

struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a lost device from the vault. It can't sync or read anything new afterwards.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The device: the start of its ID from `clipctl devices`, or its exact name.") var device: String
    @Flag(help: "Don't ask for confirmation.") var yes = false

    func run() async throws {
        let client = try Client.open(global)
        do {
            try await client.sync(timeout: Client.syncTimeout)
        } catch {
            throw CLIError("Not revoked: sync first failed (\(describe(error)))")
        }
        let devices = try await client.engine.devices()
        let target = try pick(device, from: devices)
        guard !target.isThisDevice else { throw CLIError(describe(SyncError.cannotRevokeThisDevice)) }
        if !yes {
            print("Remove \(target.name) (\(shortDeviceID(target.id)))? It stops syncing and can't read anything copied from now on. [y/N] ", terminator: "")
            fflush(nil)
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                print("Not revoked.")
                return
            }
        }
        do {
            try await client.engine.revoke([target.id])
        } catch {
            throw CLIError("Not revoked: \(describe(error))")
        }
        print("revoked \(target.name). This device now uses a new vault key.")
        // The relay dropped every image and file with the log; send this device's copies again under the new key.
        do {
            let sent = try await client.uploadPending()
            if sent > 0 { print("uploaded \(sent) file\(sent == 1 ? "" : "s") again under the new key") }
        } catch {
            warn("re-upload stopped (\(describe(error))); it resumes on the next `clipctl sync` or `watch`")
        }
        print("Your other devices switch to it the next time they sync. Relay pin is now \(await client.engine.currentVaultKey.authTokenSHA256).")
    }

    /// By ID prefix (dashes and case don't matter) or by exact name.
    func pick(_ wanted: String, from devices: [VaultDevice]) throws -> VaultDevice {
        let prefix = wanted.lowercased().replacingOccurrences(of: "-", with: "")
        let byID = prefix.isEmpty ? [] : devices.filter {
            $0.id.lowercased().replacingOccurrences(of: "-", with: "").hasPrefix(prefix)
        }
        let matches = byID.isEmpty ? devices.filter { $0.name == wanted } : byID
        switch matches.count {
        case 1: return matches[0]
        case 0: throw CLIError("No device matches \"\(wanted)\". Try `clipctl devices`.")
        default:
            throw CLIError("\"\(wanted)\" matches \(matches.count) devices. Type more of the ID from `clipctl devices`.")
        }
    }
}

/// The first 8 hex digits of a device ID, lower case, like item IDs in `list`.
func shortDeviceID(_ id: String) -> String {
    String(id.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
}
