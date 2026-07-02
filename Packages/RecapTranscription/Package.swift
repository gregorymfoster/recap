// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapTranscription",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapTranscription", targets: ["RecapTranscription"]),
        .executable(name: "transcribe-probe", targets: ["TranscribeProbe"]),
        .executable(name: "diarize-probe", targets: ["DiarizeProbe"]),
    ],
    dependencies: [
        .package(path: "../RecapCore"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        .target(name: "RecapTranscription", dependencies: ["RecapCore", "WhisperKit", "FluidAudio"]),
        // Manual-test harness: download a model and transcribe a file.
        // Run: swift run transcribe-probe <audio-file> [variant]
        .executableTarget(name: "TranscribeProbe", dependencies: ["RecapTranscription"]),
        // Manual-test harness: diarize a file and print speaker turns.
        // Run: swift run diarize-probe <audio-file>
        .executableTarget(name: "DiarizeProbe", dependencies: ["RecapTranscription"]),
        .testTarget(name: "RecapTranscriptionTests", dependencies: ["RecapTranscription"]),
    ]
)
