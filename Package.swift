// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeepressoCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KeepressoCore", targets: ["KeepressoCore"]),
        // The caffeinate-style CLI. Built here for the dev loop; the release
        // app embeds the identically sourced `keepresso-cli` Xcode target.
        .executable(name: "keepresso", targets: ["keepresso-cli"])
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
        .testTarget(
            name: "KeepressoCoreTests",
            dependencies: ["KeepressoCore"],
            path: "Tests/KeepressoCoreTests"
        )
    ]
)
