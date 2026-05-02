import AVFoundation
import XCTest
@testable import VideoCoachCore

final class AssetTracksTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetTracksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    func test_videoPlusAudioAsset_returnsAudioTrackFromOptionalAudioTrack() async throws {
        let url = tempDir.appendingPathComponent("video-with-audio.mov")
        try SyntheticAsset.write(to: url, hasAudio: true)
        let asset = AVURLAsset(url: url)

        let audioTrack = try await asset.optionalAudioTrack()
        XCTAssertNotNil(audioTrack)
        XCTAssertEqual(audioTrack?.mediaType, .audio)
    }

    func test_videoOnlyAsset_optionalAudioTrackIsNilAndPrimaryVideoTrackResolves() async throws {
        let url = tempDir.appendingPathComponent("video-only.mov")
        try SyntheticAsset.write(to: url, hasAudio: false)
        let asset = AVURLAsset(url: url)

        let audioTrack = try await asset.optionalAudioTrack()
        XCTAssertNil(audioTrack)

        let videoTrack = try await asset.primaryVideoTrack()
        XCTAssertEqual(videoTrack.mediaType, .video)
    }

    func test_audioOnlyAsset_primaryVideoTrackThrowsNoVideoTrack() async throws {
        let url = tempDir.appendingPathComponent("audio-only.m4a")
        try SyntheticAsset.writeAudioOnly(to: url)
        let asset = AVURLAsset(url: url)

        do {
            _ = try await asset.primaryVideoTrack()
            XCTFail("expected AssetTrackError.noVideoTrack")
        } catch let AssetTrackError.noVideoTrack(reportedURL) {
            XCTAssertEqual(reportedURL, url)
        }
    }
}
