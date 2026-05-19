import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoCoachCore

#if canImport(AppKit)
import AppKit
#endif

/// Cached preview state for a single clip. Phase A of `ClipPreviewBuilder`
/// (asset loads, composition track inserts, source/webcam layer instructions
/// with their geometry baked in) produces this entry once; Phase B
/// re-runs whenever `showPiP` toggles to rebuild just the
/// `AVMutableVideoComposition` (cheap — no asset I/O).
struct PreviewCacheEntry {
    let player: AVPlayer
    let renderSize: CGSize
    let clipDuration: CMTime
    let sourceTrackID: CMPersistentTrackID
    let webcamTrackID: CMPersistentTrackID
    let sourceLayer: AVMutableVideoCompositionLayerInstruction
    let webcamLayer: AVMutableVideoCompositionLayerInstruction
}

enum ClipPreviewBuilderError: Error {
    case bookmarkResolutionFailed(displayName: String)
    case missingSourceVideo
    case noSourceVideoTrack(URL)
    case noWebcamVideoTrack(URL)
    case invalidSourceNaturalSize(URL)
}

/// Builds a `PreviewCacheEntry` for Mode C clip preview.
///
/// **`nonisolated` is load-bearing.** `Workspace` is `@MainActor`-isolated and
/// awaits `buildPreviewEntry`. Without `nonisolated`, the heavy work — N ×
/// AVFoundation asset loads (duration, video/audio tracks, naturalSize) and
/// composition track insertions, which on long-GOP HEVC can take 100–800ms —
/// would run on the main actor and freeze the UI for seconds at a time. The
/// annotation lets Swift schedule the work on the cooperative thread pool.
enum ClipPreviewBuilder {

