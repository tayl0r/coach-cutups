import AVFoundation
import CoreMedia
import Foundation

/// Errors raised by ``CompilationExporter``.
public enum CompilationExportError: Error, CustomStringConvertible, LocalizedError {
    case missingClip(UUID)
    case missingSourceAsset(Int)
    case missingWebcamAsset(UUID)
    case noVideoTrackAdded(site: String)
    case noAudioTrackAdded(site: String)
    case exportSessionInitFailed(String)
    case exportFailed(status: AVAssetExportSession.Status, message: String)

    public var description: String {
        switch self {
        case .missingClip(let id):              return "missing clip for plan entry \(id)"
        case .missingSourceAsset(let i):        return "missing source asset for sourceIndex \(i)"
        case .missingWebcamAsset(let id):       return "missing webcam asset for clip \(id)"
        case .noVideoTrackAdded(let site):      return "AVMutableComposition.addMutableTrack returned nil for video (\(site))"
        case .noAudioTrackAdded(let site):      return "AVMutableComposition.addMutableTrack returned nil for audio (\(site))"
        case .exportSessionInitFailed(let m):   return "AVAssetExportSession init failed: \(m)"
        case .exportFailed(let s, let m):       return "AVAssetExportSession failed (status=\(s.rawValue)): \(m)"
        }
    }

