// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeepressoCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KeepressoCore", targets: ["KeepressoCore"])
    ],
    targets: [
        .target(
            name: "KeepressoCore",
            path: "Sources/KeepressoCore"
        ),
        .testTarget(
            name: "KeepressoCoreTests",
            dependencies: ["KeepressoCore"],
            path: "Tests/KeepressoCoreTests"
        )
    ]
)
