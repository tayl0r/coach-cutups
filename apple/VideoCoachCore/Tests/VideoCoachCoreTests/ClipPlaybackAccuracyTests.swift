import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// End-to-end pixel-level verification of clip playback. The source video
/// is a `FiducialAsset`: five large saturated-color fiducial squares at
/// fixed source coordinates plus a 12-bit binary frame-number barcode
/// along the bottom. Each test:
///   1. crafts a `Clip` with specific events,
///   2. builds the same composition + videoComposition that
///      `ClipPreviewBuilder.buildPreviewItem` would build,
///   3. samples a frame at a chosen compositionTime through
///      `AVAssetImageGenerator` (uses the same compositor as
///      `AVAssetExportSession`),
///   4. decodes the barcode to learn which source frame the compositor
///      actually emitted, and/or classifies a probe sample to check that
///      a particular fiducial is at the expected viewport position.
///
/// **Why fiducials beat per-pixel encoding**: the previous
/// `PositionEncodedAsset` packed (sourceTime, sourceX, sourceY) into RGB
/// gradients, so any sampled pixel "decoded" back to a (t, x, y) triple.
/// In practice H.264 BT.709 YCbCr roundtrip + chroma subsampling smeared
/// the gradients enough that absolute decodes were unreliable; we worked
/// around it with delta-based assertions. Fiducials trade pixel-density
/// for hard categorical signals — a primary-color square either decodes
/// as that color or it doesn't, with a comfortable noise margin.
final class ClipPlaybackAccuracyTests: XCTestCase {

    // MARK: - Test fixtures

    private static let sourceWidth = 1280
    private static let sourceHeight = 720
    private static let sourceFps = 30
    private static let sourceDuration: Double = 10
    /// Total source frames the FiducialAsset writes. Used by tests that
    /// reason about "the last frame of the source" — a freeze on EOF is
    /// expected to display this index.
    private static var sourceFrameCount: Int {
        Int((sourceDuration * Double(sourceFps)).rounded())
    }

