// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecapCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecapCore", targets: ["RecapCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "RecapCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "RecapCoreTests", dependencies: ["RecapCore"]),
    ]
)
