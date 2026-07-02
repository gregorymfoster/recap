// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapTranscription",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapTranscription", targets: ["RecapTranscription"])
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapTranscription", dependencies: ["RecapCore"]),
        .testTarget(name: "RecapTranscriptionTests", dependencies: ["RecapTranscription"]),
    ]
)
