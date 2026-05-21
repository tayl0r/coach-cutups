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
    // Swift 6 strict concurrency: AVAssetExportSession is NS_SWIFT_NONSENDABLE,
    // so capturing it in Task.detached inside CompilationExporter requires
    // nonisolated(unsafe) or a Sendable wrapper — both add complexity with no
    // runtime benefit. Pin to Swift 5 mode until AVFoundation adopts Sendable
    // or we replace the sampler pattern.
    swiftLanguageModes: [.v5]
)
