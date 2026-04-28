import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoCoachCore

#if canImport(AppKit)
import AppKit
#endif

enum ClipPreviewBuilderError: Error {
    case bookmarkResolutionFailed(displayName: String)
    case missingSourceVideo
    case noSourceVideoTrack(URL)
    case noWebcamVideoTrack(URL)
    case pixelBufferAllocFailed
    case freezeFrameDecodeFailed(URL, CMTime, underlying: Error)
}

/// Builds the `AVPlayerItem` for Mode C clip preview.
///
/// **`nonisolated` is load-bearing.** `Workspace` is `@MainActor`-isolated and
/// awaits `buildPreviewItem`. Without `nonisolated`, the heavy work — N ×
/// `AVAssetImageGenerator.image(at:)` calls that each take 100–800ms on
/// long-GOP HEVC sources — would run on the main actor and freeze the UI for
/// seconds at a time. The annotation lets Swift schedule the work on the
/// cooperative thread pool.
enum ClipPreviewBuilder {

    /// Builds an `AVPlayerItem` that plays a single clip's composited preview:
    /// source-with-freezes + continuous webcam + audio mix. Strokes and the
    /// bottom text bar are drawn as AppKit overlays (see `StrokeReplayLayer`)
    /// outside this builder's scope.
    nonisolated static func buildPreviewItem(
        for clip: Clip,
        project: Project,
        projectFolder: URL
    ) async throws -> AVPlayerItem {
        // 1. Resolve the source video URL via the bookmark. Plain bookmarks —
        //    we run unsandboxed under hardened runtime.
        guard project.sourceVideos.indices.contains(clip.sourceIndex) else {
            throw ClipPreviewBuilderError.missingSourceVideo
        }
        let sourceRef = project.sourceVideos[clip.sourceIndex]
        let srcURL = try resolveBookmark(sourceRef.bookmark,
                                         displayName: sourceRef.displayName)
        // 2. Resolve the webcam recording URL.
        let webcamURL = ProjectStore.recordingsDir(in: projectFolder)
            .appendingPathComponent(clip.recordingFilename)

        // 3. Load both assets.
        let srcAsset = AVURLAsset(url: srcURL)
        let webcamAsset = AVURLAsset(url: webcamURL)

        async let srcDurationLoad = srcAsset.load(.duration)
        async let srcVideoTrackLoad = srcAsset.primaryVideoTrack()
        async let srcAudioTrackLoad = srcAsset.optionalAudioTrack()

        let webcamDuration = try await webcamAsset.load(.duration)
        let webcamVideoTrack = try await webcamAsset.primaryVideoTrack()
        let webcamAudioTrack = try await webcamAsset.optionalAudioTrack()

        let srcDuration = try await srcDurationLoad
        let srcVideoTrack = try await srcVideoTrackLoad
        let srcAudioTrack = try await srcAudioTrackLoad

        let sourceDurationSeconds = srcDuration.seconds.isFinite
            ? srcDuration.seconds
            : sourceRef.durationSeconds
        let segments = clip.playbackSegments(sourceDuration: sourceDurationSeconds)

        // 4. Build composition. Track-ID strategy mirrors the export's:
        //    source video = 1, source audio = 2, webcam video = 1000,
        //    webcam audio = 2000. Required so the compositor can fetch by ID
        //    and the audio mix can target each input by trackID.
        let comp = AVMutableComposition()
        let sourceTrackID: CMPersistentTrackID = 1
        let sourceAudioTrackID: CMPersistentTrackID = 2
        let webcamTrackID: CMPersistentTrackID = 1000
        let webcamAudioTrackID: CMPersistentTrackID = 2000

        guard let sourceVideoComp = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: sourceTrackID
        ) else {
            throw ClipPreviewBuilderError.noSourceVideoTrack(srcURL)
        }
        guard let webcamVideoComp = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: webcamTrackID
        ) else {
            throw ClipPreviewBuilderError.noWebcamVideoTrack(webcamURL)
        }
        let sourceAudioComp = comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: sourceAudioTrackID
        )
        let webcamAudioComp = comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: webcamAudioTrackID
        )

        // Insert source-video `.play` segments only — `.freeze` segments are
        // synthesized at render time by re-emitting the pre-decoded frame.
        // Use a 600-tick timescale to match the rest of the project's
        // CMTime conventions.
        var compCursor = CMTime.zero
        for seg in segments {
            let segDur = CMTime(seconds: seg.outDuration, preferredTimescale: 600)
            switch seg.kind {
            case .play:
                let srcStart = CMTime(seconds: seg.sourceStart, preferredTimescale: 600)
                let srcRange = CMTimeRange(start: srcStart, duration: segDur)
                try sourceVideoComp.insertTimeRange(srcRange, of: srcVideoTrack, at: compCursor)
                if let sourceAudioComp, let srcAudioTrack {
                    try? sourceAudioComp.insertTimeRange(srcRange, of: srcAudioTrack, at: compCursor)
                }
            case .freeze:
                // No insert — the compositor returns the frozen frame for
                // these output times. `requiredSourceTrackIDs` keeps the
                // track in the request even when no media is attached at
                // this output time.
                break
            }
            compCursor = compCursor + segDur
        }

        // Webcam plays continuously over the clip's full duration. Use the
        // composition's accumulated duration (built from segments) as the
        // canonical clip duration; clamp to the webcam's actual length so
        // we don't try to insert past EOF.
        let clipDuration = compCursor
        let webcamUseDuration = min(clipDuration, webcamDuration)
        if webcamUseDuration > .zero {
            try webcamVideoComp.insertTimeRange(
                CMTimeRange(start: .zero, duration: webcamUseDuration),
                of: webcamVideoTrack,
                at: .zero
            )
            if let webcamAudioComp, let webcamAudioTrack {
                try? webcamAudioComp.insertTimeRange(
                    CMTimeRange(start: .zero, duration: webcamUseDuration),
                    of: webcamAudioTrack,
                    at: .zero
                )
            }
        }

        // 5. Pre-decode freeze frames. Skip the entire allocation if there
        //    are no `.freeze` segments — the common case for an
        //    uninterrupted recording.
        var frozenFrames: [Int: CVPixelBuffer] = [:]
        let freezeIndices = segments.enumerated().compactMap {
            $0.element.kind == .freeze ? $0.offset : nil
        }
        if !freezeIndices.isEmpty {
            let gen = AVAssetImageGenerator(asset: srcAsset)
            gen.appliesPreferredTrackTransform = true
            // Snap to the nearest keyframe — fine for a held frame, and the
            // reason a 100–800ms decode window is acceptable here.
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            gen.maximumSize = CGSize(width: 1280, height: 720)

            for i in freezeIndices {
                let priorPlayEnd = sourceTimeAtEndOfPlay(precedingSegment: i, in: segments)
                let t = CMTime(seconds: priorPlayEnd, preferredTimescale: 600)
                let cgImage: CGImage
                do {
                    let result = try await gen.image(at: t)
                    cgImage = result.image
                } catch {
                    throw ClipPreviewBuilderError.freezeFrameDecodeFailed(srcURL, t, underlying: error)
                }
                let buf = try cgImageToBGRAPixelBuffer(cgImage)
                frozenFrames[i] = buf
            }
        }

        // 6. Build the video composition. One PreviewInstruction covering the
        //    whole clip; AVFoundation calls `startRequest` per output frame.
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = PreviewCompositor.self
        videoComp.renderSize = CGSize(width: 1280, height: 720)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = PreviewInstruction.make(
            sourceTrackID: sourceTrackID,
            webcamTrackID: webcamTrackID,
            compositionStart: .zero,
            clipDuration: clipDuration,
            segments: segments,
            frozenFrames: frozenFrames
        )
        videoComp.instructions = [instruction]

        let item = AVPlayerItem(asset: comp)
        item.videoComposition = videoComp
        return item
    }

    // MARK: - Helpers

    /// Source-time at the END of the `.play` segment immediately preceding
    /// `freezeIndex`. The frozen frame for that freeze should display
    /// whatever the user last saw before pausing. If no `.play` segment
    /// precedes it (the unusual case of a clip that begins with `.freeze`),
    /// fall back to the very first segment's `sourceStart` — the earliest
    /// source-time the compositor knows about.
    nonisolated private static func sourceTimeAtEndOfPlay(
        precedingSegment freezeIndex: Int,
        in segments: [PlaybackSegment]
    ) -> Double {
        var i = freezeIndex - 1
        while i >= 0 {
            let seg = segments[i]
            if seg.kind == .play {
                return seg.sourceStart + seg.outDuration
            }
            i -= 1
        }
        return segments.first?.sourceStart ?? 0
    }

    nonisolated private static func resolveBookmark(_ data: Data,
                                                    displayName: String) throws -> URL {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            return url
        } catch {
            throw ClipPreviewBuilderError.bookmarkResolutionFailed(displayName: displayName)
        }
    }

    nonisolated private static func cgImageToBGRAPixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width, image.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard let buf = pb else { throw ClipPreviewBuilderError.pixelBufferAllocFailed }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buf
    }
}