    /// Builds a `PreviewCacheEntry` that plays a single clip's composited
    /// preview: source-with-freezes + continuous webcam + audio mix. Strokes
    /// and the bottom text bar are drawn as AppKit overlays (see
    /// `StrokeReplayLayer`) outside this builder's scope.
    nonisolated static func buildPreviewEntry(
        for clip: Clip,
        project: Project,
        projectFolder: URL
    ) async throws -> PreviewCacheEntry {
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
        NSLog("[Preview] building for clip \(clip.id) src=\(srcURL.lastPathComponent) webcam=\(webcamURL.lastPathComponent)")
        let webcamExists = FileManager.default.fileExists(atPath: webcamURL.path)
        let webcamSize = (try? FileManager.default.attributesOfItem(atPath: webcamURL.path)[.size] as? Int) ?? -1
        NSLog("[Preview] webcam file exists=\(webcamExists) size=\(webcamSize)")

        // 3. Load both assets.
        let srcAsset = AVURLAsset(url: srcURL)
        let webcamAsset = AVURLAsset(url: webcamURL)

        async let srcDurationLoad = srcAsset.load(.duration)
        async let srcVideoTrackLoad = srcAsset.primaryVideoTrack()
        async let srcAudioTrackLoad = srcAsset.optionalAudioTrack()

        let webcamDuration: CMTime
        let webcamVideoTrack: AVAssetTrack
        let webcamAudioTrack: AVAssetTrack?
        let srcDuration: CMTime
        let srcVideoTrack: AVAssetTrack
        let srcAudioTrack: AVAssetTrack?
        do {
            NSLog("[Preview] loading webcam.duration"); webcamDuration = try await webcamAsset.load(.duration)
            NSLog("[Preview] loading webcam.videoTrack"); webcamVideoTrack = try await webcamAsset.primaryVideoTrack()
            NSLog("[Preview] loading webcam.audioTrack"); webcamAudioTrack = try await webcamAsset.optionalAudioTrack()
            NSLog("[Preview] loading src.duration"); srcDuration = try await srcDurationLoad
            NSLog("[Preview] loading src.videoTrack"); srcVideoTrack = try await srcVideoTrackLoad
            NSLog("[Preview] loading src.audioTrack"); srcAudioTrack = try await srcAudioTrackLoad
        } catch {
            NSLog("[Preview] asset load step failed: \(error)")
            throw error
        }
        NSLog("[Preview] loads done. srcDur=\(srcDuration.seconds) webcamDur=\(webcamDuration.seconds)")

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
        // Sub-frame granule for freeze inserts (1.67ms at timescale 600).
        // Smaller than any practical source frame duration (30 fps = 33ms,
        // 60 fps = 16.7ms), so the inserted slice contains exactly one
        // source frame — the one displayed at `srcStart`. We then stretch
        // it across the freeze's full duration via `scaleTimeRange`, which
        // makes AVPlayer hold that single frame for as long as the user
        // paused. Using a wider slice (e.g. 1/30s) risks straddling a
        // source frame boundary and showing the *next* frame partway
        // through the freeze, which the user perceives as the pause
        // happening at a slightly wrong moment.
        let freezeSlice = CMTime(value: 1, timescale: 600)
        var compCursor = CMTime.zero
        for (segIdx, seg) in segments.enumerated() {
            let segDur = CMTime(seconds: seg.outDuration, preferredTimescale: 600)
            // Sub-frame segments (e.g. two events <1ms apart from a continuous
            // zoom gesture) round to 0 ticks at timescale 600. AVFoundation
            // rejects empty insertTimeRange calls with -11800/-12780, so skip
            // both the source insert and the cursor advance — there's nothing
            // to render either way.
            guard segDur > .zero else { continue }
            let srcStart = CMTime(seconds: seg.sourceStart, preferredTimescale: 600)
            switch seg.kind {
            case .play:
                let srcRange = CMTimeRange(start: srcStart, duration: segDur)
                do {
                    try sourceVideoComp.insertTimeRange(srcRange, of: srcVideoTrack, at: compCursor)
                } catch {
                    NSLog("[Preview] sourceVideoComp.insertTimeRange failed seg=\(segIdx) range=\(srcRange) at=\(compCursor): \(error)")
                    throw error
                }
                if let sourceAudioComp, let srcAudioTrack {
                    try? sourceAudioComp.insertTimeRange(srcRange, of: srcAudioTrack, at: compCursor)
                }
            case .freeze:
                // Insert one source frame at the freeze's source-time, then
                // stretch it to fill the freeze's output duration. AVPlayer
                // sees a regular source slice and delivers it on every
                // composite request, so the compositor can render it without
                // needing the PreviewInstruction's pre-decoded frozenFrames
                // (which the playback path can't reach).
                //
                // Bias the slice's start ONE TICK past `srcStart` (1.67ms at
                // timescale 600 — ~5% of a 30fps frame, far less on faster
                // sources). When mpv reports `time-pos` exactly on a source
                // frame's PTS boundary, AVMutableComposition's
                // `insertTimeRange` empirically picks the sample whose PTS
                // is STRICTLY less than the slice start, delivering the
                // frame BEFORE the user-visible one. The strokes overlay
                // then appears on a frame one motion-step behind where the
                // user drew. Shifting by one tick lands the slice safely
                // inside the visible frame's PTS interval (the next frame
                // boundary is always ≥ 8ms away — half-frame at 60 fps).
                let freezeStart = srcStart + CMTime(value: 1, timescale: 600)
                let frameRange = CMTimeRange(start: freezeStart, duration: freezeSlice)
                do {
                    try sourceVideoComp.insertTimeRange(frameRange, of: srcVideoTrack, at: compCursor)
                } catch {
                    NSLog("[Preview] sourceVideoComp.insertTimeRange (freeze) failed seg=\(segIdx) range=\(frameRange) at=\(compCursor): \(error)")
                    throw error
                }
                sourceVideoComp.scaleTimeRange(
                    CMTimeRange(start: compCursor, duration: freezeSlice),
                    toDuration: segDur
                )
            }
            compCursor = compCursor + segDur
        }

        // Webcam plays continuously over the clip's full duration. Use the
        // composition's accumulated duration (built from segments) as the
        // canonical clip duration; clamp to the webcam's actual length so
        // we don't try to insert past EOF.
        let clipDuration = compCursor
        let webcamUseDuration = min(clipDuration, webcamDuration)
        NSLog("[Preview] segments=\(segments.count) clipDur=\(clipDuration.seconds) webcamUse=\(webcamUseDuration.seconds)")
        if webcamUseDuration > .zero {
            do {
                try webcamVideoComp.insertTimeRange(
                    CMTimeRange(start: .zero, duration: webcamUseDuration),
                    of: webcamVideoTrack,
                    at: .zero
                )
            } catch {
                NSLog("[Preview] webcamVideoComp.insertTimeRange failed dur=\(webcamUseDuration.seconds): \(error)")
                throw error
            }
            if let webcamAudioComp, let webcamAudioTrack {
                try? webcamAudioComp.insertTimeRange(
                    CMTimeRange(start: .zero, duration: webcamUseDuration),
                    of: webcamAudioTrack,
                    at: .zero
                )
            }
        }

        // 5. (No freeze pre-decode anymore — freeze segments are now realized
        //    as 1-frame source slices stretched to the freeze duration via
        //    `scaleTimeRange` in the segment loop above. AVPlayer delivers
        //    them through the normal sourceFrame pipeline, so we don't need
        //    a per-segment frozenFrames cache.)

        // 6. v1 sources are landscape-only (matching
        // `CompilationExporter.renderSize`), so renderSize is the source's
        // raw natural size with no rotation handling.
        let srcNatural = try await srcVideoTrack.load(.naturalSize)
        let nativeRender = CGSize(
            width: abs(srcNatural.width),
            height: abs(srcNatural.height)
        )
        guard nativeRender.width > 0, nativeRender.height > 0 else {
            throw ClipPreviewBuilderError.invalidSourceNaturalSize(srcURL)
        }
        // Preview is shown in a window — the source's full native dimensions
        // (often 4K) inflate every per-frame composite/output buffer with no
        // visible benefit. Cap the longer side to 1920px and preserve aspect.
        // Export keeps native (CompilationExporter has its own composition).
        let maxLongSide: CGFloat = 1920
        let longest = max(nativeRender.width, nativeRender.height)
        let renderSize: CGSize
        if longest > maxLongSide {
            let scale = maxLongSide / longest
            renderSize = CGSize(
                width: (nativeRender.width * scale).rounded(),
                height: (nativeRender.height * scale).rounded()
            )
        } else {
            renderSize = nativeRender
        }

        // No custom compositor: AVPlayer's playback path on macOS 26 strips
        // any subclass of AVMutableVideoCompositionInstruction (along with the
        // `requiredSourceTrackIDs` override carried on it), causing every
        // source-frame request to return nil → black playback. Built-in
        // composition with explicit layer instructions sidesteps the strip.

        // Source layer: stretch the source's natural size to the renderSize
        // (matching the pre-rewrite "non-uniform fit"), then layer the
        // recorded zoom on top via setTransformRamp so playback replays the
        // user's pinch/scroll/pan gestures.
        let baseStretch = CGAffineTransform(
            scaleX: renderSize.width / max(srcNatural.width, 1),
            y: renderSize.height / max(srcNatural.height, 1)
        )
        // Compose baseStretch with zoom's viewport-space delta. CGAffineTransform's
        // .concatenating(_) is "self then arg", so this means
        // "stretch source to renderSize, then apply zoom as a viewport delta."
        func sourceTransform(zoom: Zoom) -> CGAffineTransform {
            baseStretch.concatenating(zoom.deltaTransform(viewportSize: renderSize))
        }
        let zoomKeyframes: [(time: Double, zoom: Zoom)] = clip.events.compactMap { e in
            if case let .zoom(z) = e.kind { return (e.recordTime, z) }
            return nil
        }
        let sourceLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoComp)
        // Stepwise per-keyframe setTransform (no setTransformRamp). AVPlayer's
        // built-in compositor on macOS 26 silently ignores setTransformRamp
        // calls on a layer instruction even though AVAssetExportSession
        // honors them — verified empirically by `LayerInstructionZoomTests`,
        // which passes via export with ramps but the live preview shows the
        // source un-zoomed. setTransform is honored on both paths, and
        // recording captures zoom at 60+ Hz during continuous gestures so
        // the stepwise transform changes on every preview frame and the
        // user perceives a smooth interpolation.
        if zoomKeyframes.isEmpty {
            sourceLayer.setTransform(sourceTransform(zoom: .identity), at: .zero)
        } else {
            var lastTime = CMTime(value: -1, timescale: 600)
            for kf in zoomKeyframes {
                let t = CMTime(seconds: kf.time, preferredTimescale: 600)
                // setTransform requires strictly increasing times; sub-tick
                // events from continuous gestures collapse to the same tick
                // at timescale 600 — keep the last one (closest to its
                // intended record-time) and drop the earlier dup.
                guard t > lastTime else { continue }
                sourceLayer.setTransform(sourceTransform(zoom: kf.zoom), at: t)
                lastTime = t
            }
        }

