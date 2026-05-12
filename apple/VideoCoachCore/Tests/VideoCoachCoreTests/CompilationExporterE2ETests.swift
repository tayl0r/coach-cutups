import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// End-to-end export verification: write a `FiducialAsset` source, run the
/// production `CompilationExporter`, sample frames from the resulting `.mp4`,
/// and assert that user-recorded events (zoom, freeze, strokes, FF/RW) are
/// reflected in the exported pixels. Catches issues that unit tests on the
/// segment-builder or compositor can't see in isolation — e.g. the
/// 2026-05-05 regression where `CompilationExporter.compositorEvents(...)`
/// stripped `.zoom` events from the per-frame compositor input, producing
/// exports that always rendered at identity zoom regardless of the user's
/// recorded zoom keyframes.
///
/// Each test runs a real HEVC export. Allow ~5–15s wall time per test.
final class CompilationExporterE2ETests: XCTestCase {

    private static let sourceWidth = 1280
    private static let sourceHeight = 720
    private static let sourceFps = 30
    private static let sourceDuration: Double = 10

    private var srcURL: URL!
    private var camURL: URL!
    private var outURL: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
        srcURL = tmp.appendingPathComponent("export-e2e-src-\(UUID()).mov")
        camURL = tmp.appendingPathComponent("export-e2e-cam-\(UUID()).mov")
        outURL = tmp.appendingPathComponent("export-e2e-out-\(UUID()).mp4")
        try FiducialAsset.write(
            to: srcURL,
            duration: Self.sourceDuration,
            width: Self.sourceWidth, height: Self.sourceHeight,
            fps: Self.sourceFps
        )
        // hasAudio: true mirrors the working CompilationExporterTests smoke
        // pattern. The exporter pipes mic audio through an
        // AVMutableAudioMix; providing a real audio track keeps that path
        // happy and avoids -11838 ("Operation not supported for this
        // media") that fires when the audio path gets a malformed input.
        try SyntheticAsset.write(
            to: camURL,
            duration: Self.sourceDuration,
            hasAudio: true,
            width: 320, height: 240,
            videoColor: (r: 0x40, g: 0x40, b: 0x40)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: srcURL)
        try? FileManager.default.removeItem(at: camURL)
        try? FileManager.default.removeItem(at: outURL)
    }

    // MARK: - Zoom regression (the 2026-05-05 user-reported bug)

    /// Regression test for the 2026-05-05 bug: a clip with `appendInitialZoom`
    /// at recordTime=0 (e.g., user zoomed in before pressing Record) must
    /// produce an exported video where the zoom transform is applied. Before
    /// the fix to `CompilationExporter.compositorEvents(from:)`, the zoom was
    /// silently filtered out and exports always rendered at identity.
    ///
    /// Verifies by sampling a frame at viewport (0.7, 0.7) under zoom 2×
    /// panX=0.25 — that location maps to the source's bottom-right MAGENTA
    /// fiducial under that zoom. If zoom is identity (the bug), the same
    /// viewport coordinate sees gray background instead.
    func test_export_zoomKeyframeAppliedToOutputFrames() async throws {
        let zoom = Zoom(scale: 2, panX: 0.25, panY: 0)
        let clip = Clip(
            name: "zoom-export",
            tags: ["test"],
            sourceIndex: 0,
            startSourceSeconds: 5,
            recordingDuration: 2,
            recordingFilename: camURL.lastPathComponent,
            events: [
                .init(recordTime: 0, kind: .zoom(zoom)),
                .init(recordTime: 0, kind: .play(sourceTime: 5)),
            ],
            sortIndex: 0
        )

        try await runExport(clip: clip)

        let cg = try await sampleFrame(of: outURL, atOutputTime: 0.5)
        let probeAt = FiducialAsset.expectedViewportPoint(of: .bottomRight, after: zoom)
        let probe = CGRect(
            x: Double(probeAt.x) - 0.02, y: Double(probeAt.y) - 0.02,
            width: 0.04, height: 0.04
        )
        let rgb = PixelSampling.averageRGB(in: cg, normalizedRect: probe)
        let classified = FiducialAsset.classify(rgb: rgb)
        XCTAssertEqual(classified, .bottomRight,
            "exported video at viewport \(probeAt) under zoom \(zoom) should show the MAGENTA bottom-right fiducial; got \(String(describing: classified)) (sample=\(rgb)). If nil/gray, zoom transform was NOT applied during export — regression of the .zoom event filter.")
    }

    // MARK: - Leading-freeze: clip starts paused

    /// A clip recorded entirely paused — the user pressed R while the source
    /// was paused, drew/zoomed, then stopped — has no `.play` segments at all
    /// on the source video track. The export pipeline relies on the
    /// compositor's `lastSourceFrame` cache for freeze rendering, but that
    /// cache starts nil at every clip boundary. Without a fallback, a
    /// paused-throughout clip exports as black with just the webcam PiP.
    ///
    /// Verifies by exporting a paused-at-sourceTime=5 clip at identity zoom,
    /// then decoding the barcode at output-time=0.5. Should land on the
    /// frame at sourceTime=5 (≈frame 150 at 30fps); a black/garbage frame
    /// would fail to decode the barcode at all.
    func test_export_leadingFreezeClip_showsHeldSourceFrameNotBlack() async throws {
        let clip = Clip(
            name: "paused-export",
            tags: ["test"],
            sourceIndex: 0,
            startSourceSeconds: 5,
            recordingDuration: 2,
            recordingFilename: camURL.lastPathComponent,
            events: [
                .init(recordTime: 0, kind: .zoom(.identity)),
                .init(recordTime: 0, kind: .pause(sourceTime: 5)),
            ],
            sortIndex: 0
        )

        try await runExport(clip: clip)

        let cg = try await sampleFrame(of: outURL, atOutputTime: 0.5)
        guard let frame = FiducialAsset.decodeFrameNumber(in: cg) else {
            XCTFail("barcode unreadable on first frame of paused-throughout clip — export likely produced a black frame because the compositor's lastSourceFrame cache was nil at clip start")
            return
        }
        let expected = Int((5.0 * Double(Self.sourceFps)).rounded())
        XCTAssertEqual(frame, expected, accuracy: 5,
            "leading freeze should show source frame ≈\(expected) (sourceTime=5s); got \(frame)")
    }

    // MARK: - PiP placement and base orientation

    /// Pixel-correctness lock for the compositor GPU-render path: verifies that
    /// (1) the base frame is rendered right-side-up (center pixel matches the
    /// source center fiducial's BLUE color), and (2) the PiP lands at
    /// bottom-right — the bottom-right corner of the output matches the dark-
    /// gray webcam color, while the top-right corner does NOT (it shows the
    /// source's GREEN fiducial instead).
    ///
    /// The webcam is a 320×240 `SyntheticAsset` with `videoColor:
    /// (r:0x40, g:0x40, b:0x40)` (~25% gray), clearly distinguishable from
    /// both mid-gray background (0x80) and every saturated fiducial.
    ///
    /// PiP geometry from `CompilationCompositor.startRequest`:
    ///   pipW = outW * 0.22, margin = outH * 0.022
    ///   CIImage origin = bottom-left → in CGImage (y=0 top) coordinates the
    ///   PiP occupies the bottom-right corner.
    func test_first_frame_pip_lands_bottom_right_and_base_is_upright() async throws {
        let clip = Clip(
            name: "pip-orientation",
            tags: ["test"],
            sourceIndex: 0,
            startSourceSeconds: 2,
            recordingDuration: 2,
            recordingFilename: camURL.lastPathComponent,
            events: [
                .init(recordTime: 0, kind: .zoom(.identity)),
                .init(recordTime: 0, kind: .play(sourceTime: 2)),
            ],
            sortIndex: 0
        )

        try await runExport(clip: clip)

        let cg = try await sampleFrame(of: outURL, atOutputTime: 0.5)

        // ── 1. Base-orientation check ─────────────────────────────────────
        // The center fiducial is BLUE (0x00, 0x00, 0xFF) at source (0.5, 0.4).
        // At identity zoom it maps 1:1 to viewport (0.5, 0.4). We probe a 4%
        // window centered there and classify it.
        let centerProbeRect = CGRect(x: 0.48, y: 0.38, width: 0.04, height: 0.04)
        let centerRGB = PixelSampling.averageRGB(in: cg, normalizedRect: centerProbeRect)
        let centerClass = FiducialAsset.classify(rgb: centerRGB)
        XCTAssertEqual(centerClass, .center,
            "base frame center should be the BLUE center fiducial; got \(String(describing: centerClass)) (sample=\(centerRGB)). A nil/other result means base orientation or zoom math is wrong after the GPU-render refactor.")

        // ── 2. PiP is at bottom-right ─────────────────────────────────────
        // compositor PiP geometry:
        //   pipW = outW*0.22 → x ∈ [0.758, 0.978] (normalized)
        //   pipH = pipW*(240/320) = outW*0.165/outH ≈ 0.165  (720p: 165/720 ≈ 0.229)
        //   CIImage y=0 is bottom; CGImage y=0 is top, so PiP CGImage y ∈ [0.813, 0.978]
        // Probe at (0.93, 0.93) — well inside the PiP region in CGImage coords.
        let webcamExpectedR = Double(0x40) / 255.0   // ≈ 0.251
        let webcamExpectedG = Double(0x40) / 255.0
        let webcamExpectedB = Double(0x40) / 255.0
        let tolerance = 0.10   // wide enough to absorb HEVC + BT.709 bias

        let pipProbeRect = CGRect(x: 0.91, y: 0.91, width: 0.04, height: 0.04)
        let pipRGB = PixelSampling.averageRGB(in: cg, normalizedRect: pipProbeRect)
        XCTAssertEqual(pipRGB.r, webcamExpectedR, accuracy: tolerance,
            "bottom-right corner should show webcam dark-gray R≈\(webcamExpectedR); got \(pipRGB). PiP may not be placed at bottom-right (or Y math is inverted).")
        XCTAssertEqual(pipRGB.g, webcamExpectedG, accuracy: tolerance,
            "bottom-right corner should show webcam dark-gray G≈\(webcamExpectedG); got \(pipRGB).")
        XCTAssertEqual(pipRGB.b, webcamExpectedB, accuracy: tolerance,
            "bottom-right corner should show webcam dark-gray B≈\(webcamExpectedB); got \(pipRGB).")

        // ── 3. Top-right is NOT the webcam (PiP isn't full-height or inverted) ─
        // The topRight fiducial is GREEN at source (0.85, 0.15), which maps to
        // viewport (0.85, 0.15) at identity zoom. Probe at (0.93, 0.05) —
        // outside the PiP region, inside the source image.
        let topRightProbeRect = CGRect(x: 0.91, y: 0.03, width: 0.04, height: 0.04)
        let topRightRGB = PixelSampling.averageRGB(in: cg, normalizedRect: topRightProbeRect)
        // This pixel must NOT look like webcam dark-gray: it should be
        // substantially brighter than 0x40 in at least one channel.
        let maxChannel = max(topRightRGB.r, topRightRGB.g, topRightRGB.b)
        XCTAssertGreaterThan(maxChannel, webcamExpectedR + tolerance,
            "top-right corner should not show the webcam dark-gray color; got \(topRightRGB). If the PiP covered the full right edge or Y was inverted, the PiP would appear here too.")
    }

    // MARK: - Helpers

    private func runExport(clip: Clip) async throws {
        var project = Project(name: "export-e2e")
        project.clips = [clip]
        let plan = project.compilationPlan(
            for: "test",
            sourceDurations: [0: Self.sourceDuration]
        )
        XCTAssertEqual(plan.entries.count, 1)

        let sourceAsset = AVURLAsset(url: srcURL)
        let webcamAsset = AVURLAsset(url: camURL)
        let exporter = CompilationExporter()
        try await exporter.export(
            plan: plan,
            clipsByID: [clip.id: clip],
            sourceAssets: [0: sourceAsset],
            clipWebcamAssets: [clip.id: webcamAsset],
            outputURL: outURL,
            resolution: .r720,
            quality: .medium,
            sourceVolume: 1.0,
            commentaryVolume: 1.0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    private func sampleFrame(of url: URL, atOutputTime t: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var cgImage: CGImage!
        let semaphore = DispatchSemaphore(value: 0)
        gen.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]
        ) { _, image, _, _, _ in
            cgImage = image
            semaphore.signal()
        }
        semaphore.wait()
        guard cgImage != nil else {
            XCTFail("no frame at outputTime=\(t)")
            throw FiducialAsset.Error.appendFailed("no image")
        }
        return cgImage
    }
}
