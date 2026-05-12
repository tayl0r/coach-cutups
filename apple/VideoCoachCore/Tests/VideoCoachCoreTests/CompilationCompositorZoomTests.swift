import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import VideoCoachCore

/// Phase 5 Task 5.2 — pixel-content tests for zoom integration into the
/// export compositor (`CompilationCompositor`).
///
/// 1. Identity-zoom regression test (v2 finding 6): zoom == .identity must be
///    bit-for-bit-comparable to "no zoom events at all". This guards against
///    silent stretch-vs-letterbox regressions when wiring zoom into the
///    base-frame draw.
///
/// 2. Zoom 2× centered: at scale=2 panX=0 panY=0 the visible viewport is the
///    center 100×100 of a 200×200 source. A red corner that fell into the
///    output top-left at identity is no longer visible there — output top-left
///    now samples a pixel from the source's center crop.
///
/// Both tests run end-to-end through `AVAssetExportSession` (HEVC), matching
/// the `CompilationCompositorTests` smoke pattern. HEVC chroma compression is
/// the dominant pixel-tolerance source.
final class CompilationCompositorZoomTests: XCTestCase {
    // MARK: - Identity-zoom bit-identical regression

    func test_identity_zoom_produces_same_output_as_no_zoom() async throws {
        // Render two compositions of the same green source asset:
        //   * one with `events: []`
        //   * one with `events: [.zoom(.identity)]` at recordTime 0
        // Sample matching regions of both outputs and assert they agree to
        // within HEVC tolerance. At identity, the explicit `if zoom ==
        // .identity` branch in startRequest takes the SAME draw path as the
        // no-events composition — so the only differences should be encoder
        // jitter, well below any meaningful threshold.
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("zoom-identity-src-\(UUID()).mov")
        let outNoZoomURL = tmp.appendingPathComponent("zoom-identity-noz-\(UUID()).mp4")
        let outIdentityURL = tmp.appendingPathComponent("zoom-identity-id-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: outNoZoomURL)
            try? FileManager.default.removeItem(at: outIdentityURL)
        }

        // Solid green 320x240 source — keeps export quick. Color choice is
        // irrelevant; we're comparing output to itself across two paths.
        try SyntheticAsset.write(
            to: srcURL,
            duration: 1.0,
            hasAudio: false,
            width: 320,
            height: 240,
            videoColor: (r: 0, g: 0xFF, b: 0)
        )

        let outNoZoom = try await renderCompilation(
            sourceURL: srcURL,
            renderSize: CGSize(width: 320, height: 240),
            events: [],
            outURL: outNoZoomURL
        )
        let outIdentity = try await renderCompilation(
            sourceURL: srcURL,
            renderSize: CGSize(width: 320, height: 240),
            events: [CommentaryEvent(recordTime: 0, kind: .zoom(.identity))],
            outURL: outIdentityURL
        )

        // Sample the same five regions of each output (avoiding the bottom 8%
        // text bar overlay) and assert pairwise channel agreement within
        // HEVC encoder jitter (~5/255 channel ≈ 0.02 in normalized space).
        // The two outputs both went through the explicit
        // `cg.draw(img, in: ...)` line — they should agree very tightly.
        let regions: [(name: String, rect: CGRect)] = [
            ("center", CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)),
            ("top-left", CGRect(x: 0.05, y: 0.05, width: 0.10, height: 0.10)),
            ("top-right", CGRect(x: 0.85, y: 0.05, width: 0.10, height: 0.10)),
            ("bottom-left", CGRect(x: 0.05, y: 0.55, width: 0.10, height: 0.10)),
            ("bottom-right", CGRect(x: 0.85, y: 0.55, width: 0.10, height: 0.10)),
        ]
        for (name, rect) in regions {
            let a = PixelSampling.averageRGB(in: outNoZoom, normalizedRect: rect)
            let b = PixelSampling.averageRGB(in: outIdentity, normalizedRect: rect)
            XCTAssertEqual(a.r, b.r, accuracy: 0.03, "[identity] \(name) R drifted: \(a) vs \(b)")
            XCTAssertEqual(a.g, b.g, accuracy: 0.03, "[identity] \(name) G drifted: \(a) vs \(b)")
            XCTAssertEqual(a.b, b.b, accuracy: 0.03, "[identity] \(name) B drifted: \(a) vs \(b)")
        }
    }

    // MARK: - Zoom 2× centered

    func test_zoom_2x_centered_shows_only_center_quadrant_of_source() async throws {
        // Build a 200×200 source: red top-left 50×50 corner + blue everywhere
        // else. (The plan's verbatim setup said "red top-left 100×100
        // quadrant" but at scale=2 the visible center 100×100 of source still
        // overlaps red at source(50..100, 50..100), so the red would still
        // show in the output corner. Shrinking the red corner to 50×50 makes
        // the center-crop strictly all-blue, matching the test's intent.)
        //
        // At zoom scale=2 panX=0 panY=0 the output's visible region is the
        // center 100×100 of source. Output top-left → source(50, 50) → blue.
        // Without the zoom wiring, output top-left would be RED — the test
        // fails on the unmodified compositor.
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("zoom-2x-src-\(UUID()).mov")
        let outURL = tmp.appendingPathComponent("zoom-2x-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try writeRedCornerOnBlueAsset(to: srcURL, width: 200, height: 200, redCornerSize: 50)

        let cg = try await renderCompilation(
            sourceURL: srcURL,
            renderSize: CGSize(width: 200, height: 200),
            events: [CommentaryEvent(recordTime: 0, kind: .zoom(Zoom(scale: 2, panX: 0, panY: 0)))],
            outURL: outURL
        )

        // Sample a small box near the output's top-left corner — well clear
        // of the bottom 8% text bar overlay. At identity this region would be
        // RED (source's top-left red corner stretched across output). At
        // zoom=2 it samples a pixel inside the source's center crop — blue.
        let topLeft = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.10, height: 0.10)
        )
        print("[zoom 2x] top-left (expect BLUE): \(topLeft)")
        XCTAssertGreaterThan(topLeft.b, 0.50, "top-left not BLUE at zoom=2 — zoom not wired into compositor")
        XCTAssertLessThan(topLeft.r, 0.30, "top-left has too much RED at zoom=2 — red corner still visible")

        // Sanity: output center should also be blue. At zoom=2 the output's
        // center samples source's center (100, 100), which is blue.
        let center = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        )
        print("[zoom 2x] center (expect BLUE): \(center)")
        XCTAssertGreaterThan(center.b, 0.50, "center not BLUE at zoom=2")
    }

    // MARK: - Zoom with pan: Y direction

    func test_zoom_2x_with_pan_to_top_left_shows_red_corner_in_output_top_left() async throws {
        // Regression test for the GPU-render-rewrite (`23e358f`) Y-inversion
        // bug: `zoom.deltaTransform(viewportSize:)` is authored for TOP-LEFT
        // coordinate space (matching how `ClipPreviewBuilder`'s
        // `AVMutableVideoCompositionLayerInstruction.setTransform` consumes
        // it), but the rewritten `CompilationCompositor` applied it to a
        // `CIImage` in BOTTOM-LEFT space → the panY direction was inverted in
        // the export. Panning toward the source's TOP-LEFT corner showed the
        // BOTTOM-LEFT of the source in the exported viewport instead.
        //
        // Setup: 200×200 source with a 50×50 red corner at TOP-LEFT, blue
        // elsewhere. Zoom: scale=2, panX=-0.25, panY=-0.25 → viewport center
        // samples normalized source(0.25, 0.25) → pixel(50, 50). Visible
        // viewport spans source(0..0.5, 0..0.5) — the top-left quadrant,
        // including the red corner.
        //
        // Correct behavior: output top-left samples source(0, 0) → RED.
        // Bug behavior:     output top-left samples source(0, 100) → BLUE
        //                   (lower half of source, because the Y pan was
        //                   inverted by the bottom-left coordinate space).
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("zoom-pan-tl-src-\(UUID()).mov")
        let outURL = tmp.appendingPathComponent("zoom-pan-tl-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try writeRedCornerOnBlueAsset(to: srcURL, width: 200, height: 200, redCornerSize: 50)

        let cg = try await renderCompilation(
            sourceURL: srcURL,
            renderSize: CGSize(width: 200, height: 200),
            events: [CommentaryEvent(
                recordTime: 0,
                kind: .zoom(Zoom(scale: 2, panX: -0.25, panY: -0.25))
            )],
            outURL: outURL
        )

        // Output top-left should sample the source's red corner.
        let topLeft = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.10, height: 0.10)
        )
        print("[zoom pan top-left] output top-left (expect RED): \(topLeft)")
        XCTAssertGreaterThan(topLeft.r, 0.50, "output top-left not RED at panY=-0.25 — Y pan direction is inverted in the CIImage-applied zoom transform")
        XCTAssertLessThan(topLeft.b, 0.30, "output top-left has too much BLUE at panY=-0.25 — red corner not visible where it should be")

        // Output bottom (well above the 8% text bar zone) should be blue —
        // beyond the red corner's reach in source Y.
        let lower = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.05, y: 0.75, width: 0.10, height: 0.10)
        )
        print("[zoom pan top-left] output lower-left (expect BLUE): \(lower)")
        XCTAssertGreaterThan(lower.b, 0.50, "output lower-left not BLUE — red corner extends past where it should")
    }

    // MARK: - Test infrastructure

    /// Run one compilation export and return the decoded mid-clip frame as a
    /// `CGImage` ready for `PixelSampling.averageRGB`. Single-clip composition
    /// covering the full source duration; no strokes, empty text bar (so the
    /// bottom-bar fill is dark grey but doesn't render text glyphs).
    private func renderCompilation(
        sourceURL: URL,
        renderSize: CGSize,
        events: [CommentaryEvent],
        outURL: URL
    ) async throws -> CGImage {
        let asset = AVURLAsset(url: sourceURL)
        let dur = try await asset.load(.duration)
        let track = try await asset.loadTracks(withMediaType: .video).first!

        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else {
            throw NSError(domain: "Test", code: 1)
        }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: .zero)
        // Webcam track: re-use source so the composition has the second
        // declared track (matches how production wires per-clip webcam).
        guard let webcam = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1000) else {
            throw NSError(domain: "Test", code: 2)
        }
        try webcam.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: .zero)

        let inst = CompilationInstruction.make(
            clipIndex: 0,
            indexInOutput: 0,
            totalClips: 1,
            compositionStart: .zero,
            clipDuration: dur,
            sourceTrackID: 1,
            webcamTrackID: 1000,
            segments: [PlaybackSegment(kind: .play, sourceStart: 0, outDuration: dur.seconds)],
            strokes: [],
            events: events,
            textBarLine: ""
        )

        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = CompilationCompositor.self
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions = [inst]

        guard let export = AVAssetExportSession(
            asset: comp,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw NSError(domain: "Test", code: 3)
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComp
        await export.export()
        XCTAssertEqual(
            export.status, .completed,
            "export failed: \(export.error?.localizedDescription ?? "unknown")"
        )

        let outAsset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        return cg
    }

    /// Write a 1-second BGRA video at 30fps consisting of a red top-left
    /// `redCornerSize × redCornerSize` corner on a blue background.
    /// Channel order in the BGRA pixel buffer: B, G, R, A.
    private func writeRedCornerOnBlueAsset(
        to url: URL,
        width: Int,
        height: Int,
        redCornerSize: Int
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "Test", code: 10, userInfo: [NSLocalizedDescriptionKey: "cannot add input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw NSError(domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let duration = 1.0
        let frameCount = Int((duration * Double(fps)).rounded())
        let timescale: CMTimeScale = 600
        let frameDuration = CMTime(value: CMTimeValue(timescale / CMTimeScale(fps)), timescale: timescale)

        let queue = DispatchQueue(label: "ZoomTests.video")
        let done = DispatchSemaphore(value: 0)
        var nextFrame = 0
        var finished = false
        var capturedError: Swift.Error?
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if nextFrame >= frameCount {
                    if !finished {
                        finished = true
                        input.markAsFinished()
                        done.signal()
                    }
                    return
                }
                do {
                    let pts = CMTimeMultiply(frameDuration, multiplier: Int32(nextFrame))
                    let buffer = try Self.makeRedCornerBuffer(
                        pool: adaptor.pixelBufferPool,
                        width: width,
                        height: height,
                        redCornerSize: redCornerSize
                    )
                    if !adaptor.append(buffer, withPresentationTime: pts) {
                        throw NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "append failed"])
                    }
                    nextFrame += 1
                } catch {
                    capturedError = error
                    if !finished {
                        finished = true
                        input.markAsFinished()
                        done.signal()
                    }
                    return
                }
            }
        }
        done.wait()
        if let capturedError { throw capturedError }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "Test", code: 13, userInfo: [NSLocalizedDescriptionKey: "finishWriting failed"])
        }
    }

    private static func makeRedCornerBuffer(
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int,
        redCornerSize: Int
    ) throws -> CVPixelBuffer {
        var maybe: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA,
                nil,
                &maybe
            )
        }
        guard status == kCVReturnSuccess, let buffer = maybe else {
            throw NSError(domain: "Test", code: 20, userInfo: [NSLocalizedDescriptionKey: "buffer alloc \(status)"])
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "Test", code: 21)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let w = CVPixelBufferGetWidth(buffer)
        // BGRA channel order in memory: B, G, R, A.
        // red  = (B=0,   G=0, R=255, A=255)
        // blue = (B=255, G=0, R=0,   A=255)
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                let isRed = x < redCornerSize && y < redCornerSize
                if isRed {
                    row[i]     = 0    // B
                    row[i + 1] = 0    // G
                    row[i + 2] = 0xFF // R
                    row[i + 3] = 0xFF // A
                } else {
                    row[i]     = 0xFF // B
                    row[i + 1] = 0    // G
                    row[i + 2] = 0    // R
                    row[i + 3] = 0xFF // A
                }
            }
        }
        return buffer
    }
}
