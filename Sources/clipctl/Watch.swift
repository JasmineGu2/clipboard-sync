import ArgumentParser
import ClipCore
import ClipPeerSocket
import ClipSync
import Foundation
#if os(Windows)
import ClipWindows
import WinSDK
#endif

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep syncing and (on Windows) capture copied text. Ctrl+C to stop.",
        discussion: """
            Capture pauses while <home>/paused exists. Content marked concealed by password managers is never captured.
            On Windows, the newest copy from another device goes on this clipboard as it arrives; --no-receive turns that off.
            """
    )
    @OptionGroup var global: GlobalOptions
    @Flag(name: .customLong("no-receive"), help: "Don't put the newest copy from another device on this clipboard.")
    var noReceive = false
    @Option(help: "Delete unpinned items older than this many days, on every device. Checked hourly.")
    var expireDays: Int?
    @Option(help: ArgumentHelp(
        "When the relay is unreachable, also sync directly with your other devices, listening on this port.",
        discussion: "Listens on this device's Tailscale address only. Without it, watch still dials devices that listen."))
    var peerPort: Int?
    @Option(help: "Address for --peer-port to listen on (default: this device's Tailscale IPv4 address).")
    var peerHost: String?
    @Option(help: .hidden) var exitAfter: Double?

    /// Written by watch for `clipctl status`, which runs as a separate process.
    static let syncPathKey = "clipctl.sync_path"
    static let peerListenKey = "clipctl.peer_listen"

    static let pollInterval: Duration = .milliseconds(250)
    static let expiryInterval: Duration = .seconds(3600)

    func validate() throws {
        if let peerPort, !(1...65_535).contains(peerPort) {
            throw ValidationError("--peer-port must be between 1 and 65535.")
        }
        if peerHost != nil, peerPort == nil { throw ValidationError("--peer-host needs --peer-port.") }
        if let peerHost, PeerAddress.ipv4Octets(peerHost) == nil {
            throw ValidationError("--peer-host must be an IPv4 address, like 100.101.102.103.")
        }
        if let expireDays, !(1...SyncEngine.maxExpiryDays).contains(expireDays) {
            throw ValidationError("--expire-days must be between 1 and \(SyncEngine.maxExpiryDays).")
        }
    }

    func run() async throws {
        let client = try Client.open(global)
        let engine = client.engine
        let stop = StopSignal.install()
        let deadline = exitAfter.map { Date().addingTimeInterval($0) }

        #if os(Windows)
        say("Watching the clipboard and syncing with \(client.config.serverURL). Ctrl+C to stop.")
        #else
        say("Syncing with \(client.config.serverURL) (no clipboard capture on this OS). Ctrl+C to stop.")
        #endif
        if client.home.isPaused { say("Capture is paused: \(client.home.pausedURL.path) exists.") }

        // F16: direct sync with other devices while the relay is unreachable.
        let listener = try startPeerListener(engine: engine)
        await engine.enablePeerSync(PeerSetup(dialer: SocketPeerDialer(), listenAddress: listener?.boundAddress))
        try? client.db.setMeta(Self.peerListenKey, listener?.boundAddress)
        var lastPath: SyncPath?

        #if os(Windows)
        let receives = !noReceive
        #else
        let receives = false  // no clipboard to write to
        #endif
        // The reporter decides what to receive; the loop below writes it, so it can skip its own write.
        let inbox = ClipboardInbox()
        var baseline = LatestClipFollower(device: client.device)
        _ = baseline.update(newest: try client.db.items(limit: 1).first)

        // One line per new item, whether captured here or synced from another device.
        let alreadySeen = Set(try client.db.items(limit: 500).map(\.id))
        let reporter = Task { [baseline] in
            var seen = alreadySeen
            var follower = baseline
            for await _ in engine.changes {
                guard let fresh = try? client.db.items(limit: 50).filter({ !seen.contains($0.id) }) else { continue }
                for item in fresh.reversed() {
                    seen.insert(item.id)
                    let verb = item.content?.sourceDevice == client.device ? "captured" : "synced  "
                    say("\(verb) \(itemLine(item))")
                }
                if receives, let text = follower.update(newest: try? client.db.items(limit: 1).first) {
                    inbox.put(text)
                }
            }
        }
        let syncLoop = Task { await engine.run() }
        let expiryLoop = expireDays.map { days in
            Task {
                while !Task.isCancelled {
                    do {
                        let count = try await engine.expireItems(olderThan: .seconds(days * 86_400))
                        if count > 0 { say("expired  \(count) item(s) older than \(days) days") }
                    } catch {
                        say("expiry failed  (\(describe(error)))")
                    }
                    try? await Task.sleep(for: Self.expiryInterval)
                }
            }
        }

        #if os(Windows)
        var lastSequence = WindowsClipboard.sequenceNumber
        var wasPaused = client.home.isPaused
        #endif
        while !stop.isSet {
            if let deadline, Date() >= deadline { break }
            let path = await engine.syncPath
            if path != lastPath {
                if lastPath != nil || path != .relay { say("sync path: \(describePath(path))") }
                lastPath = path
                try? client.db.setMeta(
                    Self.syncPathKey, "\(describePath(path)) (since \(ISO8601DateFormatter().string(from: Date())))")
            }
            if await engine.status == .revoked {
                say("This device was removed from the vault, so it no longer syncs. Pair it again to use it.")
                break
            }
            try? await Task.sleep(for: Self.pollInterval)
            #if os(Windows)
            // Only when nothing new was copied here since the last check: otherwise capture that first (below),
            // and since it's newer, drop the pending receive.
            if WindowsClipboard.sequenceNumber == lastSequence, let text = inbox.take() {
                do {
                    try WindowsClipboard.write(text)
                    say("received \(preview(text))")
                } catch {
                    say("not received (\(describe(error)))")
                }
                lastSequence = WindowsClipboard.sequenceNumber  // our own write, not a copy to capture
            }
            let sequence = WindowsClipboard.sequenceNumber
            guard sequence != lastSequence else { continue }
            let paused = client.home.isPaused
            if paused != wasPaused {
                say(paused ? "Capture paused." : "Capture resumed.")
                wasPaused = paused
            }
            if paused {
                lastSequence = sequence
                continue
            }
            switch WindowsClipboard.readForCapture() {
            case .busy:
                continue  // keep lastSequence so the next tick tries again
            case .text(let text):
                _ = inbox.take()  // a copy made here is newer than anything waiting to be received
                do {
                    try await engine.addText(text)
                } catch SyncError.emptyText {
                } catch {
                    say("skipped  (\(describe(error)))")
                }
            case .concealed(let marker):
                say("skipped  concealed content (\(marker))")
            case .tooLarge:
                say("skipped  text over 1 MB")
            case .noText:
                break
            }
            lastSequence = sequence
            #endif
        }

        expiryLoop?.cancel()
        listener?.stop()
        try? client.db.setMeta(Self.peerListenKey, nil)
        try? client.db.setMeta(Self.syncPathKey, nil)
        syncLoop.cancel()
        await syncLoop.value
        // Let the reporter print anything recorded just before the stop.
        try? await Task.sleep(for: .milliseconds(100))
        reporter.cancel()
        say("Stopped.")
    }
}

