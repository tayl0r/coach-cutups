import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// Tests that `ClipPreviewBuilder` honors `Clip.showPiP` by including or
/// omitting the webcam `AVMutableVideoCompositionLayerInstruction`. The
/// preview path uses AVFoundation's built-in compositor (custom one is
/// stripped on macOS 26 — see ClipPreviewBuilder line 256-260), so the
/// hide-PiP behavior lives entirely in the builder's layerInstructions
/// array. This test guards against a future refactor that accidentally
/// merges the showPiP=true/false branches back into one path.
@MainActor
final class ClipPreviewBuilderTests: XCTestCase {
    private var projectFolder: URL!
    private var srcURL: URL!
    private let webcamFilename = "clip-A.mov"

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
        projectFolder = tmp.appendingPathComponent("preview-builder-\(UUID())")
        let recordingsDir = projectFolder.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir,
                                                withIntermediateDirectories: true)
        srcURL = tmp.appendingPathComponent("preview-builder-src-\(UUID()).mov")
        let webcamURL = recordingsDir.appendingPathComponent(webcamFilename)
        try SyntheticAsset.write(to: srcURL, duration: 1.0, hasAudio: false,
                                 width: 1280, height: 720,
                                 videoColor: (r: 0, g: 0xFF, b: 0))
        try SyntheticAsset.write(to: webcamURL, duration: 1.0, hasAudio: false,
                                 width: 320, height: 240,
                                 videoColor: (r: 0xFF, g: 0, b: 0))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectFolder)
        try? FileManager.default.removeItem(at: srcURL)
    }

    func test_showPiPTrue_includesWebcamLayerInstruction() async throws {
        let entry = try await buildEntry(showPiP: true)
        let item = try XCTUnwrap(entry.player.currentItem)
        let vc = try XCTUnwrap(item.videoComposition)
        let inst = try XCTUnwrap(vc.instructions.first as? AVVideoCompositionInstruction)
        XCTAssertEqual(inst.layerInstructions.count, 2,
            "showPiP=true must emit both webcam + source layer instructions")
    }

    func test_showPiPFalse_omitsWebcamLayerInstruction() async throws {
        let entry = try await buildEntry(showPiP: false)
        let item = try XCTUnwrap(entry.player.currentItem)
        let vc = try XCTUnwrap(item.videoComposition)
        let inst = try XCTUnwrap(vc.instructions.first as? AVVideoCompositionInstruction)
        XCTAssertEqual(inst.layerInstructions.count, 1,
            "showPiP=false must emit only the source layer instruction")
    }

    /// Verifies that `makeVideoComposition` — the helper that
    /// `Workspace.setShowPiP(_:for:)` wraps — correctly rebuilds the
    /// composition with one vs. two layer instructions when called against
    /// a live AVPlayerItem. The guard in `setShowPiP`
    /// (`guard let entry = _previewCache[id] else { return }`) is a
    /// trivial cache-miss no-op; exercising it end-to-end would require
    /// constructing a full `Workspace` with a real project folder, which
    /// transitively pulls MPVKit and ProjectStore into the test bundle —
    /// not worth it for a one-line guard.
    @MainActor
    func test_makeVideoComposition_swapsLayerInstructionsInPlace() async throws {
        let entry = try await buildEntry(showPiP: true)
        let item = try XCTUnwrap(entry.player.currentItem)

        // Sanity: two layer instructions initially.
        let vcBefore = try XCTUnwrap(item.videoComposition)
        let instBefore = try XCTUnwrap(vcBefore.instructions.first as? AVVideoCompositionInstruction)
        XCTAssertEqual(instBefore.layerInstructions.count, 2)

        // Flip via the helper that setShowPiP wraps.
        item.videoComposition = ClipPreviewBuilder.makeVideoComposition(
            renderSize: entry.renderSize,
            clipDuration: entry.clipDuration,
            sourceTrackID: entry.sourceTrackID,
            webcamTrackID: entry.webcamTrackID,
            sourceLayer: entry.sourceLayer,
            webcamLayer: entry.webcamLayer,
            showPiP: false
        )

        let vcAfter = try XCTUnwrap(item.videoComposition)
        let instAfter = try XCTUnwrap(vcAfter.instructions.first as? AVVideoCompositionInstruction)
        XCTAssertEqual(instAfter.layerInstructions.count, 1,
            "live-swap must reduce layer count to 1 without rebuilding the player")

        // Flip back to confirm symmetry.
        item.videoComposition = ClipPreviewBuilder.makeVideoComposition(
            renderSize: entry.renderSize,
            clipDuration: entry.clipDuration,
            sourceTrackID: entry.sourceTrackID,
            webcamTrackID: entry.webcamTrackID,
            sourceLayer: entry.sourceLayer,
            webcamLayer: entry.webcamLayer,
            showPiP: true
        )
        let vcRestored = try XCTUnwrap(item.videoComposition)
        let instRestored = try XCTUnwrap(vcRestored.instructions.first as? AVVideoCompositionInstruction)
        XCTAssertEqual(instRestored.layerInstructions.count, 2,
            "live-swap back to showPiP=true must restore both layer instructions")
    }

    private func buildEntry(showPiP: Bool) async throws -> PreviewCacheEntry {
        var project = Project(name: "preview-builder")
        let bookmark = try srcURL.bookmarkData(options: [])
        project.sourceVideos.append(.init(
            bookmark: bookmark,
            displayName: srcURL.lastPathComponent,
            durationSeconds: 1.0
        ))
        let clip = Clip(
            name: "c",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 1.0,
            recordingFilename: webcamFilename,
            events: [.init(recordTime: 0, kind: .play(sourceTime: 0))],
            showPiP: showPiP,
            sortIndex: 0
        )
        project.clips = [clip]
        return try await ClipPreviewBuilder.buildPreviewEntry(
            for: clip,
            project: project,
            projectFolder: projectFolder
        )
    }
}
