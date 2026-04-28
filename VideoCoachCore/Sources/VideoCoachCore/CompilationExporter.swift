import AVFoundation
import CoreMedia
import Foundation

/// Errors raised by ``CompilationExporter``.
public enum CompilationExportError: Error, CustomStringConvertible {
    case missingClip(UUID)
    case missingSourceAsset(Int)
    case missingWebcamAsset(UUID)
    case noVideoTrackAdded
    case noAudioTrackAdded
    case exportSessionInitFailed(String)
    case exportFailed(status: AVAssetExportSession.Status, message: String)

    public var description: String {
        switch self {
        case .missingClip(let id):           return "missing clip for plan entry \(id)"
        case .missingSourceAsset(let i):     return "missing source asset for sourceIndex \(i)"
        case .missingWebcamAsset(let id):    return "missing webcam asset for clip \(id)"
        case .noVideoTrackAdded:             return "AVMutableComposition.addMutableTrack returned nil for video"
        case .noAudioTrackAdded:             return "AVMutableComposition.addMutableTrack returned nil for audio"
        case .exportSessionInitFailed(let m): return "AVAssetExportSession init failed: \(m)"
        case .exportFailed(let s, let m):    return "AVAssetExportSession failed (status=\(s.rawValue)): \(m)"
        }
    }
}

