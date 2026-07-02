// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapUI", targets: ["RecapUI"])
    ],
    dependencies: [
        .package(path: "../RecapCore"),
        .package(path: "../RecapAudio"),
        .package(path: "../RecapTranscription"),
        .package(path: "../RecapEnhancement"),
    ],
    targets: [
        .target(
            name: "RecapUI",
            dependencies: ["RecapCore", "RecapAudio", "RecapTranscription", "RecapEnhancement"]
        ),
        .testTarget(name: "RecapUITests", dependencies: ["RecapUI"]),
    ]
)
