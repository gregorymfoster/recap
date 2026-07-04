// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapAudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapAudio", targets: ["RecapAudio"]),
        .executable(name: "capture-probe", targets: ["CaptureProbe"]),
        .executable(name: "call-audio-probe", targets: ["CallAudioProbe"]),
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapAudio", dependencies: ["RecapCore"]),
        // Manual-test harness: records N seconds of mic + system audio with the
        // real MeetingRecorder and reports capture stats. Run: swift run capture-probe 5
        .executableTarget(name: "CaptureProbe", dependencies: ["RecapAudio"]),
        // Manual-test harness: runs the real ProcessAudioMonitor for N seconds and
        // prints call-audio start/stop events as they happen. No mic/system audio
        // capture and no TCC prompt — CoreAudio process metadata only.
        // Run: swift run call-audio-probe 5 [bundleID ...]
        .executableTarget(name: "CallAudioProbe", dependencies: ["RecapAudio"], path: "Sources/call-audio-probe"),
        .testTarget(name: "RecapAudioTests", dependencies: ["RecapAudio"]),
    ]
)
