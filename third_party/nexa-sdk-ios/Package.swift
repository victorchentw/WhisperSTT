// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NexaSdkLocal",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NexaSdk", targets: ["NexaSdk"]),
    ],
    targets: [
        .binaryTarget(name: "NexaSdk", path: "NexaSdk.xcframework"),
    ]
)
