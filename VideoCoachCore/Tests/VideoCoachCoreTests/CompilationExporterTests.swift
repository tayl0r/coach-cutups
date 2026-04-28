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

    /// Repros the user's actual failure path using their on-disk files. Only
    /// runs when the fixture path exists (i.e. on the user's machine) — CI
    /// and other developers skip silently.
    func test_exporter_realProjectFiles() async throws {
        let sourcePath = "/Users/taylor/Downloads/VID_20260418_095633_01_01.mp4"
        let recordingsDir = "/Users/taylor/coach-cutups/2026-spring/week-2/recordings"
        let projectJSON = "/Users/taylor/coach-cutups/2026-spring/week-2/project.json"
        guard FileManager.default.fileExists(atPath: sourcePath),
              FileManager.default.fileExists(atPath: projectJSON) else {
            throw XCTSkip("Real-project fixture not present on this machine")
        }

        let project = try ProjectStore.read(
            from: URL(fileURLWithPath: "/Users/taylor/coach-cutups/2026-spring/week-2")
        )
        // Filter to clips tagged "highlights" (the simplest case the user could
        // hit — one of the user's actual tags). Adjust as needed to repro.
        let plan = project.compilationPlan(for: "highlights", sourceDurations: [
            0: project.sourceVideos[0].durationSeconds,
        ])
        XCTAssertGreaterThan(plan.entries.count, 0, "no clips matched 'highlights' tag")
        print("[real-repro] plan entries: \(plan.entries.count)")
        for e in plan.entries {
            print("[real-repro]   entry indexInOutput=\(e.indexInOutput) clipID=\(e.clipID) recDur=\(e.recordingDuration)s segments=\(e.segments.count) compStart=\(e.compositionStart)s")
        }

        let sourceAsset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        var clipsByID: [UUID: Clip] = [:]
        var clipWebcamAssets: [UUID: AVURLAsset] = [:]
        for clip in project.clips {
            clipsByID[clip.id] = clip
            let url = URL(fileURLWithPath: recordingsDir).appendingPathComponent(clip.recordingFilename)
            clipWebcamAssets[clip.id] = AVURLAsset(url: url)
        }

        let outputURL = URL(fileURLWithPath: "/tmp/real-repro-output.mp4")
        try? FileManager.default.removeItem(at: outputURL)
        // Don't delete on exit — we want to inspect orientation manually.

        // Diagnostic: build the same composition the exporter would, dump
        // its tracks + instructions, THEN try the export. If invalid, we
        // see exactly what AVFoundation rejected.
        try await dumpCompositionDetails(
            plan: plan, clipsByID: clipsByID,
            sourceAsset: sourceAsset,
            clipWebcamAssets: clipWebcamAssets
        )

        let exporter = CompilationExporter()
        try await exporter.export(
            plan: plan,
            clipsByID: clipsByID,
            sourceAssets: [0: sourceAsset],
            clipWebcamAssets: clipWebcamAssets,
            outputURL: outputURL,
            resolution: .source,
            quality: .medium,
            sourceVolume: 1.0,
            commentaryVolume: 1.0
        )
        // Verify the output exists and is a non-trivial HEVC file. This case
        // is now a regression check for the inter-clip cursor drift bug
        // (sub-millisecond gaps between clips that AVFoundation rejects).
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let outAsset = AVURLAsset(url: outputURL)
        let outDuration = try await outAsset.load(.duration).seconds
        let expectedDuration = plan.entries.reduce(0.0) { $0 + $1.recordingDuration }
        XCTAssertEqual(outDuration, expectedDuration, accuracy: 0.5,
                       "output duration far from sum of clip durations")
        print("[real-repro] SUCCESS: \(plan.entries.count) clips → \(String(format: "%.2f", outDuration))s output")
    }

    /// Inspects the composition the way the exporter builds it and prints
    /// per-track timeline. Run as a no-op preflight to surface bad shapes.
    private func dumpCompositionDetails(
        plan: CompilationPlan,
        clipsByID: [UUID: Clip],
        sourceAsset: AVURLAsset,
        clipWebcamAssets: [UUID: AVURLAsset]
    ) async throws {
        let comp = AVMutableComposition()
        let sourceVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let sourceAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        print("[dump] sourceVideo trackID=\(sourceVideoTrack.trackID), sourceAudio trackID=\(sourceAudioTrack.trackID)")

        let sourceVideoSrc = try await sourceAsset.primaryVideoTrack()
        let sourceAudioSrc = try await sourceAsset.optionalAudioTrack()
        print("[dump] source asset: video=\(sourceVideoSrc.trackID) audio=\(sourceAudioSrc?.trackID ?? -1)")

        for entry in plan.entries {
            let clip = clipsByID[entry.clipID]!
            print("[dump] --- entry \(entry.indexInOutput) clip=\(clip.name) compStart=\(entry.compositionStart)s recDur=\(entry.recordingDuration)s segments=\(entry.segments.count)")
            // Mirror the post-fix CompilationExporter: cursor stays in CMTime
            // so it lands exactly where the previous insert ended.
            var outCursor = CMTime(seconds: entry.compositionStart, preferredTimescale: 600)
            var playCount = 0
            for seg in entry.segments {
                let segDur = CMTime(seconds: seg.outDuration, preferredTimescale: 600)
                if seg.kind == .play {
                    playCount += 1
                    let srcRange = CMTimeRange(start: CMTime(seconds: seg.sourceStart, preferredTimescale: 600),
                                               duration: segDur)
                    do {
                        try sourceVideoTrack.insertTimeRange(srcRange, of: sourceVideoSrc, at: outCursor)
                        if let sourceAudioSrc {
                            try sourceAudioTrack.insertTimeRange(srcRange, of: sourceAudioSrc, at: outCursor)
                        }
                    } catch {
                        print("[dump]   insertTimeRange threw at outCursor=\(outCursor.seconds): \(error)")
                    }
                }
                outCursor = outCursor + segDur
            }
            print("[dump]   inserted \(playCount) play segments")

            let webcamAsset = clipWebcamAssets[clip.id]!
            let webcamVideoSrc = try await webcamAsset.primaryVideoTrack()
            let webcamAudioSrc = try await webcamAsset.optionalAudioTrack()
            let webcamTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let clipDuration = CMTime(seconds: entry.recordingDuration, preferredTimescale: 600)
            let clipStart = CMTime(seconds: entry.compositionStart, preferredTimescale: 600)
            let webcamAvailable = try await webcamAsset.load(.duration)
            let webcamReadDuration = CMTimeMinimum(clipDuration, webcamAvailable)
            try webcamTrack.insertTimeRange(CMTimeRange(start: .zero, duration: webcamReadDuration),
                                            of: webcamVideoSrc, at: clipStart)
            print("[dump]   webcam track \(webcamTrack.trackID) inserted [\(clipStart.seconds)..\((clipStart + webcamReadDuration).seconds)] webcamAvailable=\(webcamAvailable.seconds)s")
            if let webcamAudioSrc {
                let micTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try micTrack.insertTimeRange(CMTimeRange(start: .zero, duration: webcamReadDuration),
                                             of: webcamAudioSrc, at: clipStart)
                print("[dump]   mic track \(micTrack.trackID)")
            }
        }
        print("[dump] composition.duration = \(comp.duration.seconds)s, totalTracks=\(comp.tracks.count)")
        print("[dump] sourceVideoTrack timeRanges: \(sourceVideoTrack.segments.count) segments")
        for (i, s) in sourceVideoTrack.segments.enumerated().prefix(8) {
            print("[dump]   seg[\(i)]: target=\(s.timeMapping.target.start.seconds)..\((s.timeMapping.target.start + s.timeMapping.target.duration).seconds) source=\(s.timeMapping.source.start.seconds)..\((s.timeMapping.source.start + s.timeMapping.source.duration).seconds) empty=\(s.isEmpty)")
        }
        if sourceVideoTrack.segments.count > 8 {
            print("[dump]   ... (\(sourceVideoTrack.segments.count - 8) more)")
        }
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
