// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapAudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapAudio", targets: ["RecapAudio"]),
        .executable(name: "capture-probe", targets: ["CaptureProbe"]),
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapAudio", dependencies: ["RecapCore"]),
        // Manual-test harness: records N seconds of mic + system audio with the
        // real MeetingRecorder and reports capture stats. Run: swift run capture-probe 5
        .executableTarget(name: "CaptureProbe", dependencies: ["RecapAudio"]),
        .testTarget(name: "RecapAudioTests", dependencies: ["RecapAudio"]),
    ]
)
