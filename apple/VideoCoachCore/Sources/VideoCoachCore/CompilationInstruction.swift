import AVFoundation
import CoreMedia
import Foundation

/// Per-clip context for the export compositor.
///
/// AVFoundation instantiates `CompilationCompositor` itself (via
/// `customVideoCompositorClass`) and calls `startRequest(_:)` once per output
/// frame. There is no per-clip `init` to thread context through, so the
/// canonical pattern is to **subclass `AVMutableVideoCompositionInstruction`**
/// and stash per-clip data on the instruction. AVFoundation passes the
/// subclass through unchanged; the compositor casts it on the way in.
///
/// CRITICAL: every instance MUST have `timeRange` set to the clip's
/// compositional range AND `requiredSourceTrackIDs` populated — otherwise
/// AVFoundation rejects the composition or skips frames. Use ``make(...)``
/// rather than the bare initializer to ensure both are set.
///
/// `requiredSourceTrackIDs` is `readonly` on the parent class
/// (`AVMutableVideoCompositionInstruction` only exposes a getter — the
/// matching `requiredSourceSampleDataTrackIDs` is the only `copy`-mutable
/// kin). We override the property with our own backing storage so callers
/// can still configure which tracks AVFoundation must hand to the compositor
/// per `request.sourceFrame(byTrackID:)`.
public final class CompilationInstruction: AVMutableVideoCompositionInstruction, @unchecked Sendable {
    public var clipIndex: Int = 0
    public var indexInOutput: Int = 0
    public var totalClips: Int = 0
    public var sourceTrackID: CMPersistentTrackID = 1
    public var webcamTrackID: CMPersistentTrackID = 1000
    public var clipCompositionStart: CMTime = .zero
    public var segments: [PlaybackSegment] = []
    public var strokes: [Stroke] = []
    /// Pre-filtered `.stroke` and `.clearAll` events with `recordTime` set in
    /// the clip's local timeline. The compositor synthesizes a throwaway
    /// `Clip` from these to call the shared `visibleStrokes(in:atRecordTime:)`
    /// helper unchanged (which needs the events list to honor `.clearAll`).
    public var events: [CommentaryEvent] = []
    public var textBarLine: String = ""
    public var showPiP: Bool = true

    private var _requiredSourceTrackIDs: [NSValue] = []
    public override var requiredSourceTrackIDs: [NSValue] {
        get { _requiredSourceTrackIDs }
    }

    /// Builder helper — always prefer this over the bare initializer so that
    /// `timeRange` and `requiredSourceTrackIDs` are guaranteed set.
    public static func make(
        clipIndex: Int,
        indexInOutput: Int,
        totalClips: Int,
        compositionStart: CMTime,
        clipDuration: CMTime,
        sourceTrackID: CMPersistentTrackID = 1,
        webcamTrackID: CMPersistentTrackID,
        showPiP: Bool = true,
        segments: [PlaybackSegment],
        strokes: [Stroke],
        events: [CommentaryEvent],
        textBarLine: String
    ) -> CompilationInstruction {
        let i = CompilationInstruction()
        i.timeRange = CMTimeRange(start: compositionStart, duration: clipDuration)
        // requiredSourceTrackIDs is `[NSValue]`-typed; NSNumber is the
        // conventional boxing for CMPersistentTrackID. Passing raw Int32s
        // won't compile.
        //
        // Webcam stays in the required-track list even when `showPiP`
        // is false. `CompilationExporter` always inserts the webcam track
        // (so a hidden PiP can be re-enabled later by flipping the flag);
        // the compositor reads `showPiP` and skips the draw without
        // touching the composition shape. Asymmetric with
        // `PreviewInstruction.make`, which drops the webcam ID when
        // suppressed because the preview builder DOES omit the layer
        // instruction entirely.
        i._requiredSourceTrackIDs = [
            NSNumber(value: sourceTrackID),
            NSNumber(value: webcamTrackID),
        ]
        i.clipIndex = clipIndex
        i.indexInOutput = indexInOutput
        i.totalClips = totalClips
        i.sourceTrackID = sourceTrackID
        i.webcamTrackID = webcamTrackID
        i.clipCompositionStart = compositionStart
        i.segments = segments
        i.strokes = strokes
        i.events = events
        i.textBarLine = textBarLine
        i.showPiP = showPiP
        return i
    }
}
