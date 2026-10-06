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
        .executable(name: "clipctl", targets: ["clipctl"]),
        .executable(name: "ConvergenceHarness", targets: ["ConvergenceHarness"]),
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
        // Test helper: writes to a ClipDatabase until killed. CrashInjectionTests launches it (PRD N12).
        .executableTarget(name: "ClipStoreCrashWriter", dependencies: ["ClipStore", "ClipCore"]),
        .target(name: "ClipSync", dependencies: ["ClipCore", "ClipCrypto", "ClipStore", "ClipWire"]),
        .executableTarget(name: "clipctl", dependencies: [
            "ClipSync", "ClipAppCore",
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
        .testTarget(name: "ClipAppCoreTests", dependencies: ["ClipAppCore", "ClipSync", "ClipStore", "ClipCrypto", "ClipCore", "ClipWire"]),
    ]
)
