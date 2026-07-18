// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeepressoCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KeepressoCore", targets: ["KeepressoCore"]),
        // The caffeinate-style CLI. Built here for the dev loop; the release
        // app embeds the identically sourced `keepresso-cli` Xcode target.
        .executable(name: "keepresso", targets: ["keepresso-cli"]),
        // A protocol-only stdio server exposing wake leases to AI agents.
        .executable(name: "keepresso-mcp", targets: ["keepresso-mcp"]),
        // The privileged helper daemon (an SMAppService LaunchDaemon). Same
        // arrangement: built here for the dev loop, shipped via the
        // identically sourced `keepresso-helper` Xcode target.
        .executable(name: "keepresso-helper", targets: ["keepresso-helper"])
    ],
    targets: [
        .target(
            name: "KeepressoCore",
            path: "Sources/KeepressoCore"
        ),
        .executableTarget(
            name: "keepresso-cli",
            dependencies: ["KeepressoCore"],
            path: "Sources/keepresso-cli"
        ),
        .executableTarget(
            name: "keepresso-mcp",
            dependencies: ["KeepressoCore"],
            path: "Sources/keepresso-mcp"
        ),
        .executableTarget(
            name: "keepresso-helper",
            dependencies: ["KeepressoCore"],
            path: "Sources/keepresso-helper",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "KeepressoCoreTests",
            dependencies: ["KeepressoCore"],
            path: "Tests/KeepressoCoreTests"
        )
    ]
)
