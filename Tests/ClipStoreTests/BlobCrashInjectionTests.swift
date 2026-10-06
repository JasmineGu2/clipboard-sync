import ClipCore
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

/// PRD N12 for payload files: a crash at any point never leaves a corrupt blob marked complete.
///
/// Runs ClipStoreCrashWriter in blob mode against a real cache folder (downloads chunk by chunk, imports, and
/// downloads that write one bad chunk), kills it at a random moment, and checks the folder:
/// - every complete blob file (named by its bare ID) has exactly the bytes its ID implies;
/// - every blob the writer reported complete is there;
/// - the next run resumes each partial download, and a resume of good bytes is never rejected (N5): only a
///   download that wrote a bad chunk may end in "hash mismatch", and then it's removed, never published.
///
/// Fast by default (12 kills, a few seconds). For a long run:
///   CLIPSTORE_BLOB_CRASH_ITERATIONS=300 swift test --filter BlobCrashInjectionTests
/// CLIPSTORE_CRASH_SEED picks the seed (default 1).
final class BlobCrashInjectionTests: XCTestCase {
    /// A fresh cache folder every this many kills, so leftovers get resumed across several runs but the folder
    /// stays small.
    let killsPerFolder = 4

    func testKilledBlobWriterNeverPublishesACorruptFile() throws {
        let env = ProcessInfo.processInfo.environment
        let iterations = env["CLIPSTORE_BLOB_CRASH_ITERATIONS"].flatMap(Int.init) ?? 12
        let seed = env["CLIPSTORE_CRASH_SEED"].flatMap(UInt64.init) ?? 1
        let writer = try crashWriterExecutable()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlobCrash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var rng = SplitMix64(seed: seed)
        var folder = root
        var corrupt = Set<String>()
        var stats = (midBlob: 0, complete: 0, resumed: 0, rejected: 0)
        let started = Date()

        for iteration in 0..<iterations {
            if iteration % killsPerFolder == 0 {
                if iteration > 0 { try drain(writer, folder: folder, corrupt: corrupt, context: "seed \(seed), drain \(iteration)") }
                folder = root.appendingPathComponent("cache-\(iteration)")
                corrupt = []
            }
            let context = "seed \(seed), iteration \(iteration)"
            let delay = Double(rng.next() % 150 + 1) / 1000  // never 0: 0 means "wait for stopWhen"
            let run = try runAndKill(writer, folder: folder, seed: rng.next(), stopWhen: { _ in false }, delay: delay)
            corrupt.formUnion(run.corrupt)
            if run.inFlight != nil { stats.midBlob += 1 }
            stats.complete += run.completed.count
            stats.resumed += run.resumed
            stats.rejected += run.rejected.count
            check(folder: folder, run: run, corrupt: corrupt, context: context)
            if testRun?.failureCount ?? 0 > 0 { return }
        }
        try drain(writer, folder: folder, corrupt: corrupt, context: "seed \(seed), final drain")
        print(String(
            format: "Blob crash test: seed %llu, %d kills (%d mid-blob), %d blobs completed, %d resumes, %d bad downloads rejected, %.1f s",
            seed, iterations, stats.midBlob, stats.complete, stats.resumed, stats.rejected, Date().timeIntervalSince(started)
        ))
        XCTAssertGreaterThan(stats.midBlob, 0, "no kill landed while a blob was being written")
    }

    // MARK: Checks

    func check(folder: URL, run: BlobRun, corrupt: Set<String>, context: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // Every complete file holds exactly its blob's bytes: a bad chunk or a torn write never got published.
        for name in names {
            guard let uuid = UUID(uuidString: name) else { continue }
            let id = BlobID(uuid)
            XCTAssertTrue(matchesPattern(folder.appendingPathComponent(name), id),
                          "\(context): \(name) is marked complete but its bytes are wrong")
        }
        for id in run.completed {
            XCTAssertTrue(names.contains(id), "\(context): \(id) was reported complete but isn't there")
        }
        // A resumed download of good bytes must finish; only one that wrote a bad chunk may be rejected.
        for id in run.rejected where !corrupt.contains(id) {
            XCTFail("\(context): resuming \(id) was rejected although every chunk written was good")
        }
        for id in run.rejected {
            XCTAssertFalse(names.contains(id), "\(context): rejected \(id) is still there")
            XCTAssertFalse(names.contains(id + ".partial"), "\(context): rejected \(id) left its partial file")
        }
    }

