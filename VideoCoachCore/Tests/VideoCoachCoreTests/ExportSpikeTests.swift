import AVFoundation
import CoreMedia
import XCTest

/// Phase 9.0 spike. Confirms `AVAssetExportSession` honors a
/// `customVideoCompositorClass` AND a custom `audioMix` when paired with the
/// HEVC 1080p preset. If any of the three assertions fails, the export
/// architecture (Phase 9.3–9.5) must switch to AVAssetReader/AVAssetWriter
/// (Task 9.6 promoted to mandatory).
///
/// Kept as a regression check — costs <2s and protects against future macOS
/// regressions of this combination.
final class ExportSpikeTests: XCTestCase {
    func test_AVAssetExportSession_honorsCustomCompositorAndAudioMix_underHEVCPreset() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let sourceURL = tmp.appendingPathComponent("spike-source-\(UUID()).mov")
        let outputURL = tmp.appendingPathComponent("spike-output-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Source: 10s of solid green + 1kHz sine at amplitude 0.5. Source is 64×64 — the
        // compositor paints solid red at the export's render size (1920×1080) regardless,
        // so source resolution doesn't influence what we're testing and a small source
        // keeps the test fast. (Plan said 1080p source; we deviate for speed.)
        try SyntheticAsset.write(
            to: sourceURL,
            duration: 10.0,
            hasAudio: true,
            width: 64,
            height: 64,
            videoColor: (r: 0, g: 0xFF, b: 0),
            audioFrequency: 1_000,
            audioAmplitude: 0.5
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first!
        let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio).first!

        // Composition wraps the source.
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)!
        try v.insertTimeRange(.init(start: .zero, duration: sourceDuration), of: sourceVideo, at: .zero)
        try a.insertTimeRange(.init(start: .zero, duration: sourceDuration), of: sourceAudio, at: .zero)

        // Custom compositor + 0.25 audio mix.
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = RedCompositor.self
        videoComp.renderSize = CGSize(width: 1920, height: 1080)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: sourceDuration)
        videoComp.instructions = [inst]

        let audioMix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: a)
        params.setVolume(0.25, at: .zero)
        audioMix.inputParameters = [params]

        // Export.
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVC1920x1080) else {
            XCTFail("Could not create export session")
            return
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4    // mirrors production CompilationExporter (Task 9.4)
        export.videoComposition = videoComp
        export.audioMix = audioMix
        await export.export()
        XCTAssertEqual(
            export.status, .completed,
            "Export failed: \(export.error?.localizedDescription ?? "unknown")"
        )

        // ─── Verification 1: Output is HEVC, encode actually ran. ───
        // NOTE: the plan's original assertion required bitrate > 1 Mbps. With solid-red
        // input that floor is unrealistic — HEVC compresses uniform color to a few KB
        // regardless of resolution. We instead assert HEVC codec + non-empty encode +
        // reasonable upper bound; bitrate ceiling protects against the "preset returned
        // raw bytes" pathology. Real bitrate vs Quality validation belongs in Task 9.4
        // with realistic content.
        let outAsset = AVURLAsset(url: outputURL)
        let outVideo = try await outAsset.loadTracks(withMediaType: .video).first!
        let formats = try await outVideo.load(.formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC, "Output is not HEVC")
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let outDuration = try await outAsset.load(.duration).seconds
        let computedBitrate = Double(outSize * 8) / max(outDuration, 0.001)
        XCTAssertGreaterThan(outSize, 1_000, "Output file suspiciously small — encoder may have skipped")
        XCTAssertLessThan(computedBitrate, 50_000_000, "Bitrate suspiciously high — preset may have written raw")
        XCTAssertEqual(outDuration, 10.0, accuracy: 0.5, "Output duration far from source")

        // ─── Verification 2: Frame at t=1s is RED, not green. ───
        // Proves the custom compositor was actually invoked by the HEVC preset path.
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.appliesPreferredTrackTransform = true
        let (cgImage, _) = try await gen.image(at: CMTime(seconds: 1.0, preferredTimescale: 600))
        let center = PixelSampling.averageRGB(
            in: cgImage,
            normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        )
        XCTAssertGreaterThan(center.r, 0.8, "Frame is not red — compositor was bypassed (preset fast-path)")
        XCTAssertLessThan(center.g, 0.2, "Frame still has green — compositor was not honored")

        // ─── Verification 3: Audio is ~0.25× original RMS. ───
        // Proves the AVMutableAudioMix was honored by the export pipeline.
        let outAudio = try await outAsset.loadTracks(withMediaType: .audio).first!
        let outRMS = try await AudioRMS.measure(track: outAudio, in: outAsset)
        let sourceRMS = try await AudioRMS.measure(track: sourceAudio, in: sourceAsset)
        XCTAssertEqual(
            outRMS / sourceRMS, 0.25, accuracy: 0.05,
            "Audio mix was not honored — output amplitude is \(outRMS / sourceRMS)× source"
        )
    }
}