/// Drives a single end-to-end HEVC export from a ``CompilationPlan``.
///
/// Owns the construction of the `AVMutableComposition`, the
/// `AVMutableVideoComposition` (with our ``CompilationCompositor`` and
/// per-clip ``CompilationInstruction``s), and the `AVMutableAudioMix` (with
/// 5ms boundary ramps on the source-audio track per design § "Audio").
///
/// `export(...)` runs to completion and throws on failure. Callers that want
/// progress observation should call ``progress(of:)`` in parallel after
/// retrieving the underlying `AVAssetExportSession` — but for v1 the API
/// hides the session and the smoke test does not need progress.
///
/// **Quality mapping caveat (v1):** the `quality` argument is currently
/// ignored — `AVAssetExportSession` presets do not expose direct bitrate
/// control. The bitrate table in ``ExportSettings`` is the *target* the
/// reader/writer fallback (Task 9.6) would honor. For now the preset is
/// chosen purely from `resolution`. Revisit when 9.6 is implemented or when
/// we promote a Quality-aware preset map.
public actor CompilationExporter {
    public init() {}

    /// Run an export to completion. Throws ``CompilationExportError`` on any
    /// failure. The output `.mp4` lives at `outputURL` — caller decides the
    /// path (which is also the file the AVAssetExportSession writes to).
    public func export(
        plan: CompilationPlan,
        clipsByID: [UUID: Clip],
        sourceAssets: [Int: AVURLAsset],
        clipWebcamAssets: [UUID: AVURLAsset],
        outputURL: URL,
        resolution: Resolution,
        quality: Quality,
        sourceVolume: Double,
        commentaryVolume: Double
    ) async throws {
        // ── Step 1: Build the AVMutableComposition.
        //
        // We let AVFoundation auto-assign track IDs via
        // `kCMPersistentTrackID_Invalid` and capture the actual `trackID`
        // each call returns. Explicit `preferredTrackID:` values used to work
        // (the design doc spec'd 1, 2, 1000+i, 2000+i) but on macOS 26
        // `addMutableTrack` returns nil for some explicit-ID calls — same
        // family of regression we hit with `requiredSourceTrackIDs`. Threading
        // the *assigned* IDs through is the modern Apple-recommended pattern
        // and dodges the issue entirely.
        let comp = AVMutableComposition()

        guard let sourceVideoTrack = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompilationExportError.noVideoTrackAdded
        }
        let sourceVideoTrackID = sourceVideoTrack.trackID

        guard let sourceAudioTrack = comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompilationExportError.noAudioTrackAdded
        }
        let sourceAudioTrackID = sourceAudioTrack.trackID

        // Per-clip webcam video + mic audio. Tracks-by-entry-index plus their
        // assigned IDs (so we can wire the AVMutableAudioMixInputParameters
        // and the CompilationInstruction with the real IDs).
        var webcamTracksByEntry: [Int: AVMutableCompositionTrack] = [:]
        var webcamTrackIDByEntry: [Int: CMPersistentTrackID] = [:]
        var micTracksByEntry: [Int: AVMutableCompositionTrack] = [:]
        var micTrackIDByEntry: [Int: CMPersistentTrackID] = [:]

        // Tracks the per-track existence so we know whether to produce
        // AVMutableAudioMixInputParameters for the mic track. (If the webcam
        // recording lacked audio we still added the track but inserted nothing,
        // which is fine — audio mix parameters with no time range simply do
        // nothing.)
        var hasSourceAudioInsert = false

        for entry in plan.entries {
            guard let clip = clipsByID[entry.clipID] else {
                throw CompilationExportError.missingClip(entry.clipID)
            }
            guard let sourceAsset = sourceAssets[clip.sourceIndex] else {
                throw CompilationExportError.missingSourceAsset(clip.sourceIndex)
            }
            guard let webcamAsset = clipWebcamAssets[clip.id] else {
                throw CompilationExportError.missingWebcamAsset(clip.id)
            }

            let sourceVideoSrc = try await sourceAsset.primaryVideoTrack()
            let sourceAudioSrc = try await sourceAsset.optionalAudioTrack()

            // Walk the entry's segments. For each `.play` segment, insert the
            // matching slice of source video (and audio if present) at the
            // segment's output offset. Skip `.freeze` segments — the
            // compositor renders those from cache.
            var outCursor = entry.compositionStart
            for segment in entry.segments {
                let outDur = segment.outDuration
                defer { outCursor += outDur }
                guard segment.kind == .play else { continue }
                let srcRange = CMTimeRange(
                    start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: outDur, preferredTimescale: 600)
                )
                let outStart = CMTime(seconds: outCursor, preferredTimescale: 600)
                try sourceVideoTrack.insertTimeRange(srcRange, of: sourceVideoSrc, at: outStart)
                if let sourceAudioSrc {
                    try sourceAudioTrack.insertTimeRange(srcRange, of: sourceAudioSrc, at: outStart)
                    hasSourceAudioInsert = true
                }
            }

            // Per-clip webcam: continuous insert from t=0 of the webcam asset
            // for the full clip's recording duration, placed at the clip's
            // composition start. The webcam recording starts when the user
            // hits Record, so its t=0 aligns with the clip's recordTime=0.
            let webcamVideoSrc = try await webcamAsset.primaryVideoTrack()
            let webcamAudioSrc = try await webcamAsset.optionalAudioTrack()

            guard let webcamTrack = comp.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CompilationExportError.noVideoTrackAdded
            }
            webcamTracksByEntry[entry.indexInOutput] = webcamTrack
            webcamTrackIDByEntry[entry.indexInOutput] = webcamTrack.trackID

            let clipDuration = CMTime(seconds: entry.recordingDuration, preferredTimescale: 600)
            let clipStart = CMTime(seconds: entry.compositionStart, preferredTimescale: 600)
            // Clamp the webcam read range to the actual webcam asset duration
            // — guards against a recording that ended slightly short of
            // `recordingDuration` (e.g. capture stopped a frame early).
            let webcamAvailable = try await webcamAsset.load(.duration)
            let webcamReadDuration = CMTimeMinimum(clipDuration, webcamAvailable)
            try webcamTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: webcamReadDuration),
                of: webcamVideoSrc,
                at: clipStart
            )

            if let webcamAudioSrc {
                guard let micTrack = comp.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw CompilationExportError.noAudioTrackAdded
                }
                micTracksByEntry[entry.indexInOutput] = micTrack
                micTrackIDByEntry[entry.indexInOutput] = micTrack.trackID
                try micTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: webcamReadDuration),
                    of: webcamAudioSrc,
                    at: clipStart
                )
            }
        }

        // ── Step 2: Build the AVMutableVideoComposition.
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = CompilationCompositor.self
        videoComp.renderSize = try await Self.renderSize(
            for: resolution,
            sourceAssets: sourceAssets
        )
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [CompilationInstruction] = []
        instructions.reserveCapacity(plan.entries.count)
        for entry in plan.entries {
            // Safe: we already verified clipsByID has each entry above.
            let clip = clipsByID[entry.clipID]!
            let strokes: [Stroke] = clip.events.compactMap { event in
                if case .stroke(let s) = event.kind { return s }
                return nil
            }
            // Slim event list: only `.stroke` and `.clearAll` — what the
            // compositor's visibleStrokes(in:atRecordTime:) helper needs.
            // Drop `.play`/`.pause`/`.skip` (the compositor doesn't replay
            // those — segment-driven freeze logic handles them).
            let drawingEvents: [CommentaryEvent] = clip.events.filter { event in
                switch event.kind {
                case .stroke, .clearAll: return true
                case .play, .pause, .skip: return false
                }
            }
            let textBarLine = "\(entry.indexInOutput + 1)/\(plan.entries.count), \(clip.name), \(clip.tags.joined(separator: " "))"
            // Use the AVFoundation-assigned trackIDs captured above. The
            // webcam ID may be missing if some pathological per-clip flow
            // ran without inserting a webcam track — fall back to the
            // assigned source ID so the compositor's `requiredSourceTrackIDs`
            // doesn't reference a nonexistent track.
            let webcamID = webcamTrackIDByEntry[entry.indexInOutput] ?? sourceVideoTrackID
            let inst = CompilationInstruction.make(
                clipIndex: entry.indexInOutput,
                indexInOutput: entry.indexInOutput,
                totalClips: plan.entries.count,
                compositionStart: CMTime(seconds: entry.compositionStart, preferredTimescale: 600),
                clipDuration: CMTime(seconds: entry.recordingDuration, preferredTimescale: 600),
                sourceTrackID: sourceVideoTrackID,
                webcamTrackID: webcamID,
                segments: entry.segments,
                strokes: strokes,
                events: drawingEvents,
                textBarLine: textBarLine
            )
            instructions.append(inst)
        }
        videoComp.instructions = instructions

        // ── Step 3: Build the AVMutableAudioMix.
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        if hasSourceAudioInsert {
            let sourceParams = AVMutableAudioMixInputParameters(track: sourceAudioTrack)
            sourceParams.trackID = sourceAudioTrackID
            sourceParams.setVolume(Float(sourceVolume), at: .zero)

            // Boundary ramps: at every interior `.play↔.freeze` transition,
            // insert a 5ms fade-out (pre-T) and 5ms fade-in (post-T). The
            // ramp-out start is clamped at zero — without this, a near-zero
            // boundary would produce a negative-start range that AVFoundation
            // handles inconsistently across macOS versions.
            let rampDur = CMTime(seconds: 0.005, preferredTimescale: 600)
            for entry in plan.entries {
                var outCursor = entry.compositionStart
                for (i, segment) in entry.segments.enumerated() {
                    if i > 0 {
                        // Boundary at outCursor (the start of this segment).
                        let T = CMTime(seconds: outCursor, preferredTimescale: 600)
                        let preStart = CMTimeMaximum(.zero, T - rampDur)
                        let preDur = T - preStart
                        if preDur > .zero {
                            sourceParams.setVolumeRamp(
                                fromStartVolume: Float(sourceVolume),
                                toEndVolume: 0,
                                timeRange: CMTimeRange(start: preStart, duration: preDur)
                            )
                        }
                        if rampDur > .zero {
                            sourceParams.setVolumeRamp(
                                fromStartVolume: 0,
                                toEndVolume: Float(sourceVolume),
                                timeRange: CMTimeRange(start: T, duration: rampDur)
                            )
                        }
                    }
                    outCursor += segment.outDuration
                }
            }

            inputParameters.append(sourceParams)
        }

        // Per-clip mic audio: flat volume, no ramps (mic plays continuously).
        for (entryIndex, micTrack) in micTracksByEntry {
            let micParams = AVMutableAudioMixInputParameters(track: micTrack)
            micParams.trackID = micTrackIDByEntry[entryIndex] ?? micTrack.trackID
            micParams.setVolume(Float(commentaryVolume), at: .zero)
            inputParameters.append(micParams)
        }
        audioMix.inputParameters = inputParameters

        // ── Step 4: Configure and run the AVAssetExportSession.
        let presetName = Self.presetName(for: resolution, quality: quality)
        guard let exportSession = AVAssetExportSession(
            asset: comp,
            presetName: presetName
        ) else {
            throw CompilationExportError.exportSessionInitFailed("preset=\(presetName)")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComp
        exportSession.audioMix = audioMix

        await exportSession.export()

        if exportSession.status != .completed {
            throw CompilationExportError.exportFailed(
                status: exportSession.status,
                message: exportSession.error?.localizedDescription ?? "unknown"
            )
        }
    }

    /// Polls the given session's `progress` at 5Hz and emits the values to
    /// the returned stream until the session completes/fails/cancels.
    /// `nonisolated` so the caller can await the stream without serializing
    /// through the actor's executor.
    public nonisolated func progress(of session: AVAssetExportSession) -> AsyncStream<Float> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let status = session.status
                    let value = session.progress
                    continuation.yield(value)
                    if status == .completed || status == .failed || status == .cancelled {
                        continuation.finish()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // 5Hz
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    /// Pick an `AVAssetExportPreset*` name from the (resolution, quality) pair.
    /// `quality` is currently a no-op (see type doc); kept in the signature so
    /// the call site is forward-compatible with Task 9.6's writer-based path.
    private static func presetName(for resolution: Resolution, quality: Quality) -> String {
        // Available HEVC presets on macOS 14 are 1920x1080 / 3840x2160 /
        // 4320x2160 / 7680x4320 / HighestQuality (no 1280x720). For 720p we
        // therefore use the 1080p preset and rely on `videoComposition.renderSize`
        // to dictate the actual output dimensions — confirmed equivalent in the
        // 9.0 spike (which exported a 64x64 source at 1920x1080 renderSize).
        switch resolution {
        case .source, .r1080, .r720:
            return AVAssetExportPresetHEVC1920x1080
        }
    }

    /// Compute the export's `renderSize`. For non-`.source` resolutions, take
    /// it from the table. For `.source`, use the natural dimensions of the
    /// first source asset's primary video track (or fall back to 1920x1080
    /// if the table somehow has no entry — paranoia).
    private static func renderSize(
        for resolution: Resolution,
        sourceAssets: [Int: AVURLAsset]
    ) async throws -> CGSize {
        if resolution == .source, let first = sourceAssets[0] {
            let track = try await first.primaryVideoTrack()
            let natural = try await track.load(.naturalSize)
            // Use the absolute size — track transforms might encode rotation
            // but for v1 our recordings are landscape-only.
            return CGSize(width: abs(natural.width), height: abs(natural.height))
        }
        let p = ExportSettings.pixelSize(resolution: resolution)
        return CGSize(width: p.width, height: p.height)
    }
}
