// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapCore", targets: ["RecapCore"])
    ],
    targets: [
        .target(name: "RecapCore"),
        .testTarget(name: "RecapCoreTests", dependencies: ["RecapCore"]),
    ]
)
