import XCTest
@testable import VideoCoachCore

final class ExportSettingsTests: XCTestCase {
    func test_bitrateForResolutionAndQuality() {
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .low), 6_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .medium), 12_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .high), 24_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r720, quality: .medium), 6_000_000)
    }

    func test_pixelSize_sourcePassesThrough() {
        XCTAssertEqual(ExportSettings.pixelSize(resolution: .r1080), .init(width: 1920, height: 1080))
        XCTAssertEqual(ExportSettings.pixelSize(resolution: .r720), .init(width: 1280, height: 720))
    }
}