        // `addMutableTrack(preferredTrackID:)` doesn't always honor the
        // preferred ID — if there's a collision or constraint, it generates
        // a fresh one. Use the ACTUAL assigned trackIDs for both
        // `requiredSourceTrackIDs` and the layer instruction's source track,
        // otherwise AVPlayer either fails to load the webcam track or
        // renders the layer instruction against the wrong track.
        let actualSourceID = sourceVideoComp.trackID
        let actualWebcamID = webcamVideoComp.trackID
        NSLog("[Preview] track IDs: source=\(actualSourceID) webcam=\(actualWebcamID) (preferred was \(sourceTrackID)/\(webcamTrackID)) showPiP=\(clip.showPiP)")

        // Always build BOTH layer instructions during Phase A so a later
        // `setShowPiP` toggle can swap layerInstructions without re-loading the
        // webcam asset. Cheap: one naturalSize metadata load + transform math.
        let camNatural = try await webcamVideoTrack.load(.naturalSize)
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

        let videoComp = makeVideoComposition(
            renderSize: renderSize,
            clipDuration: clipDuration,
            sourceTrackID: actualSourceID,
            webcamTrackID: actualWebcamID,
            sourceLayer: sourceLayer,
            webcamLayer: webcamLayer,
            showPiP: clip.showPiP
        )

