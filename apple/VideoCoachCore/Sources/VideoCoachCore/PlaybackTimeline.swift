import Foundation

public struct PlaybackSegment: Equatable, Sendable {
    public enum Kind: Sendable { case play, freeze }
    public var kind: Kind
    public var sourceStart: Double      // source-video offset at segment start
    public var outDuration: Double      // duration in the recording timeline (seconds)

    public init(kind: Kind, sourceStart: Double, outDuration: Double) {
        self.kind = kind
        self.sourceStart = sourceStart
        self.outDuration = outDuration
    }
}

public extension Clip {
    /// Source-video time the user was looking at, at the given record-time.
    /// Walks the event log applying play/pause/skip; stroke and clearAll do
    /// not affect source time. `.play(sourceTime:)` and `.pause(sourceTime:)`
    /// ANCHOR the cursor to the captured mpv timePos — overrides the
    /// 1×-wall-clock computation that drifts when mpv has play/pause
    /// latency or frame-boundary rounding.
    func sourceTime(atRecordTime t: Double) -> Double {
        var sourceTime = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        for ev in events where ev.recordTime <= t {
            sourceTime += (ev.recordTime - recordCursor) * rate
            recordCursor = ev.recordTime
            switch ev.kind {
            case .play(let anchor):
                rate = 1.0
                sourceTime = anchor
            case .pause(let anchor):
                rate = 0.0
                sourceTime = anchor
            case .skip(let d):    sourceTime += d
            case .stroke, .clearAll, .zoom, .unknown: break
            }
        }
        sourceTime += (t - recordCursor) * rate
        return sourceTime
    }

    func playbackSegments(sourceDuration: Double) -> [PlaybackSegment] {
        var segments: [PlaybackSegment] = []
        var sourceCursor = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        // sourceStart for a `.freeze` whose anchor lands at or past
        // sourceDuration must be pulled back inside the source bounds —
        // the freeze is realized as a 1-tick (1/600s) source slice at
        // `sourceStart`, and an out-of-bounds slice fails the
        // `insertTimeRange` call (or silently returns no samples), which
        // creates a hole in the source composition track and stalls
        // AVPlayer's compositor on every subsequent frame. 50ms back from
        // EOF is enough headroom that any realistic source FPS (1–120fps)
        // lands the 1-tick slice safely on a real sample, and is small
        // enough that the user can't perceive the difference vs. "the
        // actual last frame" when they FF past EOF.
        let freezeMaxSource = max(0, sourceDuration - 0.05)

        func emit(to recordEnd: Double) {
            let dur = recordEnd - recordCursor
            if dur <= 0 { return }

            if rate == 1.0 {
                // Source advances during this segment. If it would read
                // past sourceDuration, split into a `.play` tail covering
                // the available source plus a `.freeze` on the last source
                // frame for whatever record-time remains. Mirrors mpv:
                // playing past EOF holds the last decoded frame rather
                // than producing nothing.
                let availableSource = max(0, sourceDuration - sourceCursor)
                let playDur = min(dur, availableSource)
                if playDur > 0 {
                    segments.append(.init(
                        kind: .play, sourceStart: sourceCursor, outDuration: playDur
                    ))
                    sourceCursor += playDur
                }
                let freezeDur = dur - playDur
                if freezeDur > 0 {
                    segments.append(.init(
                        kind: .freeze,
                        sourceStart: min(sourceCursor, freezeMaxSource),
                        outDuration: freezeDur
                    ))
                }
            } else {
                segments.append(.init(
                    kind: .freeze,
                    sourceStart: min(sourceCursor, freezeMaxSource),
                    outDuration: dur
                ))
            }
            recordCursor = recordEnd
        }

        for ev in events {
            // Only state-changing events (play/pause/skip) split the
            // timeline into segments — those alter `rate` or
            // `sourceCursor`, so a new segment is needed to reflect the
            // new state. Zoom/stroke/clearAll/unknown events DON'T affect
            // segment math; emitting on them just produces a chain of
            // redundant micro-segments (kind+sourceStart+rate continuous
            // across the boundary). For a clip with a continuous-gesture
            // pinch firing ~60 zoom events per second, splitting on every
            // zoom would explode the segment count into the hundreds —
            // each one realized as an insertTimeRange+scaleTimeRange call
            // by ClipPreviewBuilder, which stalls AVPlayer's playback
            // compositor (manifests as "video freezes after first zoom,
            // audio keeps playing"). Zoom keyframes still reach the
            // compositor through `setTransform(at: recordTime)` on the
            // layer instruction — that path is independent of segment
            // boundaries.
            switch ev.kind {
            case .play(let anchor):
                emit(to: ev.recordTime)
                rate = 1.0
                sourceCursor = anchor
            case .pause(let anchor):
                emit(to: ev.recordTime)
                rate = 0.0
                sourceCursor = anchor
            case .skip(let d):
                emit(to: ev.recordTime)
                sourceCursor = max(0, min(sourceDuration, sourceCursor + d))
            case .stroke, .clearAll, .zoom, .unknown:
                break
            }
        }
        emit(to: recordingDuration)
        return segments
    }
}