extension Watch {
    /// Binds the direct-sync listener when `--peer-port` is given: on `--peer-host`, else the Tailscale address.
    func startPeerListener(engine: SyncEngine) throws -> SocketPeerListener? {
        guard let peerPort else { return nil }
        guard let host = peerHost ?? TailnetAddress.detect() else {
            throw CLIError("No Tailscale address found for --peer-port. Is Tailscale on? Or pass --peer-host.")
        }
        if !PeerAddress.isTailnet(host), !PeerAddress.isLoopback(host) {
            warn("\(host) isn't a Tailscale (100.64.0.0/10) or loopback address; direct sync is reachable from that network.")
        }
        let listener: SocketPeerListener
        do {
            listener = try SocketPeerListener(host: host, port: peerPort)
            try listener.start { await engine.handlePeerRequest($0) }
        } catch {
            throw CLIError("Can't listen for direct sync: \(error)")
        }
        say("Listening for direct sync on \(listener.boundAddress) (used when the relay is unreachable).")
        return listener
    }
}

func describePath(_ path: SyncPath) -> String {
    switch path {
    case .relay: "relay"
    case .direct(let peers): "direct (relay unreachable; \(peers) device\(peers == 1 ? "" : "s"))"
    case .offline: "offline (no relay, no device reachable)"
    }
}

/// The newest copy from another device, waiting for the watch loop to put it on the clipboard.
/// Only the latest matters, so a newer one replaces one that hasn't been written yet.
final class ClipboardInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?

    func put(_ text: String) {
        lock.lock()
        pending = text
        lock.unlock()
    }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let text = pending
        pending = nil
        return text
    }
}

/// Turns Ctrl+C into a flag the watch loop checks, so it can stop the engine cleanly.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    #if !os(Windows)
    private var source: (any DispatchSourceSignal)?
    #endif

    static let shared = StopSignal()

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    static func install() -> StopSignal {
        #if os(Windows)
        // Runs on a thread the console creates. Returning true keeps the process alive for a clean exit.
        _ = SetConsoleCtrlHandler({ event in
            guard event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT else { return false }
            StopSignal.shared.set()
            return true
        }, true)
        #else
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { StopSignal.shared.set() }
        source.resume()
        shared.lock.lock()
        shared.source = source
        shared.lock.unlock()
        #endif
        return shared
    }
}

/// Prints one line and flushes, so it shows up right away even when stdout is a file or pipe.
/// `fflush(nil)` flushes every stream without touching the C `stdout` global, which Swift 6
/// rejects on Linux as shared mutable state.
private func say(_ line: String) {
    print(line)
    fflush(nil)
}