        let zoomEventCount = clip.events.reduce(into: 0) { acc, e in
            if case .zoom = e.kind { acc += 1 }
        }
        NSLog("[Preview] renderSize=\(renderSize) zoomEvents=\(zoomEventCount) totalEvents=\(clip.events.count)")
        NSLog("[Preview] build complete; AVPlayerItem ready (built-in compositor)")

        let item = AVPlayerItem(asset: comp)
        item.videoComposition = videoComp
        let entry = PreviewCacheEntry(
            player: AVPlayer(playerItem: item),
            renderSize: renderSize,
            clipDuration: clipDuration,
            sourceTrackID: actualSourceID,
            webcamTrackID: actualWebcamID,
            sourceLayer: sourceLayer,
            webcamLayer: webcamLayer
        )
        return entry
    }

    nonisolated static func makeVideoComposition(
        renderSize: CGSize,
        clipDuration: CMTime,
        sourceTrackID: CMPersistentTrackID,
        webcamTrackID: CMPersistentTrackID,
        sourceLayer: AVMutableVideoCompositionLayerInstruction,
        webcamLayer: AVMutableVideoCompositionLayerInstruction,
        showPiP: Bool
    ) -> AVMutableVideoComposition {
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst: PreviewInstruction
        if showPiP {
            inst = PreviewInstruction.make(
                sourceTrackID: sourceTrackID,
                webcamTrackID: webcamTrackID,
                compositionStart: .zero,
                clipDuration: clipDuration,
                segments: [],
                frozenFrames: [:],
                events: []
            )
            // AVFoundation layer order: first instruction is on TOP, so the
            // webcam (PiP) goes first to overlay the full-frame source.
            inst.layerInstructions = [webcamLayer, sourceLayer]
        } else {
            // PiP suppressed: drop the webcam track from `requiredSourceTrackIDs`
            // (via the invalid sentinel) so AVPlayer doesn't decode it, and
            // omit the webcam layer instruction.
            inst = PreviewInstruction.make(
                sourceTrackID: sourceTrackID,
                webcamTrackID: kCMPersistentTrackID_Invalid,
                compositionStart: .zero,
                clipDuration: clipDuration,
                segments: [],
                frozenFrames: [:],
                events: []
            )
            inst.layerInstructions = [sourceLayer]
        }
        videoComp.instructions = [inst]
        return videoComp
    }

    // MARK: - Helpers

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
}
