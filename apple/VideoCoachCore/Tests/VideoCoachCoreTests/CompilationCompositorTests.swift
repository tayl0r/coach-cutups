import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// Phase 9.3 smoke test. Exercises the production `CompilationCompositor`
/// end-to-end through `AVAssetExportSession` (HEVC) and verifies three
/// pixel regions in the exported video:
///
/// 1. Top strip at second-stroke x → mostly RED. Asserts strokes draw at the
///    TOP of the frame, NOT the bottom — catches a flipY regression in the
///    compositor (the design doc's "Drawing capture" misuse warning).
/// 2. Top strip at first-stroke x → mostly GREEN. Proves the first stroke was
///    correctly cleared by the `.clearAll` event between the two strokes —
///    catches a regression in the visibleStrokes algorithm's `.clearAll`
///    handling.
/// 3. Bottom strip middle → darkened green (text bar overlay). Proves the
///    text bar fill is rendered at the bottom.
///
/// HEVC tolerance ~10/255 per channel (thin strokes against solid green
/// compress into a pinkish smear), so the assertions are deliberately
/// generous. The independent direction of the three checks (red vs green at
/// top, dark vs bright at bottom) is what protects against false-positive
/// passes from over-tolerant thresholds.
final class CompilationCompositorTests: XCTestCase {
    func test_compositor_drawsStrokesAtTopAndHonorsClearAll() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let sourceURL = tmp.appendingPathComponent("compositor-source-\(UUID()).mov")
        let outputURL = tmp.appendingPathComponent("compositor-output-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // 1. Synthetic source: 1s of solid green @ 1280x720. Render size
        //    matches so the compositor draws into the same dimensions.
        try SyntheticAsset.write(
            to: sourceURL,
            duration: 1.0,
            hasAudio: false,
            width: 1280,
            height: 720,
            videoColor: (r: 0, g: 0xFF, b: 0)
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first!

        // 2. Composition with one source video track at trackID 1.
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else {
            XCTFail("could not add source video track")
            return
        }
        try v.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceDuration),
            of: sourceVideo,
            at: .zero
        )

        // 3. Two short horizontal strokes near the TOP (y = 0.1) at distinct
        //    x's, plus a .clearAll between them. The first stroke is
        //    therefore cleared at recordTime=0.5 and only the second stroke
        //    remains visible at the sample time (0.85s). Each stroke is
        //    drawn as a ~6%-wide horizontal line spanning the sample region
        //    so its red survives HEVC's chroma compression of thin strokes
        //    against solid green.
        //
        //    Stroke timing semantics: event.recordTime is END of stroke;
        //    per-point t is relative to mouseDown. Both points share t=0
        //    so the whole stroke is visible the moment its event fires.
        let firstX = 0.30
        let secondX = 0.65
        let strokeY = 0.10
        let halfSpan = 0.03
        let lineWidth = 0.04 // 4% of frame height — exaggerated for HEVC survival.

