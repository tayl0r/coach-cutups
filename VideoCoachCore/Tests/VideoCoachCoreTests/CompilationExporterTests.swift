import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

/// Phase 9.4 smoke test. Builds a one-clip ``CompilationPlan``, runs the
/// production ``CompilationExporter`` end-to-end, and verifies the output
/// `.mp4`:
///   - Exists on disk and is non-trivially sized.
/// - Loads through `AVURLAsset`.
///   - Has at least one HEVC video track.
/// - Duration is approximately the clip's recording duration.
///
/// This is the most expensive test in the suite (real synthetic-asset writes
/// + a real HEVC export). Allow ~5–15s wall time.
final class CompilationExporterTests: XCTestCase {
    func test_exporter_producesHEVCFileForSingleClip() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let sourceURL = tmp.appendingPathComponent("exporter-source-\(UUID()).mov")
        let webcamURL = tmp.appendingPathComponent("exporter-webcam-\(UUID()).mov")
        let outputURL = tmp.appendingPathComponent("exporter-output-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: webcamURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // 1. Synthetic source: 5s of solid green, silent audio. Tiny dimensions
        //    are fine — the compositor renders into the export's renderSize
        //    regardless of source resolution.
        try SyntheticAsset.write(
            to: sourceURL,
            duration: 5.0,
            hasAudio: true,
            width: 320,
            height: 240,
            videoColor: (r: 0, g: 0xFF, b: 0)
        )
        // 2. Synthetic webcam: 2s of solid blue with audio (silent — mic mix
        //    isn't asserted here; we only care the export runs cleanly).
        try SyntheticAsset.write(
            to: webcamURL,
            duration: 2.0,
            hasAudio: true,
            width: 320,
            height: 240,
            videoColor: (r: 0, g: 0, b: 0xFF)
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let webcamAsset = AVURLAsset(url: webcamURL)

        // 3. Build a one-clip Project + plan. recordingDuration=2.0 with a
        //    single .play event at t=0 means the plan emits one .play
        //    segment covering the entire clip.
        let clip = Clip(
            name: "smoke",
            tags: ["test"],
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 2.0,
            recordingFilename: webcamURL.lastPathComponent,
            events: [CommentaryEvent(recordTime: 0, kind: .play)],
            sortIndex: 0
        )
        var project = Project(name: "exporter-smoke")
        project.clips = [clip]

        let plan = project.compilationPlan(
            for: "test",
            sourceDurations: [0: 5.0]
        )
        XCTAssertEqual(plan.entries.count, 1, "single tag should produce one entry")

        // 4. Run the exporter.
        let exporter = CompilationExporter()
        let started = Date()
        do {
            try await exporter.export(
                plan: plan,
                clipsByID: [clip.id: clip],
                sourceAssets: [0: sourceAsset],
                clipWebcamAssets: [clip.id: webcamAsset],
                outputURL: outputURL,
                resolution: .r720,
                quality: .medium,
                sourceVolume: 1.0,
                commentaryVolume: 1.0
            )
        } catch {
            XCTFail("export threw: \(error)")
            return
        }
        let wall = Date().timeIntervalSince(started)
        print("[exporter smoke] wall-time: \(String(format: "%.2f", wall))s")

        // 5. Verify the output file.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "output .mp4 was not created at \(outputURL.path)"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        print("[exporter smoke] output size: \(size) bytes")
        XCTAssertGreaterThan(size, 1_000, "output file suspiciously small")

        let outAsset = AVURLAsset(url: outputURL)
        let outDuration = try await outAsset.load(.duration).seconds
        print("[exporter smoke] output duration: \(String(format: "%.3f", outDuration))s")
        XCTAssertEqual(outDuration, 2.0, accuracy: 0.1, "output duration far from clip duration")

        let videoTracks = try await outAsset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThanOrEqual(videoTracks.count, 1, "no video track in output")
        let formats = try await videoTracks.first!.load(.formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        print("[exporter smoke] video codec: \(codec.map { fourCC($0) } ?? "<none>")")
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC, "output is not HEVC")
    }

    /// Reproduces the user-reported "Operation Stopped" / -11841 failure
    /// path: multi-clip export at the resolution the export sheet defaults
    /// to (.r1080), with each clip having its own webcam recording. If this
    /// passes the bug is content-specific (e.g. real HEVC source); if it
    /// fails we have a local repro to iterate on.
    func test_exporter_multiClipAt1080p() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let sourceURL = tmp.appendingPathComponent("multi-source-\(UUID()).mov")
        let webcam0URL = tmp.appendingPathComponent("multi-webcam0-\(UUID()).mov")
        let webcam1URL = tmp.appendingPathComponent("multi-webcam1-\(UUID()).mov")
        let outputURL = tmp.appendingPathComponent("multi-output-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: webcam0URL)
            try? FileManager.default.removeItem(at: webcam1URL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try SyntheticAsset.write(to: sourceURL, duration: 10.0, hasAudio: true,
                                 width: 320, height: 240,
                                 videoColor: (r: 0, g: 0xFF, b: 0))
        try SyntheticAsset.write(to: webcam0URL, duration: 2.0, hasAudio: true,
                                 width: 320, height: 240,
                                 videoColor: (r: 0, g: 0, b: 0xFF))
        try SyntheticAsset.write(to: webcam1URL, duration: 2.5, hasAudio: true,
                                 width: 320, height: 240,
                                 videoColor: (r: 0xFF, g: 0, b: 0xFF))

        let sourceAsset = AVURLAsset(url: sourceURL)
        let webcam0Asset = AVURLAsset(url: webcam0URL)
        let webcam1Asset = AVURLAsset(url: webcam1URL)

        let clip0 = Clip(
            name: "first", tags: ["test"],
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 2.0, recordingFilename: webcam0URL.lastPathComponent,
            events: [CommentaryEvent(recordTime: 0, kind: .play)],
            sortIndex: 0
        )
        let clip1 = Clip(
            name: "second", tags: ["test"],
            sourceIndex: 0, startSourceSeconds: 5.0,
            recordingDuration: 2.5, recordingFilename: webcam1URL.lastPathComponent,
            events: [CommentaryEvent(recordTime: 0, kind: .play)],
            sortIndex: 1
        )
        var project = Project(name: "multi-clip-smoke")
        project.clips = [clip0, clip1]

        let plan = project.compilationPlan(for: "test", sourceDurations: [0: 10.0])
        XCTAssertEqual(plan.entries.count, 2)

        let exporter = CompilationExporter()
        do {
            try await exporter.export(
                plan: plan,
                clipsByID: [clip0.id: clip0, clip1.id: clip1],
                sourceAssets: [0: sourceAsset],
                clipWebcamAssets: [clip0.id: webcam0Asset, clip1.id: webcam1Asset],
                outputURL: outputURL,
                resolution: .r1080,
                quality: .medium,
                sourceVolume: 1.0,
                commentaryVolume: 1.0
            )
        } catch {
            XCTFail("multi-clip export threw: \(error)")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let outAsset = AVURLAsset(url: outputURL)
        let outDuration = try await outAsset.load(.duration).seconds
        // Two clips: 2.0 + 2.5 = 4.5s
        XCTAssertEqual(outDuration, 4.5, accuracy: 0.2)
    }

    /// FourCC stringifier for log output: `1752589105 → "hvc1"`.
    private func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
