// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoCoachCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoCoachCore", targets: ["VideoCoachCore"]),
    ],
    targets: [
        .target(name: "VideoCoachCore"),
        .testTarget(name: "VideoCoachCoreTests", dependencies: ["VideoCoachCore"]),
    ]
)
