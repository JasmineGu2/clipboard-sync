import ClipCore
import CSQLite
import Foundation
import XCTest
@testable import ClipStore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// PRD N12: a crash at any point never corrupts the database.
///
/// Launches the ClipStoreCrashWriter helper against a real database file, kills it at a random moment
/// (SIGKILL on macOS and Linux, TerminateProcess on Windows), then reopens the file and checks it.
/// The helper prints each transaction before it starts and again once it has committed, so the test knows
/// which ops must be there and which single transaction may or may not have made it.
///
/// Fast by default. For a long run:
///   CLIPSTORE_CRASH_ITERATIONS=500 swift test --filter CrashInjectionTests
/// CLIPSTORE_CRASH_SEED picks the seed (default 1); a failure message names the seed and iteration.
///
/// Killing a process tests crashes, not power loss: the OS still flushes what SQLite handed it.
/// Power loss is what `synchronous = FULL` is for, and only a fault-injecting VFS or real hardware can test it.
final class CrashInjectionTests: XCTestCase {
    /// A fresh database file every this many kills, so the first open and the migrations get killed too
    /// and the refold check stays cheap.
    let killsPerDatabase = 8

    func testKilledWriterNeverCorruptsTheDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        let iterations = env["CLIPSTORE_CRASH_ITERATIONS"].flatMap(Int.init) ?? 16
        let seed = env["CLIPSTORE_CRASH_SEED"].flatMap(UInt64.init) ?? 1
        let writer = try writerExecutable()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipStoreCrash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var rng = SplitMix64(seed: seed)
        var model = Model()
        var path = ""
        var stats = Stats()
        let started = Date()