    // LocalizedError makes `error.localizedDescription` show the message above
    // instead of the cryptic "CompilationExportError error N".
    public var errorDescription: String? { description }
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
        Log.export.info("export start: entries=\(plan.entries.count) total=\(plan.totalDurationSeconds, format: .fixed(precision: 2))s resolution=\(resolution.rawValue) quality=\(quality.rawValue) output=\(outputURL.lastPathComponent)")

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
            throw CompilationExportError.noVideoTrackAdded(site: "source video")
        }
        let sourceVideoTrackID = sourceVideoTrack.trackID

        guard let sourceAudioTrack = comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompilationExportError.noAudioTrackAdded(site: "source audio")
        }
        let sourceAudioTrackID = sourceAudioTrack.trackID
        Log.export.info("composition tracks added: sourceVideo=\(sourceVideoTrackID) sourceAudio=\(sourceAudioTrackID)")

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

        // Single CMTime cursor across ALL entries. The plan's
        // `entry.compositionStart` is a Double cumulative sum; converting it
        // per-entry to CMTime introduces sub-millisecond drift between the
        // previous entry's actual end-of-segments cursor and the next entry's
        // declared start, leaving phantom empty inter-clip segments that
        // AVFoundation rejects ("video could not be composed"). We track the
        // cursor in CMTime end-to-end so source video, webcam, and instruction
        // boundaries all land at the exact same composition time.
        var compositionCursor = CMTime.zero
        // Per-entry actual CMTime [start, duration] — used by Step 2 (instruction
        // build) and Step 3 (audio mix ramps) so they reference the same exact
        // boundaries the source video track sees.
        var entryRangesCMTime: [Int: CMTimeRange] = [:]

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
            let entryStart = compositionCursor
            for segment in entry.segments {
                let segDur = CMTime(seconds: segment.outDuration, preferredTimescale: 600)
                defer { compositionCursor = compositionCursor + segDur }
                guard segment.kind == .play else { continue }
                let srcRange = CMTimeRange(
                    start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                    duration: segDur
                )
                try sourceVideoTrack.insertTimeRange(srcRange, of: sourceVideoSrc, at: compositionCursor)
                if let sourceAudioSrc {
                    try sourceAudioTrack.insertTimeRange(srcRange, of: sourceAudioSrc, at: compositionCursor)
                    hasSourceAudioInsert = true
                }
            }
            let entryDuration = compositionCursor - entryStart
            entryRangesCMTime[entry.indexInOutput] = CMTimeRange(start: entryStart, duration: entryDuration)

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
                throw CompilationExportError.noVideoTrackAdded(
                    site: "webcam clip \(entry.indexInOutput)"
                )
            }
            webcamTracksByEntry[entry.indexInOutput] = webcamTrack
            webcamTrackIDByEntry[entry.indexInOutput] = webcamTrack.trackID
            Log.export.info("entry \(entry.indexInOutput): webcam track \(webcamTrack.trackID) (segments=\(entry.segments.count) recordingDur=\(entry.recordingDuration, format: .fixed(precision: 2))s)")

            // Use the same CMTime range we computed from the source-video
            // inserts so the webcam track's range is identical — no
            // sub-millisecond mismatch between video and webcam tracks.
            let clipRange = entryRangesCMTime[entry.indexInOutput]!
            let clipStart = clipRange.start
            let clipDuration = clipRange.duration
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
                    throw CompilationExportError.noAudioTrackAdded(
                        site: "mic clip \(entry.indexInOutput)"
                    )
                }
                micTracksByEntry[entry.indexInOutput] = micTrack
                micTrackIDByEntry[entry.indexInOutput] = micTrack.trackID
                Log.export.info("entry \(entry.indexInOutput): mic track \(micTrack.trackID)")
                try micTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: webcamReadDuration),
                    of: webcamAudioSrc,
                    at: clipStart
                )
            }
        }

        // ── Step 2: Build the AVMutableVideoComposition.
        let compDuration = comp.duration
        Log.export.info("composition built: duration=\(compDuration.seconds, format: .fixed(precision: 3))s tracks=\(comp.tracks.count)")

        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = CompilationCompositor.self
        videoComp.renderSize = try await Self.renderSize(
            for: resolution,
            sourceAssets: sourceAssets
        )
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        Log.export.info("video composition: renderSize=\(videoComp.renderSize.width, format: .fixed(precision: 0))x\(videoComp.renderSize.height, format: .fixed(precision: 0)) frameDuration=\(videoComp.frameDuration.seconds, format: .fixed(precision: 4))s")

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
                case .play, .pause, .skip, .zoom, .unknown: return false
                }
            }
            // Bottom-bar info: `<n> / <total> | <name> | tag1, tag2, tag3`.
            // Empty segments collapse — a clip with no tags just shows
            // `<n> / <total> | <name>`; a name-less + tag-less clip just
            // shows `<n> / <total>`. No trailing pipes.
            let position = "\(entry.indexInOutput + 1) / \(plan.entries.count)"
            var parts: [String] = [position]
            let trimmedName = clip.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty { parts.append(trimmedName) }
            if !clip.tags.isEmpty { parts.append(clip.tags.joined(separator: ", ")) }
            let textBarLine = parts.joined(separator: " | ")
            // Use the AVFoundation-assigned trackIDs captured above. The
            // webcam ID may be missing if some pathological per-clip flow
            // ran without inserting a webcam track — fall back to the
            // assigned source ID so the compositor's `requiredSourceTrackIDs`
            // doesn't reference a nonexistent track.
            let webcamID = webcamTrackIDByEntry[entry.indexInOutput] ?? sourceVideoTrackID
            // Reuse the exact CMTime range we computed during the source-video
            // insertion so the instruction's timeRange aligns with the
            // underlying tracks at the bit level — no Double-conversion drift.
            let entryRange = entryRangesCMTime[entry.indexInOutput]!
            let inst = CompilationInstruction.make(
                clipIndex: entry.indexInOutput,
                indexInOutput: entry.indexInOutput,
                totalClips: plan.entries.count,
                compositionStart: entryRange.start,
                clipDuration: entryRange.duration,
                sourceTrackID: sourceVideoTrackID,
                webcamTrackID: webcamID,
                segments: entry.segments,
                strokes: strokes,
                events: drawingEvents,
                textBarLine: textBarLine
            )
            instructions.append(inst)
            Log.export.info("instruction \(entry.indexInOutput): timeRange=[\(inst.timeRange.start.seconds, format: .fixed(precision: 3))..\((inst.timeRange.start + inst.timeRange.duration).seconds, format: .fixed(precision: 3))] required=[\(sourceVideoTrackID), \(webcamID)]")
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
                // Start each entry's segment walk from the SAME CMTime the
                // source-video insertion used (entryRangesCMTime[i].start),
                // so ramp boundaries land exactly on segment edges.
                var outCursor = entryRangesCMTime[entry.indexInOutput]?.start
                    ?? CMTime(seconds: entry.compositionStart, preferredTimescale: 600)
                for (i, segment) in entry.segments.enumerated() {
                    let segDur = CMTime(seconds: segment.outDuration, preferredTimescale: 600)
                    if i > 0 {
                        // Boundary at outCursor (the start of this segment).
                        let T = outCursor
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
                    outCursor = outCursor + segDur
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

        Log.export.info("starting AVAssetExportSession (preset=\(presetName), fileType=mp4)")
        await exportSession.export()

        if exportSession.status != .completed {
            // The default `localizedDescription` on AVFoundation export errors
            // is "Operation Stopped" — useless. Dig into the underlying NSError
            // for the real cause: domain + code + userInfo (often contains
            // NSUnderlyingError with a deeper FigError code).
            let detail = Self.describe(exportSession.error)
            Log.export.error("export failed: status=\(exportSession.status.rawValue) detail=\(detail)")
            throw CompilationExportError.exportFailed(
                status: exportSession.status,
                message: detail
            )
        }
        Log.export.info("export completed successfully")
    }

    /// Walks an `NSError`'s userInfo + underlying-error chain to produce a
    /// debuggable string. AVFoundation's top-level `localizedDescription` is
    /// usually generic ("Operation Stopped"); the real cause lives in
    /// `NSUnderlyingError`'s domain/code (commonly `NSOSStatusErrorDomain`
    /// with a four-char code) and userInfo keys like `NSDebugDescription`.
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no error attached to session" }
        let ns = error as NSError
        var parts: [String] = []
        parts.append("\(ns.domain) \(ns.code)")
        parts.append(ns.localizedDescription)
        if let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String {
            parts.append("debug=\(debug)")
        }
        if let failureReason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            parts.append("reason=\(failureReason)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=[\(underlying.domain) \(underlying.code): \(underlying.localizedDescription)]")
            if let debug = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                parts.append("underlying.debug=\(debug)")
            }
        }
        return parts.joined(separator: " | ")
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
