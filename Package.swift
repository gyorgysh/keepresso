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
        // The privileged helper daemon (an SMAppService LaunchDaemon). Same
        // arrangement: built here for the dev loop, shipped via the
        // identically sourced `keepresso-helper` Xcode target.
        .executable(name: "keepresso-helper", targets: ["keepresso-helper"]),
        // The MCP stdio server exposing automation leases to AI agents. Same
        // arrangement again: dev loop here, embedded Xcode target in releases.
        .executable(name: "keepresso-mcp", targets: ["keepresso-mcp"])
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
            name: "keepresso-helper",
            dependencies: ["KeepressoCore"],
            path: "Sources/keepresso-helper"
        ),
        .executableTarget(
            name: "keepresso-mcp",
            dependencies: ["KeepressoCore"],
            path: "Sources/keepresso-mcp"
        ),
        .testTarget(
            name: "KeepressoCoreTests",
            dependencies: ["KeepressoCore"],
            path: "Tests/KeepressoCoreTests"
        )
    ]
)
