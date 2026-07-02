// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapEnhancement",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapEnhancement", targets: ["RecapEnhancement"])
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapEnhancement", dependencies: ["RecapCore"]),
        .testTarget(name: "RecapEnhancementTests", dependencies: ["RecapEnhancement"]),
    ]
)
