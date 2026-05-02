import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

final class PreviewCompositorTests: XCTestCase {
    /// Synthesizes a 1280x720 GREEN source + a 320x240 RED webcam, runs them
    /// through PreviewCompositor via AVAssetExportSession, then asserts:
    ///   * a pixel near the center is GREEN (source occupies the full frame)
    ///   * a pixel inside the bottom-right PiP is RED (webcam was composited)
    /// Tolerances are generous to absorb HEVC chroma compression.
    ///
    /// **Coverage gap:** AVAssetExportSession preserves the
    /// AVMutableVideoCompositionInstruction subclass, so this test exercises
    /// the path where `inst as? PreviewInstruction` succeeds. Production
    /// preview *playback* on macOS 26 strips the subclass (per the comment
    /// in PreviewCompositor.startRequest) — that path uses default track-IDs
    /// and cannot read `frozenFrames`, so freeze segments render black during
    /// playback by design. This test does NOT cover the freeze-frame render.
    /// Smoke-verify freeze behavior manually after Phase 3.3 lands: record a
    /// clip with at least one pause, preview it, confirm the pause segment
    /// renders black (matching pre-rewrite behavior — not regressed).
    func test_compositesSourceAndWebcamPiP() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("preview-src-\(UUID()).mov")
        let camURL = tmp.appendingPathComponent("preview-cam-\(UUID()).mov")
        let outURL = tmp.appendingPathComponent("preview-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: camURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try SyntheticAsset.write(to: srcURL, duration: 1.0, hasAudio: false,
                                 width: 1280, height: 720,
                                 videoColor: (r: 0, g: 0xFF, b: 0))
        try SyntheticAsset.write(to: camURL, duration: 1.0, hasAudio: false,
                                 width: 320, height: 240,
                                 videoColor: (r: 0xFF, g: 0, b: 0))

        let comp = AVMutableComposition()
        let srcAsset = AVURLAsset(url: srcURL)
        let camAsset = AVURLAsset(url: camURL)
        let srcDur = try await srcAsset.load(.duration)
        let srcTrack = try await srcAsset.loadTracks(withMediaType: .video).first!
        let camTrack = try await camAsset.loadTracks(withMediaType: .video).first!
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let w = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1000)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: srcTrack, at: .zero)
        try w.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: camTrack, at: .zero)

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = CGSize(width: 1280, height: 720)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.customVideoCompositorClass = PreviewCompositor.self
        let inst = PreviewInstruction.make(
            sourceTrackID: 1,
            webcamTrackID: 1000,
            compositionStart: .zero,
            clipDuration: srcDur,
            segments: [PlaybackSegment(kind: .play, sourceStart: 0, outDuration: 1.0)],
            frozenFrames: [:]
        )
        videoComp.instructions = [inst]

        let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        exp.outputURL = outURL
        exp.outputFileType = .mp4
        exp.videoComposition = videoComp
        await exp.export()
        XCTAssertEqual(exp.status, .completed, "export failed: \(String(describing: exp.error))")

        // Sample at frame ~0.5s.
        let outAsset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(value: 15, timescale: 30))

        // Center 10% box should be GREEN. PixelSampling normalizedRect uses
        // the codebase's top-down y convention (y=0 → top of image, y=1 →
        // bottom — see CompilationCompositorTests for the precedent).
        let center = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        )
        XCTAssertLessThan(center.r, 0.20, "center should be green, was \(center)")
        XCTAssertGreaterThan(center.g, 0.75, "center should be green, was \(center)")
        XCTAssertLessThan(center.b, 0.20, "center should be green, was \(center)")

        // PiP center: bottom-right at 22% width, 2.2% margin. PiP aspect is
        // 320×240 (the synthetic webcam), so pipH/pipW = 0.75. Sample a 4%
        // box inside the PiP so the box stays well clear of the PiP edges
        // even with HEVC chroma blur.
        let pipFracW = 0.22
        let pipFracH = pipFracW * 240.0 / 320.0
        let marginFrac = 0.022
        let pipCenterX = 1.0 - marginFrac - pipFracW / 2
        let pipCenterY = 1.0 - marginFrac - pipFracH / 2 // y=1 is bottom
        let sampleHalf = 0.02
        let pip = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(
                x: pipCenterX - sampleHalf,
                y: pipCenterY - sampleHalf,
                width: 2 * sampleHalf,
                height: 2 * sampleHalf
            )
        )
        XCTAssertGreaterThan(pip.r, 0.75, "PiP center should be red, was \(pip)")
        XCTAssertLessThan(pip.g, 0.25, "PiP center should be red, was \(pip)")
        XCTAssertLessThan(pip.b, 0.25, "PiP center should be red, was \(pip)")
    }
}