        for iteration in 0..<iterations {
            if iteration % killsPerDatabase == 0 {
                path = dir.appendingPathComponent("crash-\(iteration).sqlite").path
                model = Model()
            }
            let context = "seed \(seed), iteration \(iteration)"

            // Most kills land mid-write; one in eight lands during open and migration.
            let early = rng.next() % 8 == 0
            let delay = early ? Double(rng.next() % 15) / 1000 : Double(rng.next() % 80) / 1000
            let run = try runAndKill(writer, path: path, seed: rng.next(), cursor: model.cursor, early: early, delay: delay)
            stats.add(run)

            // The WAL holds the commits since the last checkpoint, so it must still be there after a kill.
            if run.ready {
                XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"), "\(context): -wal missing after kill")
            }
            // -shm is only an index into the WAL; SQLite rebuilds it if it's gone (or stale, as after any crash).
            if rng.next() % 3 == 0, FileManager.default.fileExists(atPath: path + "-shm") {
                try? FileManager.default.removeItem(atPath: path + "-shm")
                stats.shmRemoved += 1
            }

            try check(path: path, run: run, model: &model, context: context)
            if testRun?.failureCount ?? 0 > 0 { return }
        }
        print(String(
            format: "ClipStore crash test: seed %llu, %d kills (%d mid-transaction), %d transactions committed, %d -shm removed, %.1f s",
            seed, iterations, stats.midTransaction, stats.committed, stats.shmRemoved, Date().timeIntervalSince(started)
        ))
        XCTAssertGreaterThan(stats.midTransaction, 0, "no kill landed inside a transaction")
    }

    // MARK: Checks

    /// What must be in the database, from the transactions the writer reported as committed.
    struct Model {
        var ops: Set<String> = []
        var cursor: Int64 = 0
    }

    struct Stats {
        var committed = 0
        var midTransaction = 0
        var shmRemoved = 0
        mutating func add(_ run: WriterRun) {
            committed += run.committed.count
            if run.inFlight != nil { midTransaction += 1 }
        }
    }

    func check(path: String, run: WriterRun, model: inout Model, context: String) throws {
        // Opening runs WAL recovery and the migrations, through the same code the apps use.
        let db = try ClipDatabase(path: path)
        let raw = try RawSQLite(path: path)
        defer {
            raw.close()
            db.close()
        }

        XCTAssertEqual(try raw.strings("PRAGMA integrity_check"), ["ok"], context)

        // The full-text index matches its own content, and has exactly one row per visible item, under its id.
        XCTAssertNoThrow(try raw.exec("INSERT INTO items_fts(items_fts) VALUES('integrity-check')"), context)
        XCTAssertEqual(
            try raw.ints("SELECT rowid FROM items_fts ORDER BY rowid"),
            try raw.ints("SELECT id FROM items WHERE visible = 1 ORDER BY id"),
            "\(context): items_fts rows differ from visible items"
        )
        XCTAssertEqual(
            try raw.ints("SELECT count(*) FROM items_fts f JOIN items i ON i.id = f.rowid WHERE f.item_id != i.item_id"),
            [0], "\(context): items_fts row under the wrong item"
        )
        for item in try db.items(limit: 3) {
            let token = String(item.content?.text.split(separator: " ").first ?? "")
            XCTAssertTrue(try db.search(token).contains { $0.id == item.id }, "\(context): search misses \(token)")
        }

        // Every committed op is there. The one transaction in flight is all there or not there at all.
        for tx in run.committed { model.ops.formUnion(tx.ops) }
        if let remote = run.committed.last(where: { $0.kind == "remote" }) { model.cursor = remote.cursor }
        let stored = Set(try raw.strings("SELECT op_id FROM ops"))
        if let tx = run.inFlight, !tx.ops.isEmpty {
            let landed = stored.intersection(tx.ops)
            XCTAssertTrue(landed.isEmpty || landed.count == tx.ops.count,
                          "\(context): \(landed.count) of \(tx.ops.count) ops of one transaction survived")
            if landed.count == tx.ops.count {
                model.ops.formUnion(tx.ops)
                if tx.kind == "remote" { model.cursor = tx.cursor }
            }
        }
        XCTAssertEqual(model.ops.subtracting(stored).count, 0, "\(context): committed ops lost")
        XCTAssertEqual(stored.subtracting(model.ops).count, 0, "\(context): ops nobody committed")
        // The cursor moves in the same transaction as the ops it covers.
        XCTAssertEqual(try db.syncCursor(), model.cursor, "\(context): sync cursor")

        // The items table is exactly the fold of the op log.
        let ids = try raw.strings("SELECT item_id FROM items").compactMap { UUID(uuidString: $0).map(ItemID.init) }
        let before = try ids.map { try db.item($0) }
        try db.refoldAll()
        XCTAssertEqual(try ids.map { try db.item($0) }, before, "\(context): items differ from a refold of the ops")
        XCTAssertEqual(try raw.ints("SELECT count(*) FROM items"), [Int64(ids.count)], context)

        raw.close()
        db.close()
        // A clean close checkpoints the WAL back into the main file and removes it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"), "\(context): -wal left after clean close")
    }

    // MARK: Running the writer

    struct Transaction {
        var kind: String
        var cursor: Int64
        var ops: [String]
    }

    struct WriterRun {
        var ready = false
        var committed: [Transaction] = []
        /// Announced but not reported committed: it may or may not have landed.
        var inFlight: Transaction?
    }

    func runAndKill(_ writer: URL, path: String, seed: UInt64, cursor: Int64, early: Bool, delay: TimeInterval) throws -> WriterRun {
        let process = Process()
        process.executableURL = writer
        process.arguments = [path, String(seed), String(cursor)]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = PipeReader(stdout.fileHandleForReading)
        let errors = PipeReader(stderr.fileHandleForReading)
        try process.run()

        if !early {
            let deadline = Date().addingTimeInterval(30)
            while !output.text.contains("READY\n"), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        }
        Thread.sleep(forTimeInterval: delay)
        let wasRunning = process.isRunning
        crash(process)
        process.waitUntilExit()
        output.wait()
        errors.wait()
        if !wasRunning {
            XCTFail("writer exited by itself (status \(process.terminationStatus)): \(errors.text)")
        }
        return parse(output.text)
    }

    func crash(_ process: Process) {
        #if os(Windows)
        // TerminateProcess: no atexit handlers, no flushing, the same as a crash for SQLite.
        process.terminate()
        #else
        _ = kill(process.processIdentifier, SIGKILL)
        #endif
    }

    func parse(_ text: String) -> WriterRun {
        var run = WriterRun()
        // A last line without a newline was cut off mid-write, before its transaction started.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        for line in lines {
            let parts = line.split(separator: " ")
            switch parts.first {
            case "READY":
                run.ready = true
            case "P" where parts.count == 4:
                let ops = parts[3] == "-" ? [] : parts[3].split(separator: ",").map(String.init)
                run.inFlight = Transaction(kind: String(parts[1]), cursor: Int64(parts[2]) ?? 0, ops: ops)
            case "C":
                if let tx = run.inFlight { run.committed.append(tx) }
                run.inFlight = nil
            default:
                XCTFail("unexpected writer output: \(line)")
            }
        }
        return run
    }

    /// The helper binary sits next to the test bundle in the build products folder.
    func writerExecutable() throws -> URL {
        #if os(Windows)
        let name = "ClipStoreCrashWriter.exe"
        #else
        let name = "ClipStoreCrashWriter"
        #endif
        var folders: [URL] = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent() }
        folders.append(Bundle.main.bundleURL)
        folders.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for folder in folders {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw StoreError(
            code: SQLITE_NOTFOUND,
            message: "\(name) not found in \(folders.map(\.path)). Run `swift build` first (swift test builds it too)."
        )
    }
}

/// Drains a pipe on its own thread, so the writer never blocks on a full pipe and gets killed in write().
final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            done.signal()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Blocks until the pipe reaches end of file (the writer has exited).
    func wait() { done.wait() }
}
