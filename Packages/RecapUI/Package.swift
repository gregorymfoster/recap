// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapUI", targets: ["RecapUI"])
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapUI", dependencies: ["RecapCore"]),
        .testTarget(name: "RecapUITests", dependencies: ["RecapUI"]),
    ]
)