        func horizontalStroke(centerX: Double) -> Stroke {
            Stroke(
                color: RGBA(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
                lineWidth: lineWidth,
                points: [
                    StrokePoint(x: centerX - halfSpan, y: strokeY, t: 0),
                    StrokePoint(x: centerX,             y: strokeY, t: 0),
                    StrokePoint(x: centerX + halfSpan, y: strokeY, t: 0),
                ],
                autoClearAfterSeconds: nil
            )
        }
        let firstStroke = horizontalStroke(centerX: firstX)
        let secondStroke = horizontalStroke(centerX: secondX)

        let events: [CommentaryEvent] = [
            CommentaryEvent(recordTime: 0.2, kind: .stroke(firstStroke)),
            CommentaryEvent(recordTime: 0.5, kind: .clearAll),
            CommentaryEvent(recordTime: 0.7, kind: .stroke(secondStroke)),
        ]

        // Add a placeholder webcam track populated with the same source
        // (production wires per-clip webcam recordings here). The compositor
        // draws the PiP if it gets a frame; we only care here that the
        // composition is structurally valid for the requiredSourceTrackIDs
        // assertion path. The PiP overdraws a 22%-wide patch in the bottom-
        // right corner, well clear of our three sample regions.
        guard let webcamTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1000) else {
            XCTFail("could not add webcam track")
            return
        }
        try webcamTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceDuration),
            of: sourceVideo,
            at: .zero
        )

        // 4. Build one CompilationInstruction covering the full clip range.
        let inst = CompilationInstruction.make(
            clipIndex: 0,
            indexInOutput: 0,
            totalClips: 1,
            compositionStart: .zero,
            clipDuration: sourceDuration,
            sourceTrackID: 1,
            webcamTrackID: 1000,
            segments: [PlaybackSegment(kind: .play, sourceStart: 0, outDuration: 1.0)],
            strokes: [firstStroke, secondStroke],
            events: events,
            textBarLine: "1/1, smoke, smoke-tag"
        )

        // 5. Wrap in AVMutableVideoComposition with our compositor.
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = CompilationCompositor.self
        videoComp.renderSize = CGSize(width: 1280, height: 720)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions = [inst]

        // 6. Export via AVAssetExportSession with HEVC preset (matches the
        //    Phase 9.0 spike pattern).
        guard let export = AVAssetExportSession(
            asset: comp,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            XCTFail("could not create export session")
            return
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.videoComposition = videoComp
        await export.export()
        XCTAssertEqual(
            export.status, .completed,
            "export failed: \(export.error?.localizedDescription ?? "unknown")"
        )

        // 7. Sample the output well after the second stroke is drawn but
        //    before the clip ends.
        let outAsset = AVURLAsset(url: outputURL)
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (cgImage, _) = try await gen.image(at: CMTime(seconds: 0.85, preferredTimescale: 600))

        // Region 1: top strip at SECOND stroke x — expect mostly RED. The
        // sample box is sized to lie inside the stroke's drawn footprint
        // (centered on the stroke's x, narrower than the stroke's width;
        // vertical span matches the lineWidth). Sampling a wider region
        // would dilute red with surrounding green and force a tolerance
        // that no longer distinguishes "stroke drew" from "stroke didn't".
        let topRegionAtSecond = PixelSampling.averageRGB(
            in: cgImage,
            normalizedRect: CGRect(
                x: secondX - halfSpan + 0.005,
                y: strokeY - lineWidth / 2 + 0.005,
                width: 2 * halfSpan - 0.01,
                height: lineWidth - 0.01
            )
        )
        // Region 2: top strip at FIRST stroke x — expect mostly GREEN
        // (proves .clearAll wiped it). Same shape as region 1 so a fair
        // comparison.
        let topRegionAtFirst = PixelSampling.averageRGB(
            in: cgImage,
            normalizedRect: CGRect(
                x: firstX - halfSpan + 0.005,
                y: strokeY - lineWidth / 2 + 0.005,
                width: 2 * halfSpan - 0.01,
                height: lineWidth - 0.01
            )
        )
        // Region 3: bottom strip middle — expect darkened green from the
        // 60%-alpha black text bar fill.
        let bottomRegion = PixelSampling.averageRGB(
            in: cgImage,
            normalizedRect: CGRect(x: 0.40, y: 0.94, width: 0.20, height: 0.05)
        )

        // Print the sampled means so the parent agent can capture them in
        // its report (and so a failure surfaces actionable values rather
        // than just "assertion failed").
        print("[compositor smoke] top@second (expect RED): \(topRegionAtSecond)")
        print("[compositor smoke] top@first  (expect GREEN): \(topRegionAtFirst)")
        print("[compositor smoke] bottom     (expect DARK GREEN): \(bottomRegion)")

        // ─── Assertions ───
        // Tolerances: HEVC compresses thin red strokes against green into
        // pinkish tones; we deliberately stay generous on the red channel
        // (>0.4) and tight on green at first-stroke x (>0.7) since green
        // there should be untouched.

        // 1. Second stroke region: red dominant, green visibly reduced.
        XCTAssertGreaterThan(
            topRegionAtSecond.r, 0.40,
            "second stroke not RED — strokes likely drew at the BOTTOM (flipY regression)"
        )
        XCTAssertLessThan(
            topRegionAtSecond.g, topRegionAtFirst.g,
            "second stroke region greener than untouched first-stroke region — stroke not drawn"
        )

        // 2. First stroke region: should be untouched green (clearAll wiped
        //    it). If this fails, the visibleStrokes .clearAll algorithm
        //    regressed.
        XCTAssertGreaterThan(
            topRegionAtFirst.g, 0.70,
            "first stroke region not GREEN — .clearAll did not wipe the first stroke"
        )
        XCTAssertLessThan(
            topRegionAtFirst.r, 0.30,
            "first stroke region has too much RED — .clearAll did not wipe it"
        )

        // 3. Bottom region: text bar overlay darkens the green. Compare
        //    against the untouched first-stroke top region rather than a
        //    fixed threshold — relative comparison is robust to HEVC's
        //    overall green saturation drift.
        XCTAssertLessThan(
            bottomRegion.g, topRegionAtFirst.g - 0.10,
            "bottom strip not visibly darker than top — text bar fill missing"
        )
    }
}
