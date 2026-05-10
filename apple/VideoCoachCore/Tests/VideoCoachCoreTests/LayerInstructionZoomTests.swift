import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// Reproduces ClipPreviewBuilder's layer-instruction approach for replaying
/// recorded zoom on the source track during preview, then renders through
/// `AVAssetExportSession` (same built-in compositor AVPlayer uses on the
/// playback path) and samples pixels to verify the zoom transform actually
/// took effect on output frames.
///
/// Failure of `test_zoom_keyframes_apply_to_source_layer_at_runtime` reproduces
/// the user-reported bug where playback shows the source un-zoomed even
/// though `clip.events` contains the recorded `.zoom` keyframes — i.e. the
/// configured ramps/transforms aren't being honored by the built-in
/// compositor for our setup.
final class LayerInstructionZoomTests: XCTestCase {

    /// Build a composition + videoComposition that mirrors the relevant bits
    /// of `ClipPreviewBuilder.buildPreviewItem`, then export. Source is a
    /// horizontally split BLUE-left / RED-right pattern so a horizontal pan +
    /// scale will visibly flip a sampled left-quartile pixel from BLUE → RED.
    func test_zoom_keyframes_apply_to_source_layer_at_runtime() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("zoom-src-\(UUID()).mov")
        let camURL = tmp.appendingPathComponent("zoom-cam-\(UUID()).mov")
        let outURL = tmp.appendingPathComponent("zoom-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: camURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        let clipDurationSeconds: Double = 4.0
        try SplitColorAsset.write(
            to: srcURL,
            duration: clipDurationSeconds,
            width: 1280, height: 720,
            leftColor: (r: 0x00, g: 0x00, b: 0xFF),    // BLUE on the left half
            rightColor: (r: 0xFF, g: 0x00, b: 0x00)    // RED on the right half
        )
        try SyntheticAsset.write(
            to: camURL,
            duration: clipDurationSeconds,
            hasAudio: false,
            width: 320, height: 240,
            videoColor: (r: 0x00, g: 0xFF, b: 0x00)    // GREEN webcam
        )

        // ---- mirror ClipPreviewBuilder composition setup -----------------
        let comp = AVMutableComposition()
        let srcAsset = AVURLAsset(url: srcURL)
        let camAsset = AVURLAsset(url: camURL)
        let srcDur = try await srcAsset.load(.duration)
        let srcTrack = try await srcAsset.primaryVideoTrack()
        let camTrack = try await camAsset.primaryVideoTrack()

        let sourceVideoComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let webcamVideoComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1000)!
        try sourceVideoComp.insertTimeRange(
            CMTimeRange(start: .zero, duration: srcDur), of: srcTrack, at: .zero
        )
        try webcamVideoComp.insertTimeRange(
            CMTimeRange(start: .zero, duration: srcDur), of: camTrack, at: .zero
        )

        let srcNatural = try await srcTrack.load(.naturalSize)
        let renderSize = CGSize(width: abs(srcNatural.width), height: abs(srcNatural.height))

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        let baseStretch = CGAffineTransform(
            scaleX: renderSize.width / max(srcNatural.width, 1),
            y: renderSize.height / max(srcNatural.height, 1)
        )
        func sourceTransform(zoom: Zoom) -> CGAffineTransform {
            baseStretch.concatenating(zoom.deltaTransform(viewportSize: renderSize))
        }

        // Two zoom keyframes mimicking inherit-on-record (identity at t=0)
        // followed by a discrete user zoom at t=2: scale 2× with panX=0.25,
        // which makes viewport-x=0.25 map to source-x=0.625 (in the RED half).
        let keyframes: [(time: Double, zoom: Zoom)] = [
            (0.0, .identity),
            (2.0, Zoom(scale: 2.0, panX: 0.25, panY: 0.0)),
        ]

