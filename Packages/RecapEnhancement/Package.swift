// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapEnhancement",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapEnhancement", targets: ["RecapEnhancement"]),
        .executable(name: "enhance-probe", targets: ["EnhanceProbe"]),
        .executable(name: "enhance-eval", targets: ["EnhanceEval"]),
    ],
    dependencies: [
        .package(path: "../RecapCore")
    ],
    targets: [
        .target(name: "RecapEnhancement", dependencies: ["RecapCore"]),
        // Manual-test harness: enhance sample notes against a transcript JSON.
        // Run: swift run enhance-probe <transcript.json> [notes.md]
        .executableTarget(name: "EnhanceProbe", dependencies: ["RecapEnhancement"]),
        // Quality scorecard over Fixtures/enhance so prompt changes are measurable.
        // Run: swift run enhance-eval [--runs N] [--show] [fixtures-dir]
        .executableTarget(name: "EnhanceEval", dependencies: ["RecapEnhancement"]),
        .testTarget(name: "RecapEnhancementTests", dependencies: ["RecapEnhancement"]),
    ]
)
