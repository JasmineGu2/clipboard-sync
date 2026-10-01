import ArgumentParser
import ClipCore
import ClipSync
import Foundation
#if os(Windows)
import WinSDK
#endif

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep syncing and (on Windows) capture copied text. Ctrl+C to stop.",
        discussion: "Capture pauses while <home>/paused exists. Content marked concealed by password managers is never captured."
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "Delete unpinned items older than this many days, on every device. Checked hourly.")
    var expireDays: Int?
    @Option(help: .hidden) var exitAfter: Double?

    static let pollInterval: Duration = .milliseconds(250)
    static let expiryInterval: Duration = .seconds(3600)

    func validate() throws {
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

        // One line per new item, whether captured here or synced from another device.
        let alreadySeen = Set(try client.db.items(limit: 500).map(\.id))
        let reporter = Task {
            var seen = alreadySeen
            for await _ in engine.changes {
                guard let fresh = try? client.db.items(limit: 50).filter({ !seen.contains($0.id) }) else { continue }
                for item in fresh.reversed() {
                    seen.insert(item.id)
                    let verb = item.content?.sourceDevice == client.device ? "captured" : "synced  "
                    say("\(verb) \(itemLine(item))")
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
            try? await Task.sleep(for: Self.pollInterval)
            #if os(Windows)
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
        syncLoop.cancel()
        await syncLoop.value
        // Let the reporter print anything recorded just before the stop.
        try? await Task.sleep(for: .milliseconds(100))
        reporter.cancel()
        say("Stopped.")
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