        // Mirror ClipPreviewBuilder: stepwise per-keyframe setTransform
        // (no setTransformRamp).
        let sourceLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoComp)
        var lastTime = CMTime(value: -1, timescale: 600)
        for kf in keyframes {
            let t = CMTime(seconds: kf.time, preferredTimescale: 600)
            guard t > lastTime else { continue }
            sourceLayer.setTransform(sourceTransform(zoom: kf.zoom), at: t)
            lastTime = t
        }

        // Webcam PiP — same 22%/2.2% layout used in production. Anchored
        // bottom-right so it doesn't overlap the left-quartile sample point.
        let camNatural = try await camTrack.load(.naturalSize)
        let camW = max(abs(camNatural.width), 1)
        let camH = max(abs(camNatural.height), 1)
        let pipW = renderSize.width * 0.22
        let pipH = pipW * camH / camW
        let margin = renderSize.height * 0.022
        let webcamScale = CGAffineTransform(scaleX: pipW / camW, y: pipH / camH)
        let webcamTranslate = CGAffineTransform(
            translationX: renderSize.width - margin - pipW,
            y: renderSize.height - margin - pipH
        )
        let webcamLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: webcamVideoComp)
        webcamLayer.setTransform(webcamScale.concatenating(webcamTranslate), at: .zero)

        let inst = PreviewInstruction.make(
            sourceTrackID: sourceVideoComp.trackID,
            webcamTrackID: webcamVideoComp.trackID,
            compositionStart: .zero,
            clipDuration: srcDur,
            segments: [],
            frozenFrames: [:],
            events: []
        )
        inst.layerInstructions = [webcamLayer, sourceLayer]
        videoComp.instructions = [inst]

        // ---- export -----------------------------------------------------
        let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        exp.outputURL = outURL
        exp.outputFileType = .mp4
        exp.videoComposition = videoComp
        await exp.export()
        XCTAssertEqual(exp.status, .completed,
                       "export failed: \(String(describing: exp.error))")

        // ---- sample frames ---------------------------------------------
        let outAsset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        // Probe at viewport-(0.28–0.32, 0.48–0.52) — well clear of the PiP
        // (x ≥ 0.78). Chosen so the viewport-x sweeps across the source
        // BLUE/RED boundary (source-x = 0.5) ONLY when the zoom transform
        // is honored:
        //   - identity zoom         → src-x ≈ 0.30          → BLUE
        //   - scale=2, panX=0.25    → src-x ≈ 0.50–0.54     → RED
        // (CGAffineTransform-applied "zoom delta" places viewport-(0.30) at
        // source-(0.5+(0.30-0.5)/2) ≈ 0.40 only if pan were 0; with the
        // panX=0.25 shift it lands solidly in the RED half regardless of
        // sub-pixel rounding.)
        let probe = CGRect(x: 0.28, y: 0.48, width: 0.04, height: 0.04)

        let (cgEarly, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let early = PixelSampling.averageRGB(in: cgEarly, normalizedRect: probe)
        XCTAssertGreaterThan(early.b, 0.75,
            "at identity zoom, viewport (0.28–0.32, 0.48–0.52) should be BLUE; got \(early)")
        XCTAssertLessThan(early.r, 0.25,
            "at identity zoom, viewport should not be RED; got \(early)")

        let (cgLate, _) = try await gen.image(at: CMTime(seconds: 2.5, preferredTimescale: 600))
        let late = PixelSampling.averageRGB(in: cgLate, normalizedRect: probe)
        // DIAGNOSTIC: also sample where the WEBCAM PiP should be (bottom-right).
        // PiP ≈ x ∈ [0.78, 0.978], y ∈ [0.835, 0.978]. Sample center ~ (0.88, 0.91).
        let pipProbe = CGRect(x: 0.86, y: 0.89, width: 0.04, height: 0.04)
        let pipEarly = PixelSampling.averageRGB(in: cgEarly, normalizedRect: pipProbe)
        let pipLate  = PixelSampling.averageRGB(in: cgLate, normalizedRect: pipProbe)
        // Outside the PiP, top-left of the frame is the source's left half.
        let topLeftEarly = PixelSampling.averageRGB(in: cgEarly,
            normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.04, height: 0.04))
        let topRightEarly = PixelSampling.averageRGB(in: cgEarly,
            normalizedRect: CGRect(x: 0.71, y: 0.05, width: 0.04, height: 0.04))
        print("[DIAG] late.probe(0.21–0.25, 0.48–0.52) = \(late)")
        print("[DIAG] PiP early=\(pipEarly) late=\(pipLate) (expected ≈ GREEN)")
        print("[DIAG] early.topLeft=\(topLeftEarly) topRight=\(topRightEarly) (expected BLUE / RED)")
        XCTAssertGreaterThan(late.r, 0.75,
            "at zoom 2× panX=0.25, viewport (0.28–0.32, 0.48–0.52) should be RED " +
            "(zoom moves source's right half under the probe); got \(late) " +
            "— zoom transform was NOT applied")
        XCTAssertLessThan(late.b, 0.25,
            "at zoom 2× panX=0.25, viewport should not be BLUE; got \(late)")
    }

}
