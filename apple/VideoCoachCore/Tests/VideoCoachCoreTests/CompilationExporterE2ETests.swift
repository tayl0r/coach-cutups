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

    /// Regression test for the "text bar darkens the PiP" bug. The text
    /// bar (semi-transparent black, bottom 8% of output) overlaps the
    /// bottom slice of the PiP at typical 16:9 / 4:3 layouts. When the
    /// bar fill is drawn AFTER the PiP, the PiP's lower edge gets tinted.
    /// Fix: the bar fill draws in Stage 1 before the PiP composites, so
    /// the PiP appears on top of the bar tint.
    ///
    /// Probe: a small box inside the PiP's horizontal range AND inside
    /// the bar's vertical strip. Expected color: clean webcam dark-gray
    /// (~0.251 per channel). Buggy color: webcam dark-gray darkened by
    /// 60% alpha black → ~0.10 per channel.
    func test_text_bar_renders_below_pip_so_pip_is_not_darkened() async throws {
        let clip = Clip(
            name: "bar-zorder",
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
        // textBarLine is "1 / 1 | bar-zorder | test" (the exporter's
        // assembly). With test active the bar is non-empty so the fill
        // gets drawn.
        try await runExport(clip: clip)

        let cg = try await sampleFrame(of: outURL, atOutputTime: 0.5)

        // Probe inside PiP horizontal (x ∈ [0.758, 0.978]) AND inside
        // bar vertical (y ∈ [0.92, 1.0]). At 720p that overlap is the
        // PiP's bottom slice ≈ y ∈ [0.92, 0.978]. Same tolerance as the
        // companion `test_first_frame_pip_lands_bottom_right_…` test —
        // BT.709 conversion lifts 0x40 to roughly 0.30 in the decoded
        // RGB, and HEVC adds a bit more drift on top.
        let webcamExpected = Double(0x40) / 255.0   // ≈ 0.251
        let tolerance = 0.10

        let probe = CGRect(x: 0.85, y: 0.94, width: 0.04, height: 0.02)
        let rgb = PixelSampling.averageRGB(in: cg, normalizedRect: probe)
        XCTAssertEqual(rgb.r, webcamExpected, accuracy: tolerance,
            "PiP's bottom slice should show clean webcam dark-gray (R≈\(webcamExpected)); got \(rgb). The text bar's semi-transparent fill is darkening the PiP — it must draw below the PiP, not above.")
        XCTAssertEqual(rgb.g, webcamExpected, accuracy: tolerance,
            "PiP's bottom slice G channel; got \(rgb).")
        XCTAssertEqual(rgb.b, webcamExpected, accuracy: tolerance,
            "PiP's bottom slice B channel; got \(rgb).")
    }

    func test_exportSuppressesPiPWhenClipShowPiPFalse() async throws {
        // Mirrors the existing PiP-positive tests but with showPiP=false on
        // the single clip. The bottom-right corner of the output must be
        // source pixels, not the webcam's solid dark-gray.
        let clip = Clip(
            name: "noPiP",
            tags: ["test"],
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 2,
            recordingFilename: camURL.lastPathComponent,
            events: [
                .init(recordTime: 0, kind: .zoom(.identity)),
                .init(recordTime: 0, kind: .play(sourceTime: 0)),
            ],
            showPiP: false,
            sortIndex: 0
        )

        try await runExport(clip: clip)

        // Probe inside the original PiP region (CGImage x≈0.91, y≈0.85 —
        // PiP x ∈ [0.758, 0.978], y ∈ [0.813, 0.978]) but ABOVE the text-
        // bar strip (bar y ∈ [0.92, 1.0]), so the bar's semi-transparent
        // black fill doesn't contaminate the sample. With showPiP=false
        // this pixel comes from the FiducialAsset source background
        // (mid-gray 0x80 ≈ 0.5 per channel). With PiP drawn (the
        // regression we're guarding against), it would instead be the
        // webcam dark-gray (0x40, 0x40, 0x40 ≈ 0.25 per channel,
        // ≈0.32 after BT.709 + HEVC drift).
        let cg = try await sampleFrame(of: outURL, atOutputTime: 0.5)
        let pipProbeRect = CGRect(x: 0.91, y: 0.85, width: 0.04, height: 0.04)
        let pipRGB = PixelSampling.averageRGB(in: cg, normalizedRect: pipProbeRect)
        let maxChannel = max(pipRGB.r, pipRGB.g, pipRGB.b)
        XCTAssertGreaterThan(
            maxChannel, 0.40,
            "bottom-right looks like webcam dark-gray (~0.32/ch after drift) — PiP drew despite showPiP=false. Sample=\(pipRGB)"
        )
    }

    // MARK: - Scoreboard overlay end-to-end

    /// Pixel-anchor integration test for the scoreboard overlay rendered
    /// during export. Verifies the full chain: `Project.scoreboard` +
    /// `Project.matchEvents` → `ExportSheet`-style precompute →
    /// `CompilationExporter.export(scoreboardConfig:matchEventsAbs:…)` →
    /// `CompilationInstruction.scoreboardConfig` → compositor's
    /// `drawScoreboard(...)` call. A regression in any link silently strips
    /// the overlay (export looks like the no-scoreboard baseline) — unit
    /// tests on `scoreboardState` or `drawScoreboard` in isolation can't
    /// catch the wiring break.
    ///
    /// Probes the home and away color cells inside the score bar — home is
    /// pure red, away is pure blue. Layout (from
    /// `Overlays/ScoreboardDraw.swift`, normalized to output size):
    ///   bar:   leftX = 0.015, topY = 0.015, barW = 0.36, barH = 0.08
    ///   accentH = barH * 0.08 ≈ 0.0064 (top sliver)
    ///   scoreBarH = barH - accentH ≈ 0.0736
    ///   scoreRowY = topY + accentH ≈ 0.0214
    ///   homeCell x ∈ [leftX, leftX + 0.30·barW] = [0.015, 0.123]
    ///   awayCell x ∈ [0.195, 0.303]
    ///   both cells y ∈ [≈0.0214, ≈0.095]
    /// Probe rects sit inside those bands and avoid the centered team-name
    /// text (white, ~half the cell height) by sitting near the cell's left
    /// edge.
    func test_export_drawsScoreboard_homePrimaryAtHomeCell_awayPrimaryAtAwayCell() async throws {
        let clip = Clip(
            name: "scoreboard-export",
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
        let scoreboard = ScoreboardConfig(
            home: TeamConfig(
                name: "RED",
                primaryColor: RGBA(r: 1, g: 0, b: 0, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)
            ),
            away: TeamConfig(
                name: "BLU",
                primaryColor: RGBA(r: 0, g: 0, b: 1, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)
            )
        )
        // startStop at absoluteTime=0 — `project.sourceVideos` is empty in
        // this fixture so `cumulativeOffset == 0` and the recorded
        // sourceSeconds maps 1:1 to absSeconds. At output time 0.5 we're at
        // sourceTime 2.5 → absTime 2.5, well past the game start, so
        // `scoreboardState(...)` returns non-nil and the overlay renders.
        let events: [MatchEventRecord] = [
            .init(kind: .startStop, sourceIndex: 0, sourceSeconds: 0.0)
        ]

        try await runExport(clip: clip, scoreboard: scoreboard, matchEvents: events)
        let frame = try await sampleFrame(of: outURL, atOutputTime: 0.5)

        // Probe near the left edge of each cell to dodge the centered team
        // name (white text). Width 0.03 keeps the probe inside the homeCell
        // [0.015, 0.123] / awayCell [0.195, 0.303] horizontal bands.
        let homeAvg = PixelSampling.averageRGB(
            in: frame,
            normalizedRect: CGRect(x: 0.025, y: 0.04, width: 0.03, height: 0.03)
        )
        XCTAssertGreaterThan(homeAvg.r, 0.5,
            "home cell should be red-dominant; got \(homeAvg). If r≈g≈b the scoreboard overlay wasn't drawn — the precompute → exporter → compositor wiring is broken.")
        XCTAssertLessThan(homeAvg.b, 0.3,
            "home cell should not be blue; got \(homeAvg).")

        let awayAvg = PixelSampling.averageRGB(
            in: frame,
            normalizedRect: CGRect(x: 0.205, y: 0.04, width: 0.03, height: 0.03)
        )
        XCTAssertGreaterThan(awayAvg.b, 0.5,
            "away cell should be blue-dominant; got \(awayAvg).")
        XCTAssertLessThan(awayAvg.r, 0.3,
            "away cell should not be red; got \(awayAvg).")
    }

    // MARK: - Helpers

    private func runExport(
        clip: Clip,
        scoreboard: ScoreboardConfig? = nil,
        matchEvents: [MatchEventRecord] = []
    ) async throws {
        var project = Project(name: "export-e2e")
        project.clips = [clip]
        project.scoreboard = scoreboard
        project.matchEvents = matchEvents
        let plan = project.compilationPlan(
            for: "test",
            sourceDurations: [0: Self.sourceDuration]
        )
        XCTAssertEqual(plan.entries.count, 1)

        let sourceAsset = AVURLAsset(url: srcURL)
        let webcamAsset = AVURLAsset(url: camURL)
        // Mirror ExportSheet's scoreboard precompute. `sourceVideos` is empty
        // in this lightweight test fixture (no Project.sourceVideos populated),
        // so `project.absSeconds` collapses to `clip.startSourceSeconds`,
        // which is exactly what we want for a one-source single-clip test.
        let clipStartAbsSecondsByID = Dictionary(
            uniqueKeysWithValues: project.clips.map {
                ($0.id, project.absSeconds(sourceIndex: $0.sourceIndex, sourceSeconds: $0.startSourceSeconds))
            }
        )
        let matchEventsAbs = project.absoluteMatchEvents
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
            commentaryVolume: 1.0,
            scoreboardConfig: project.scoreboard,
            matchEventsAbs: matchEventsAbs,
            clipStartAbsSecondsByID: clipStartAbsSecondsByID
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
