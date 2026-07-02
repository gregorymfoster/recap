// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapTranscription",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapTranscription", targets: ["RecapTranscription"]),
        .executable(name: "transcribe-probe", targets: ["TranscribeProbe"]),
    ],
    dependencies: [
        .package(path: "../RecapCore"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "RecapTranscription", dependencies: ["RecapCore", "WhisperKit"]),
        // Manual-test harness: download a model and transcribe a file.
        // Run: swift run transcribe-probe <audio-file> [variant]
        .executableTarget(name: "TranscribeProbe", dependencies: ["RecapTranscription"]),
        .testTarget(name: "RecapTranscriptionTests", dependencies: ["RecapTranscription"]),
    ]
)
