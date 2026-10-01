// swift-tools-version:6.0
import PackageDescription

// The relay server. A separate package so the root package (clients) keeps building on Windows,
// where SwiftNIO doesn't. Build and test on Linux or macOS.
let package = Package(
    name: "ClipRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipRelay", targets: ["ClipRelay"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
    ],
    dependencies: [
        .package(name: "ClipSync", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // System SQLite: libsqlite3-dev on Linux, the SDK copy on macOS.
        .systemLibrary(
            name: "RelaySQLite",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        // Storage, long-poll notifier, auth and the router builder. Everything testable lives here.
        .target(name: "RelayCore", dependencies: [
            "RelaySQLite",
            .product(name: "ClipWire", package: "ClipSync"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "ClipRelay", dependencies: [
            "RelayCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "RelayTests", dependencies: [
            "RelayCore",
            .product(name: "ClipWire", package: "ClipSync"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ]),
    ]
)
