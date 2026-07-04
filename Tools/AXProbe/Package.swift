// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AXProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ax-probe", targets: ["AXProbe"])
    ],
    targets: [
        .executableTarget(name: "AXProbe")
    ]
)