    /// Runs the writer until it has resumed every partial download (its first new blob), then kills it and checks.
    func drain(_ writer: URL, folder: URL, corrupt: Set<String>, context: String) throws {
        let run = try runAndKill(writer, folder: folder, seed: 7, stopWhen: { text in
            text.split(separator: "\n").contains { $0.hasPrefix("B ") && !$0.hasSuffix(" resume") }
        }, delay: 0)
        check(folder: folder, run: run, corrupt: corrupt, context: context)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let leftovers = names.filter { $0.hasSuffix(".partial") }.filter { name in
            // The one new blob the writer had started when it was stopped may be partial.
            !(run.inFlight.map { name.hasPrefix($0) } ?? false)
        }
        XCTAssertEqual(leftovers, [], "\(context): partial downloads not resumed")
    }

    /// Compares the file with the blob's bytes, one chunk at a time.
    func matchesPattern(_ url: URL, _ id: BlobID) -> Bool {
        let (size, chunkSize) = TestBlobPattern.shape(id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var offset = 0
        while offset < size {
            let count = min(chunkSize, size - offset)
            guard let data = try? handle.read(upToCount: count),
                  data == TestBlobPattern.bytes(id, offset: offset, count: count)
            else { return false }
            offset += count
        }
        return (try? handle.read(upToCount: 1))?.isEmpty ?? true
    }

    // MARK: Running the writer

    struct BlobRun {
        var completed: [String] = []
        var rejected: [String] = []
        var corrupt: [String] = []
        var resumed = 0
        /// Started but not reported complete or rejected.
        var inFlight: String?
    }

    func runAndKill(_ writer: URL, folder: URL, seed: UInt64, stopWhen: (String) -> Bool, delay: TimeInterval) throws -> BlobRun {
        let process = Process()
        process.executableURL = writer
        process.arguments = ["blob", folder.path, String(seed)]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = PipeReader(stdout.fileHandleForReading)
        let errors = PipeReader(stderr.fileHandleForReading)
        try process.run()

        let deadline = Date().addingTimeInterval(60)
        while !output.text.contains("READY\n"), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        while !stopWhen(output.text), process.isRunning, Date() < deadline, delay == 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        Thread.sleep(forTimeInterval: delay)
        let wasRunning = process.isRunning
        #if os(Windows)
        process.terminate()
        #else
        _ = kill(process.processIdentifier, SIGKILL)
        #endif
        process.waitUntilExit()
        output.wait()
        errors.wait()
        if !wasRunning { XCTFail("blob writer exited by itself (status \(process.terminationStatus)): \(errors.text)") }
        return parse(output.text)
    }

    func parse(_ text: String) -> BlobRun {
        var run = BlobRun()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()  // cut off mid-line, or the empty string after the last newline
        for line in lines {
            let parts = line.split(separator: " ").map(String.init)
            switch parts.first {
            case "READY": break
            case "B" where parts.count == 3:
                run.inFlight = parts[1]
                if parts[2] == "corrupt" { run.corrupt.append(parts[1]) }
                if parts[2] == "resume" { run.resumed += 1 }
            case "D" where parts.count == 2:
                run.completed.append(parts[1])
                run.inFlight = nil
            case "R" where parts.count == 2:
                run.rejected.append(parts[1])
                run.inFlight = nil
            default:
                XCTFail("unexpected blob writer output: \(line)")
            }
        }
        return run
    }
}

/// The helper binary sits next to the test bundle in the build products folder (as for CrashInjectionTests).
func crashWriterExecutable() throws -> URL {
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
    throw BlobCacheError.io("\(name) not found in \(folders.map(\.path)); run `swift build` first")
}

/// The writer's `BlobPattern` (Sources/ClipStoreCrashWriter/BlobWriter.swift), without the hash. Keep in step.
enum TestBlobPattern {
    static func shape(_ id: BlobID) -> (size: Int, chunkSize: Int) {
        let seed = seed(id)
        let chunkSizes = [4 << 10, 64 << 10, 1 << 20]
        return (Int((seed >> 24) % UInt64(2 << 20)) + 1, chunkSizes[Int((seed >> 8) % 3)])
    }

    static func seed(_ id: BlobID) -> UInt64 {
        withUnsafeBytes(of: id.rawValue.uuid) { $0.load(as: UInt64.self) }
    }

    static func bytes(_ id: BlobID, offset: Int, count: Int) -> Data {
        var state = seed(id) &+ UInt64(offset / 8) &* 0x9E37_79B9_7F4A_7C15
        var data = Data(capacity: count + 8)
        while data.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            withUnsafeBytes(of: z.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.prefix(count)
    }
}
