// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipSync",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "ClipWire", targets: ["ClipWire"]),
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "ClipCrypto", targets: ["ClipCrypto"]),
        .library(name: "ClipStore", targets: ["ClipStore"]),
        .library(name: "ClipSync", targets: ["ClipSync"]),
        .library(name: "ClipAppCore", targets: ["ClipAppCore"]),
        .library(name: "ClipPeerSocket", targets: ["ClipPeerSocket"]),
        .executable(name: "clipctl", targets: ["clipctl"]),
        .executable(name: "ConvergenceHarness", targets: ["ConvergenceHarness"]),
        .executable(name: "ClipSyncWin", targets: ["ClipSyncWin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Below 1.8: 1.8.x checks out git symlinks, which fail on Windows without Developer Mode.
        .package(url: "https://github.com/apple/swift-argument-parser", "1.5.0"..<"1.8.0"),
    ],
    targets: [
        // Wire format shared with the relay server (Server/ package). No dependencies.
        .target(name: "ClipWire"),
        // Data model and merge rules. Pure Swift, no I/O.
        .target(name: "ClipCore"),
        .target(name: "ClipCrypto", dependencies: [
            "ClipCore", "ClipWire",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // SQLite amalgamation compiled from source so every OS gets the same version and FTS5.
        .target(
            name: "CSQLite",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
            ]
        ),
        // Crypto only for SHA-256 of blob files in BlobCache.
        .target(name: "ClipStore", dependencies: [
            "ClipCore", "CSQLite",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // Test helper: writes to a ClipDatabase (or, in blob mode, a BlobCache) until killed. CrashInjectionTests
        // and BlobCrashInjectionTests launch it (PRD N12).
        .executableTarget(name: "ClipStoreCrashWriter", dependencies: [
            "ClipStore", "ClipCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "ClipSync", dependencies: ["ClipCore", "ClipCrypto", "ClipStore", "ClipWire"]),
        // F16: BSD-socket dialer and listener behind ClipSync's PeerDialer/PeerListener (macOS, iOS, Linux, Windows).
        .target(name: "ClipPeerSocket", dependencies: ["ClipSync", "ClipWire"]),
        .testTarget(name: "ClipPeerSocketTests", dependencies: ["ClipPeerSocket", "ClipSync", "ClipWire"]),
        // Win32 pieces shared by clipctl and the tray app: the clipboard (capture with concealed-content skip, write)
        // and the DPAPI key store. All but WindowsError.swift are `#if os(Windows)`, so elsewhere it is nearly empty.
        .target(name: "ClipWindows", dependencies: ["ClipCrypto"]),
        .executableTarget(name: "clipctl", dependencies: [
            "ClipSync", "ClipAppCore", "ClipPeerSocket",
            "ClipWindows",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // Randomized convergence simulation; the executable is a thin CLI over it.
        .target(name: "ClipHarness", dependencies: ["ClipCore"]),
        .executableTarget(name: "ConvergenceHarness", dependencies: ["ClipHarness"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCryptoTests", dependencies: ["ClipCrypto"]),
        .testTarget(name: "ClipStoreTests", dependencies: ["ClipStore"]),
        .testTarget(name: "ClipSyncTests", dependencies: ["ClipSync"]),
        .testTarget(name: "ClipHarnessTests", dependencies: ["ClipHarness", "ClipCore"]),
        // Shared app model for the Apple apps (apps/Apple). No UI frameworks, so it builds and tests on Windows.
        .target(name: "ClipAppCore", dependencies: ["ClipSync", "ClipStore", "ClipCrypto", "ClipCore"]),
        // M3 Windows tray app (apps/Windows). Win32 through the WinSDK module; on other OSes main.swift only
        // prints that it's Windows only, so `swift build` stays green everywhere.
        // /SUBSYSTEM:WINDOWS: no console window. /ENTRY:mainCRTStartup: Swift emits `main`, not `WinMain`.
        .executableTarget(
            name: "ClipSyncWin",
            dependencies: [
                "ClipAppCore", "ClipWindows", "ClipPeerSocket", "ClipSync", "ClipStore", "ClipCrypto", "ClipCore",
            ],
            path: "apps/Windows/ClipSyncWin",
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Shell32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows])),
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])),
            ]
        ),
        .testTarget(name: "ClipAppCoreTests", dependencies: ["ClipAppCore", "ClipSync", "ClipStore", "ClipCrypto", "ClipCore", "ClipWire"]),
    ]
)
