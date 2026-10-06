#if DEBUG
import ClipAppCore
import ClipCrypto
import Darwin
import Foundation

/// DEBUG-only launch options for measuring N3 (iPhone launch with 10,000 items) and N4 (Mac idle CPU) without
/// touching the real vault. Pass them as launch arguments (they land in UserDefaults' argument domain):
///
///     -ClipSyncMeasureItems 10000             seed a separate vault with that many items, then use it
///     -ClipSyncMeasureHome /some/folder       where that vault lives (default: Application Support/ClipSyncMeasure)
///     -ClipSyncMeasureServer http://...       its relay (default: 127.0.0.1:9, nothing listens, so it's offline)
///     -ClipSyncMeasureOpen devices|picker     open a screen at launch, for screenshots
///
/// The vault key is a fixed throwaway and lives in memory only (never the Keychain), so this can't read or
/// change a real history. Release builds don't contain any of this.
enum MeasurementMode {
    static var itemCount: Int { UserDefaults.standard.integer(forKey: "ClipSyncMeasureItems") }
    static var isOn: Bool { itemCount > 0 }
    static var openAtLaunch: String? { UserDefaults.standard.string(forKey: "ClipSyncMeasureOpen") }

    struct Setup {
        let home: URL
        let keyStore: any KeyStore
    }

    /// Seeds the measurement vault (first launch only) and returns where it is. nil when measurement is off.
    static func prepare(deviceName: String) -> Setup? {
        guard isOn else { return nil }
        let defaults = UserDefaults.standard
        let home = defaults.string(forKey: "ClipSyncMeasureHome").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appendingPathComponent("ClipSyncMeasure", isDirectory: true)
        let server = defaults.string(forKey: "ClipSyncMeasureServer").flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:9")!
        // A fixed throwaway key: this vault holds generated text only.
        let key = try! VaultKey(rawBytes: Data(repeating: 0x5A, count: 32))
        let keyStore = InMemoryKeyStore(key: key, deviceKey: try! DeviceKey(rawBytes: Data(repeating: 0x21, count: 32)))
        let start = Date()
        do {
            let count = try ClipApp.seedForMeasurement(
                home: home, key: key, keyStore: keyStore, count: itemCount, serverURL: server, deviceName: deviceName)
            let sinceLaunch = processStart().map { " \(milliseconds(since: $0)) ms after process start" } ?? ""
            report("measurement vault ready: \(count) items in \(home.path) (\(milliseconds(since: start)) ms;\(sinceLaunch))")
        } catch {
            report("couldn't seed the measurement vault: \(error)")
        }
        return Setup(home: home, keyStore: keyStore)
    }

    /// Prints a step of the launch with its time since the process started (measurement runs only).
    static func mark(_ step: String) {
        guard isOn, let started = processStart() else { return }
        report("\(step) at \(milliseconds(since: started)) ms")
    }

    @MainActor private static var reportedLaunch = false

    /// Call when the history first shows items. Prints the time since the process started, once.
    @MainActor
    static func historyOnScreen(itemsShown: Int) {
        guard isOn, !reportedLaunch, let started = processStart() else { return }
        reportedLaunch = true
        // The next main-queue turn runs after SwiftUI commits this frame.
        DispatchQueue.main.async {
            report("N3 launch: process start to history on screen \(milliseconds(since: started)) ms (\(itemsShown) rows shown, \(itemCount) items)")
        }
    }

    /// When the kernel started this process, so the measurement includes dyld and runtime start-up.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private static func report(_ line: String) {
        print("ClipSync measure: \(line)")
        fflush(stdout)
    }
}
#endif
