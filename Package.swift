// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PervigilCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PervigilCore", targets: ["PervigilCore"]),
        // The caffeinate-style CLI. Built here for the dev loop; the release
        // app embeds the identically sourced `pervigil-cli` Xcode target.
        .executable(name: "pervigil", targets: ["pervigil-cli"]),
        // The privileged helper daemon (an SMAppService LaunchDaemon). Same
        // arrangement: built here for the dev loop, shipped via the
        // identically sourced `pervigil-helper` Xcode target.
        .executable(name: "pervigil-helper", targets: ["pervigil-helper"]),
        // The MCP stdio server exposing automation leases to AI agents. Same
        // arrangement again: dev loop here, embedded Xcode target in releases.
        .executable(name: "pervigil-mcp", targets: ["pervigil-mcp"])
    ],
    targets: [
        .target(
            name: "PervigilCore",
            path: "Sources/PervigilCore"
        ),
        .executableTarget(
            name: "pervigil-cli",
            dependencies: ["PervigilCore"],
            path: "Sources/pervigil-cli"
        ),
        .executableTarget(
            name: "pervigil-helper",
            dependencies: ["PervigilCore"],
            path: "Sources/pervigil-helper",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "pervigil-mcp",
            dependencies: ["PervigilCore"],
            path: "Sources/pervigil-mcp"
        ),
        .testTarget(
            name: "PervigilCoreTests",
            dependencies: ["PervigilCore"],
            path: "Tests/PervigilCoreTests"
        )
    ]
)
