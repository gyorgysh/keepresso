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
        .executable(name: "keepresso", targets: ["keepresso-cli"]),
        .executable(name: "keepresso-helper", targets: ["keepresso-helper"]),
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
            path: "Sources/keepresso-helper",
            exclude: ["Info.plist"]
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
