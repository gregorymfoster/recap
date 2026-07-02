// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapAudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapAudio", targets: ["RecapAudio"])
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapAudio", dependencies: ["RecapCore"]),
        .testTarget(name: "RecapAudioTests", dependencies: ["RecapAudio"]),
    ]
)
