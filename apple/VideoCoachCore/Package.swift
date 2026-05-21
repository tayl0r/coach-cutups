// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VideoCoachCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VideoCoachCore", targets: ["VideoCoachCore"]),
    ],
    targets: [
        .target(name: "VideoCoachCore"),
        .testTarget(name: "VideoCoachCoreTests", dependencies: ["VideoCoachCore"]),
    ],
    swiftLanguageModes: [.v5]
)
