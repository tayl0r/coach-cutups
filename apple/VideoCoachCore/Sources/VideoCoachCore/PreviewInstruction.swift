import AVFoundation
import CoreMedia
import Foundation

/// Per-clip context for the Mode C preview compositor.
///
/// AVFoundation instantiates `PreviewCompositor` itself (via
/// `customVideoCompositorClass`) and calls `startRequest(_:)` once per output
/// frame. Per-clip metadata (the clip's playback segments and its pre-decoded
/// freeze frames) rides on this `AVMutableVideoCompositionInstruction` subclass
/// — AVFoundation passes the subclass through unchanged; the compositor casts
/// it on the way in.
///
/// Mode C builds a single-clip composition per preview, so `clipIndex` is
/// always `0`, but we keep the field to mirror `CompilationInstruction` for
/// readability.
///
/// `requiredSourceTrackIDs` is `readonly` on the parent class — we override
/// with private backing storage, the same pattern `CompilationInstruction`
/// uses.
public final class PreviewInstruction: AVMutableVideoCompositionInstruction, @unchecked Sendable {
    public var clipIndex: Int = 0
    public var sourceTrackID: CMPersistentTrackID = 1
    public var webcamTrackID: CMPersistentTrackID = 1000
    public var clipCompositionStart: CMTime = .zero
    public var segments: [PlaybackSegment] = []
    /// Pre-decoded frozen frame keyed by segment index where
    /// `segments[i].kind == .freeze`. Built once at composition build time;
    /// never mutated at render time. This lets backward scrubbing across a
    /// freeze segment display the correct frame instead of a stale runtime
    /// cache (which AVPlayer can poison with out-of-order seek requests).
    public var frozenFrames: [Int: CVPixelBuffer] = [:]
    /// Recording-time events for the clip in this instruction. The compositor
    /// reads `.zoom` keyframes off this array to apply per-frame zoom delta;
    /// other event kinds are ignored at composite time. Default `[]` keeps
    /// existing call sites compiling unchanged with identity-zoom behavior.
    public var events: [CommentaryEvent] = []

    private var _requiredSourceTrackIDs: [NSValue] = []
    public override var requiredSourceTrackIDs: [NSValue] {
        get { _requiredSourceTrackIDs }
    }

    /// Builder helper. Always prefer this over the bare initializer so that
    /// `timeRange` and `requiredSourceTrackIDs` are guaranteed set.
    public static func make(
        clipIndex: Int = 0,
        sourceTrackID: CMPersistentTrackID = 1,
        webcamTrackID: CMPersistentTrackID = 1000,
        compositionStart: CMTime,
        clipDuration: CMTime,
        segments: [PlaybackSegment],
        frozenFrames: [Int: CVPixelBuffer],
        events: [CommentaryEvent] = []
    ) -> PreviewInstruction {
        let i = PreviewInstruction()
        i.timeRange = CMTimeRange(start: compositionStart, duration: clipDuration)
        i._requiredSourceTrackIDs = [
            NSNumber(value: sourceTrackID),
            NSNumber(value: webcamTrackID),
        ]
        i.clipIndex = clipIndex
        i.sourceTrackID = sourceTrackID
        i.webcamTrackID = webcamTrackID
        i.clipCompositionStart = compositionStart
        i.segments = segments
        i.frozenFrames = frozenFrames
        i.events = events
        return i
    }

    /// Returns the index of the segment containing `t` (record-time, in
    /// seconds local to the clip). Walks `outDuration`s; clamps to the last
    /// segment if `t` falls past the walked range.
    public func segmentIndex(forRecordTime t: Double) -> Int {
        var elapsed = 0.0
        for (i, seg) in segments.enumerated() {
            let next = elapsed + seg.outDuration
            if t < next { return i }
            elapsed = next
        }
        return max(0, segments.count - 1)
    }
}