    private var srcURL: URL!
    private var camURL: URL!
    private var renderedComp: AVMutableComposition?
    private var renderedVideoComp: AVMutableVideoComposition?

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
        srcURL = tmp.appendingPathComponent("fiducial-src-\(UUID()).mov")
        camURL = tmp.appendingPathComponent("fiducial-cam-\(UUID()).mov")
        try FiducialAsset.write(
            to: srcURL,
            duration: Self.sourceDuration,
            width: Self.sourceWidth, height: Self.sourceHeight,
            fps: Self.sourceFps
        )
        try SyntheticAsset.write(
            to: camURL,
            duration: Self.sourceDuration,
            hasAudio: false,
            width: 320, height: 240,
            videoColor: (r: 0x40, g: 0x40, b: 0x40)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: srcURL)
        try? FileManager.default.removeItem(at: camURL)
        renderedComp = nil
        renderedVideoComp = nil
    }

    // MARK: - Source-time tests (barcode-decoded)

    /// A clip recorded paused at sourceTime=5 holds a single frozen frame
    /// throughout its duration. The barcode at every compTime must decode
    /// to exactly the source frame at sourceTime=5, and that index must
    /// stay constant across multiple sample times.
    func test_freeze_holdsSingleSourceFrame() async throws {
        let clip = makeClip(
            startSourceSeconds: 5,
            recordingDuration: 3,
            events: [.init(recordTime: 0, kind: .pause(sourceTime: 5))]
        )
        try await renderClip(clip)

        let expectedFrame = Int((5.0 * Double(Self.sourceFps)).rounded())
        let f0 = try decodeFrame(at: 0.5)
        let f1 = try decodeFrame(at: 1.5)
        let f2 = try decodeFrame(at: 2.5)
        XCTAssertEqual(f0, expectedFrame, "freeze should display the source frame at t=5s (frame \(expectedFrame))")
        XCTAssertEqual(f1, expectedFrame)
        XCTAssertEqual(f2, expectedFrame)
    }

    /// Regression for "drawing appears 1 frame off" reports. When the user
    /// pauses mpv on a moving source, mpv's `time-pos` lands a few µs
    /// *below* the displayed frame's nominal PTS — observed values like
    /// `4.866638` for a frame whose 30fps PTS is `4.866666…`. The naive
    /// `insertTimeRange(start: srcStart, duration: 1tick)` then picks the
    /// frame whose PTS is strictly ≤ the slice start: in this case frame
    /// 145 instead of frame 146, which the user was actually looking at
    /// when they pressed space and drew on the ball.
    ///
    /// This test pins srcStart at three offsets relative to a frame's PTS:
    ///   * exactly on the boundary (proves the test infra works)
    ///   * 28µs below (matches the mpv-lag observed in production logs)
    ///   * 28µs above
    /// All three should resolve to the same source frame — the one the
    /// user was looking at, which on a 30fps source is the frame whose PTS
    /// is the largest one ≤ srcStart, OR — when srcStart is just slightly
    /// below a frame's PTS due to mpv-side rounding — the next frame the
    /// user is visually displaying. Until the freeze realizer accounts for
    /// this sub-tick lag, the slightly-below case will deliver the wrong
    /// frame.
    func test_freeze_subTickBelowFrameBoundary_deliversDisplayedFrame() async throws {
        let fps = Double(Self.sourceFps)
        let displayedFrame = 146
        let nominalPTS = Double(displayedFrame) / fps     // 4.866666…
        let mpvLag = 28e-6                                // matches production probe

        struct Case { let label: String; let srcStart: Double }
        let cases: [Case] = [
            .init(label: "exact frame boundary",       srcStart: nominalPTS),
            .init(label: "28µs above frame boundary",  srcStart: nominalPTS + mpvLag),
            .init(label: "28µs below frame boundary",  srcStart: nominalPTS - mpvLag),
        ]

        for c in cases {
            let clip = makeClip(
                startSourceSeconds: c.srcStart,
                recordingDuration: 1,
                events: [.init(recordTime: 0, kind: .pause(sourceTime: c.srcStart))]
            )
            try await renderClip(clip)
            let decoded = try decodeFrame(at: 0.5)
            XCTAssertEqual(decoded, displayedFrame,
                "freeze at srcStart=\(c.srcStart) (\(c.label)) should deliver the displayed frame \(displayedFrame); got \(decoded)")
        }
    }

    /// pause@0 → play@1 → pause@2 records exactly 1 second of source
    /// playback. The final freeze (compTime ≥ 2) must show the source
    /// frame the user paused at — sourceTime=6 — which is sourceFps
    /// frames past the initial freeze at sourceTime=5.
    func test_pauseResume_finalFreezeShowsResumedFrame() async throws {
        let clip = makeClip(
            startSourceSeconds: 5,
            recordingDuration: 3,
            events: [
                .init(recordTime: 0,   kind: .pause(sourceTime: 5)),
                .init(recordTime: 1.0, kind: .play(sourceTime: 5)),
                .init(recordTime: 2.0, kind: .pause(sourceTime: 6)),
            ]
        )
        try await renderClip(clip)

        let initial = try decodeFrame(at: 0.5)
        let final   = try decodeFrame(at: 2.5)
        let expectedDelta = Self.sourceFps   // 1 second of source advance
        XCTAssertEqual(final - initial, expectedDelta,
            "final freeze must show source-frame \(expectedDelta) ahead of initial freeze; got Δ=\(final - initial)")
    }

    /// Two clips starting at different source offsets must show source
    /// frames matching their `startSourceSeconds` even though
    /// recordingDuration is identical.
    func test_clipStartTime_offsetFreezeShowsCorrectSourceFrame() async throws {
        let clipA = makeClip(
            startSourceSeconds: 4,
            recordingDuration: 1,
            events: [.init(recordTime: 0, kind: .pause(sourceTime: 4))]
        )
        try await renderClip(clipA)
        let frameA = try decodeFrame(at: 0.5)

        let clipB = makeClip(
            startSourceSeconds: 6,
            recordingDuration: 1,
            events: [.init(recordTime: 0, kind: .pause(sourceTime: 6))]
        )
        try await renderClip(clipB)
        let frameB = try decodeFrame(at: 0.5)

        XCTAssertEqual(frameA, Int((4.0 * Double(Self.sourceFps)).rounded()))
        XCTAssertEqual(frameB, Int((6.0 * Double(Self.sourceFps)).rounded()))
    }

    /// Regression for the AVPlayer-stall bug: playing past sourceDuration
    /// produces a `.play` segment whose CMTimeRange falls past EOF, leaves
    /// a hole in the source track, and stalls the compositor (audio keeps
    /// playing, video freezes). The fix in `playbackSegments` now
    /// converts any post-EOF play tail into a `.freeze` on the last
    /// available frame. This test verifies that:
    ///   - No audio-only "hole" exists; the compositor produces frames
    ///     throughout the clip's duration (decode succeeds at end).
    ///   - The post-EOF freeze decodes to the LAST source frame, not some
    ///     out-of-bounds nonsense (gray, garbage, missing barcode).
    func test_FF_pastSourceEnd_freezesOnLastFrame() async throws {
        // Start near the end, FF past it (skip clamps cursor at
        // sourceDuration), then keep "playing" for 2 more seconds. The
        // last 2 seconds of the recording must show the last source frame.
        let clip = makeClip(
            startSourceSeconds: Self.sourceDuration - 1,   // 9.0
            recordingDuration: 4,
            events: [
                .init(recordTime: 0,   kind: .play(sourceTime: Self.sourceDuration - 1)),
                .init(recordTime: 1.5, kind: .skip(delta: 5.0)),  // jumps to 10, clamped
            ]
        )
        try await renderClip(clip)

        let frameLate = try decodeFrame(at: 3.5)
        let lastSourceFrame = Self.sourceFrameCount - 1
        // Allow ±5 frames of slack: the EOF-freeze fix backs sourceStart
        // off by 50ms (= 1.5 frames at 30fps) and the H.264 GOP layout
        // can shift the actually-decoded sample a couple of frames either
        // side. The test's purpose is to confirm there's NO hole — a
        // handful of frames off the exact last sample is fine.
        XCTAssertEqual(frameLate, lastSourceFrame, accuracy: 5,
            "post-EOF play tail must freeze on (approximately) the last source frame, not produce a hole; got frame \(frameLate), expected ~\(lastSourceFrame)")
    }

    // MARK: - Spatial tests (fiducial-classified)

    /// At identity zoom, the center fiducial (BLUE, source-(0.50, 0.40))
    /// must decode as BLUE when probed at its source coordinates. Rules
    /// out the trivial setup-failure where the source asset itself is
    /// unreadable or the compositor strips all transforms.
    func test_identityZoom_centerFiducialAtCenterPosition() async throws {
        let clip = makeClip(
            startSourceSeconds: 0,
            recordingDuration: 1,
            events: [.init(recordTime: 0, kind: .zoom(.identity))]
        )
        try await renderClip(clip)

        let identityProbe = try classifyFiducial(at: 0.5,
            viewport: FiducialAsset.Fiducial.center.sourcePoint)
        XCTAssertEqual(identityProbe, .center,
            "expected center BLUE fiducial at viewport-(0.5, 0.4) under identity zoom")
    }

    /// At zoom=2, panX=0.25 (visible source-x window [0.5, 1.0]), the
    /// bottom-right fiducial (MAGENTA at source-(0.85, 0.60)) lands at
    /// viewport-(0.7, 0.7) — the only right-side fiducial whose y stays
    /// inside the visible viewport at panY=0. (The top-right fiducial at
    /// source-y=0.15 ends up at viewport-y=-0.2 — off-screen above.)
    /// Verifies the zoom transform actually maps source coords → viewport
    /// coords using the same math as `Zoom.sourcePoint(atViewPosition:)`.
    func test_zoom2x_panX0p25_bottomRightFiducialLandsWhereExpected() async throws {
        let zoom = Zoom(scale: 2, panX: 0.25, panY: 0)
        let clip = makeClip(
            startSourceSeconds: 0,
            recordingDuration: 1,
            events: [.init(recordTime: 0, kind: .zoom(zoom))]
        )
        try await renderClip(clip)

        let expected = FiducialAsset.expectedViewportPoint(of: .bottomRight, after: zoom)
        let probe = try classifyFiducial(at: 0.5, viewport: expected)
        XCTAssertEqual(probe, .bottomRight,
            "expected MAGENTA bottom-right fiducial at viewport \(expected) under zoom \(zoom); got \(String(describing: probe))")
    }

    /// Zoom keyframes whose `recordTime` falls inside a `scaleTimeRange`-
    /// stretched freeze segment must (a) NOT disturb the held source frame
    /// and (b) take effect at their compTime so the visible fiducial
    /// framing changes when the user expects it. Reproduces a suspected
    /// AVPlayer-compositor edge case where transforms applied inside a
    /// stretched segment have historically been dropped or applied at the
    /// wrong time.
    ///
    /// Barcode decode is only valid at identity-zoom compTimes (the
    /// barcode strip lives at source-y≈0.875, which any non-identity
    /// scale=2 panY=0 moves outside the viewport). The test uses
    /// `zoom@start = identity` and `zoom@end = identity` to bookend the
    /// non-identity zoom keyframes — sampling barcode at both bookends
    /// proves the source frame stayed put across the zoom changes; the
    /// in-between fiducial probes verify the zoom transforms applied.
    func test_zoom_keyframesInsideStretchedFreeze_applyCorrectly() async throws {
        let clip = makeClip(
            startSourceSeconds: 5,
            recordingDuration: 5,
            events: [
                // appendInitialZoom + appendInitialPause: matches production order.
                .init(recordTime: 0,   kind: .zoom(.identity)),
                .init(recordTime: 0,   kind: .pause(sourceTime: 5)),
                // Zoom in, then mirror, then back to identity at end.
                .init(recordTime: 1.0, kind: .zoom(Zoom(scale: 2, panX: 0.25, panY: 0))),
                .init(recordTime: 2.0, kind: .zoom(Zoom(scale: 2, panX: -0.25, panY: 0))),
                .init(recordTime: 4.0, kind: .zoom(.identity)),
            ]
        )
        try await renderClip(clip)

        let expectedFrame = Int((5.0 * Double(Self.sourceFps)).rounded())

        // Barcode decode at IDENTITY-zoom compTimes (start and end of
        // clip): both must show the same held source frame, proving the
        // intermediate zoom keyframes didn't perturb the frozen frame.
        XCTAssertEqual(try decodeFrame(at: 0.5), expectedFrame, accuracy: 1,
            "freeze at identity-zoom start should show the held source frame")
        XCTAssertEqual(try decodeFrame(at: 4.5), expectedFrame, accuracy: 1,
            "freeze at identity-zoom end (after intermediate zoom keyframes) should still show the same held source frame")

        // Identity at start: center fiducial sits at its source coords.
        let beforeAnyChange = try classifyFiducial(at: 0.5,
            viewport: CGPoint(x: 0.5, y: 0.4))
        XCTAssertEqual(beforeAnyChange, .center)

        // After zoom@1 (panX=0.25): bottomRight lands at viewport (0.7, 0.7).
        let afterFirstZoomChange = try classifyFiducial(at: 1.5,
            viewport: CGPoint(x: 0.7, y: 0.7))
        XCTAssertEqual(afterFirstZoomChange, .bottomRight,
            "zoom@1 (inside freeze) should apply at compTime=1.5")

        // After zoom@2 (panX=-0.25): bottomLeft lands at viewport (0.3, 0.7).
        let afterSecondZoomChange = try classifyFiducial(at: 2.5,
            viewport: CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(afterSecondZoomChange, .bottomLeft,
            "zoom@2 (inside freeze) should apply at compTime=2.5")
    }

    /// A realistic recording shape: initial zoom + initial pause, draw a
    /// stroke, resume, zoom out, RW one second, pause again, zoom back in,
    /// resume. Exercises every event kind interleaved across multiple
    /// pause/play cycles AND a backward skip. `.stroke` and `.clearAll`
    /// are included so the segment builder is exercised with all event
    /// kinds at once; both must be no-ops for source-time and zoom math.
    ///
    /// Barcode decode is only valid at identity-zoom compTimes — see
    /// note on `test_zoom_keyframesInsideStretchedFreeze_*`. The clip is
    /// shaped so the period [3.0, 4.0] runs at identity zoom, including a
    /// backward skip mid-window, so we can verify *both* "play advances
    /// source" and "RW actually rewinds source" via the barcode. Other
    /// compTimes verify only that the active zoom placed the right
    /// fiducial at the predicted viewport position.
    func test_realistic_eventRichClip_compositionMatchesSegmentMath() async throws {
        let stroke = Stroke(
            color: .red, lineWidth: 0.005,
            points: [.init(x: 0.3, y: 0.5, t: 0)],
            autoClearAfterSeconds: nil
        )
        let clip = makeClip(
            startSourceSeconds: 2,
            recordingDuration: 8,
            events: [
                .init(recordTime: 0,   kind: .zoom(.identity)),
                .init(recordTime: 0,   kind: .pause(sourceTime: 2)),
                .init(recordTime: 0.5, kind: .zoom(Zoom(scale: 2, panX: 0.25, panY: 0))),
                .init(recordTime: 1.0, kind: .stroke(stroke)),    // no-op for compositor
                .init(recordTime: 2.0, kind: .play(sourceTime: 2)),
                .init(recordTime: 2.5, kind: .clearAll),          // no-op for compositor
                .init(recordTime: 3.0, kind: .zoom(.identity)),   // identity window starts
                .init(recordTime: 3.5, kind: .skip(delta: -1.0)), // RW mid identity-zoom
                .init(recordTime: 5.0, kind: .pause(sourceTime: 3)),
                .init(recordTime: 5.5, kind: .zoom(Zoom(scale: 2, panX: -0.25, panY: 0))),
                .init(recordTime: 7.0, kind: .play(sourceTime: 3)),
            ]
        )
        try await renderClip(clip)

        let fps = Double(Self.sourceFps)
        func frame(_ sourceTime: Double) -> Int {
            Int((sourceTime * fps).rounded())
        }

        // Barcode (identity-zoom window only). Walk the segment math:
        //   compTime 3.0..3.5: PLAY[srcStart=3, dur=0.5] under identity
        //                       (sourceCursor was 3 after play@2 + 1s of play
        //                       advanced to 3, then zoom@3 didn't change cursor)
        //   compTime 3.4 → source 3.4
        //   skip@3.5: sourceCursor 3.5 → 2.5 (rewind 1s)
        //   compTime 3.5..5.0: PLAY[srcStart=2.5, dur=1.5]
        //   compTime 4.0 → source 3.0 (rewound, was source=4.0 just before skip)
        //   compTime 4.9 → source 3.9
        XCTAssertEqual(try decodeFrame(at: 3.4), frame(3.4), accuracy: 2,
            "before RW under identity zoom, source should advance to ~3.4")
        XCTAssertEqual(try decodeFrame(at: 4.0), frame(3.0), accuracy: 2,
            "right after RW(-1) under identity zoom, source should drop ~1s back to ~3.0")
        XCTAssertEqual(try decodeFrame(at: 4.9), frame(3.9), accuracy: 2,
            "deeper into post-RW play segment, source should be ~3.9")

        // Spatial verification at three zoom states (compTimes outside
        // the identity window).
        // After zoom@0.5 (2x panX=0.25): bottomRight at viewport (0.7, 0.7).
        let firstZoom = try classifyFiducial(at: 1.5,
            viewport: CGPoint(x: 0.7, y: 0.7))
        XCTAssertEqual(firstZoom, .bottomRight,
            "zoom@0.5 (2x panX=0.25) should be in effect at compTime=1.5")

        // After zoom@3 (back to identity): center fiducial at viewport (0.5, 0.4).
        let identityRestored = try classifyFiducial(at: 3.6,
            viewport: CGPoint(x: 0.5, y: 0.4))
        XCTAssertEqual(identityRestored, .center,
            "zoom@3 (back to identity) should be in effect at compTime=3.6")

        // After zoom@5.5 (2x panX=-0.25): bottomLeft at viewport (0.3, 0.7).
        let mirrorZoom = try classifyFiducial(at: 6.0,
            viewport: CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(mirrorZoom, .bottomLeft,
            "zoom@5.5 (2x panX=-0.25) should be in effect at compTime=6.0")
    }

    /// Stress test: simulates a user holding a continuous pinch / scroll
    /// for ~3 seconds, which produces ~180 zoom keyframes at typical 60Hz
    /// gesture rate. Real clips that exhibit the "freeze after first
    /// zoom" bug almost certainly fall in this regime; the existing tests
    /// only had ≤5 keyframes per clip. The test verifies the compositor
    /// can build AND render frames for a clip with that keyframe density,
    /// AND that the frames at sample compTimes still decode correctly
    /// (same source frame throughout the freeze, identity-zoom barcode).
    func test_stress_continuousZoomGesture_180keyframes_inFreeze() async throws {
        // 180 zoom keyframes from t=1.0 to t=4.0 (3s × 60Hz). Each
        // keyframe walks scale linearly between 1.0 and 2.0 and panX
        // between 0 and 0.25, mimicking a held pinch + drag. The whole
        // clip is a freeze on sourceTime=5 — the user paused first, then
        // held the gesture.
        var events: [CommentaryEvent] = [
            .init(recordTime: 0, kind: .zoom(.identity)),
            .init(recordTime: 0, kind: .pause(sourceTime: 5)),
        ]
        let keyframeCount = 180
        for i in 0..<keyframeCount {
            let frac = Double(i) / Double(keyframeCount - 1)
            let t = 1.0 + frac * 3.0
            let scale = 1.0 + frac * 1.0   // 1.0 → 2.0
            let panX  = frac * 0.25        // 0 → 0.25
            events.append(.init(recordTime: t,
                kind: .zoom(Zoom(scale: scale, panX: panX, panY: 0))))
        }
        // End with identity so we can decode the barcode at the bookend.
        events.append(.init(recordTime: 4.5, kind: .zoom(.identity)))

        let clip = makeClip(
            startSourceSeconds: 5,
            recordingDuration: 5,
            events: events
        )
        try await renderClip(clip)

        let expectedFrame = Int((5.0 * Double(Self.sourceFps)).rounded())
        // Compositor must render a real frame at the start (identity).
        XCTAssertEqual(try decodeFrame(at: 0.5), expectedFrame, accuracy: 1,
            "high-keyframe-density clip must still render barcode correctly at clip start (identity zoom)")
        // And after all 180 setTransform calls, the freeze must still
        // hold the same source frame and produce a real frame.
        XCTAssertEqual(try decodeFrame(at: 4.7), expectedFrame, accuracy: 1,
            "freeze must still hold the same source frame after 180 setTransform keyframes — failure means the compositor stalled or the frozen frame got tampered with")
    }

    /// Zoom math agreement: the `Zoom.sourcePoint(atViewPosition:)`
    /// formula and the AVPlayer compositor's actual placement of source
    /// pixels must agree. Pick a zoom, compute where the center fiducial
    /// SHOULD be in the viewport, and verify the compositor put it there.
    func test_zoom2x_panY_negative_centerFiducialMovesDown() async throws {
        // panY = -0.1 means "show source content from above the source
        // center at viewport center" — i.e., viewport center looks at
        // source-(0.5, 0.4). The center fiducial at source-(0.5, 0.4)
        // ends up exactly at viewport-(0.5, 0.5).
        let zoom = Zoom(scale: 2, panX: 0, panY: -0.1)
        let clip = makeClip(
            startSourceSeconds: 0,
            recordingDuration: 1,
            events: [.init(recordTime: 0, kind: .zoom(zoom))]
        )
        try await renderClip(clip)

        let expected = FiducialAsset.expectedViewportPoint(of: .center, after: zoom)
        XCTAssertEqual(Double(expected.y), 0.5, accuracy: 1e-9,
            "test setup: panY=-0.1 should put center fiducial at viewport-y=0.5")
        let probe = try classifyFiducial(at: 0.5, viewport: expected)
        XCTAssertEqual(probe, .center,
            "expected BLUE center fiducial at viewport \(expected) under zoom \(zoom); got \(String(describing: probe))")
    }

    // MARK: - Composition build (mirrors ClipPreviewBuilder)

    /// Build the same composition + videoComposition that
    /// `ClipPreviewBuilder.buildPreviewItem` produces. Skips
    /// `AVAssetExportSession`; we render frames directly via
    /// `AVAssetImageGenerator` with `videoComposition` set to keep tests
    /// fast.
    private func renderClip(_ clip: Clip) async throws {
        let srcAsset = AVURLAsset(url: srcURL)
        let camAsset = AVURLAsset(url: camURL)
        let srcDur = try await srcAsset.load(.duration)
        let srcTrack = try await srcAsset.primaryVideoTrack()
        let camTrack = try await camAsset.primaryVideoTrack()

        let comp = AVMutableComposition()
        let sourceVideoComp = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: 1
        )!
        let webcamVideoComp = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: 1000
        )!

        let segments = clip.playbackSegments(sourceDuration: srcDur.seconds)
        let freezeSlice = CMTime(value: 1, timescale: 600)
        var compCursor = CMTime.zero
        for seg in segments {
            let segDur = CMTime(seconds: seg.outDuration, preferredTimescale: 600)
            guard segDur > .zero else { continue }
            let srcStart = CMTime(seconds: seg.sourceStart, preferredTimescale: 600)
            switch seg.kind {
            case .play:
                let srcRange = CMTimeRange(start: srcStart, duration: segDur)
                try sourceVideoComp.insertTimeRange(srcRange, of: srcTrack, at: compCursor)
            case .freeze:
                // Mirror the +1 tick freeze-start bias in production
                // (`ClipPreviewBuilder`, `CompilationExporter`). AV's
                // `insertTimeRange` picks the source sample strictly
                // before the slice start, so a slice that begins exactly
                // at the user-visible frame's PTS delivers the prior
                // frame instead. Shifting by one tick lands the slice
                // inside the visible frame's interval.
                let freezeStart = srcStart + CMTime(value: 1, timescale: 600)
                let frameRange = CMTimeRange(start: freezeStart, duration: freezeSlice)
                try sourceVideoComp.insertTimeRange(frameRange, of: srcTrack, at: compCursor)
                sourceVideoComp.scaleTimeRange(
                    CMTimeRange(start: compCursor, duration: freezeSlice),
                    toDuration: segDur
                )
            }
            compCursor = compCursor + segDur
        }
        let clipDuration = compCursor

        if clipDuration > .zero {
            try webcamVideoComp.insertTimeRange(
                CMTimeRange(start: .zero, duration: clipDuration),
                of: camTrack, at: .zero
            )
        }

        let srcNatural = try await srcTrack.load(.naturalSize)
        let renderSize = CGSize(width: abs(srcNatural.width), height: abs(srcNatural.height))
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.sourceFps))

        let baseStretch = CGAffineTransform(
            scaleX: renderSize.width / max(srcNatural.width, 1),
            y: renderSize.height / max(srcNatural.height, 1)
        )
        func sourceTransform(zoom: Zoom) -> CGAffineTransform {
            baseStretch.concatenating(zoom.deltaTransform(viewportSize: renderSize))
        }
        let zoomKeyframes: [(time: Double, zoom: Zoom)] = clip.events.compactMap { e in
            if case let .zoom(z) = e.kind { return (e.recordTime, z) }
            return nil
        }
        let sourceLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoComp)
        if zoomKeyframes.isEmpty {
            sourceLayer.setTransform(sourceTransform(zoom: .identity), at: .zero)
        } else {
            var lastTime = CMTime(value: -1, timescale: 600)
            for kf in zoomKeyframes {
                let t = CMTime(seconds: kf.time, preferredTimescale: 600)
                guard t > lastTime else { continue }
                sourceLayer.setTransform(sourceTransform(zoom: kf.zoom), at: t)
                lastTime = t
            }
        }

        // Webcam PiP — anchored bottom-right, sized to 22% of the viewport
        // width like the production builder. None of the FiducialAsset
        // probe positions fall inside this region (probes are on
        // fiducials at source-y ≤ 0.60 and on the barcode at source-y
        // ∈ [0.80, 0.95]; the PiP overlay sits at viewport-x ≥ 0.78,
        // viewport-y ≥ 0.83 — clear of every barcode bit's center).
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

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: clipDuration)
        inst.layerInstructions = [webcamLayer, sourceLayer]
        videoComp.instructions = [inst]

        renderedComp = comp
        renderedVideoComp = videoComp
    }

    /// Render a frame at the given compositionTime, decode the bottom
    /// barcode, return the source-frame index.
    private func decodeFrame(at compTime: Double) throws -> Int {
        let cg = try grabFrame(at: compTime)
        guard let f = FiducialAsset.decodeFrameNumber(in: cg) else {
            XCTFail("barcode decode failed at compTime=\(compTime); barcode strip is gray-ish — check whether the compositor produced a real frame")
            throw FiducialAsset.Error.appendFailed("barcode decode failed")
        }
        return f
    }

    /// Render a frame at compTime, sample a 4%×4% probe centered on
    /// `viewport` (each component normalized 0...1), and classify which
    /// fiducial color (if any) the sample matches. Returns nil — and
    /// fails the calling test cleanly via XCTFail — if the requested
    /// probe falls outside the viewport: that's a test-design bug worth
    /// surfacing rather than crashing in PixelSampling's index math.
    private func classifyFiducial(at compTime: Double, viewport: CGPoint) throws -> FiducialAsset.Fiducial? {
        let probeHalf = 0.02
        guard
            viewport.x - probeHalf >= 0, viewport.x + probeHalf <= 1,
            viewport.y - probeHalf >= 0, viewport.y + probeHalf <= 1
        else {
            XCTFail("probe at viewport \(viewport) falls outside the [0,1] viewport — pick a fiducial+zoom whose expected viewport position stays in bounds")
            return nil
        }
        let cg = try grabFrame(at: compTime)
        let probe = CGRect(
            x: Double(viewport.x) - probeHalf, y: Double(viewport.y) - probeHalf,
            width: probeHalf * 2, height: probeHalf * 2
        )
        let rgb = PixelSampling.averageRGB(in: cg, normalizedRect: probe)
        return FiducialAsset.classify(rgb: rgb)
    }

    private func grabFrame(at compTime: Double) throws -> CGImage {
        guard let comp = renderedComp, let videoComp = renderedVideoComp else {
            XCTFail("renderClip(_:) was not called before sampling")
            throw FiducialAsset.Error.appendFailed("no comp")
        }
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = videoComp
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var cgImage: CGImage!
        let semaphore = DispatchSemaphore(value: 0)
        gen.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: CMTime(seconds: compTime, preferredTimescale: 600))]
        ) { _, image, _, _, _ in
            cgImage = image
            semaphore.signal()
        }
        semaphore.wait()
        guard cgImage != nil else {
            XCTFail("no frame at compTime=\(compTime)")
            throw FiducialAsset.Error.appendFailed("no image")
        }
        return cgImage
    }

    private func makeClip(
        startSourceSeconds: Double,
        recordingDuration: Double,
        events: [CommentaryEvent]
    ) -> Clip {
        Clip(
            name: "test", sourceIndex: 0,
            startSourceSeconds: startSourceSeconds,
            recordingDuration: recordingDuration,
            recordingFilename: "irrelevant.mov",
            events: events,
            sortIndex: 0
        )
    }
}
