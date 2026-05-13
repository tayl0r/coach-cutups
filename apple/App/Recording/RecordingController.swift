import Foundation
import QuartzCore
import VideoCoachCore

/// Owns the in-memory event log for a single recording. A new
/// `RecordingController` instance is created per recording — `t0Seconds` is
/// stored as `let` and never mutated, so by construction every event's
/// timestamp is `clock() − t0Seconds`, which is monotonic.
///
/// Created on the main actor only after `CaptureSessionController.startRecording`
/// resolves (i.e. after the first sample buffer landed). The R / space /
/// arrow keys ignore presses until this controller exists.
@MainActor
final class RecordingController {
    /// Host-time PTS (seconds) of the first frame in the recording. Set once
    /// in `init`, read by every `appendXxx` to compute `recordTime`.
    let t0Seconds: Double

    /// Injected clock — production passes `CACurrentMediaTime`, tests pass a
    /// fake closure to advance time deterministically without sleeping.
    private let clock: () -> Double

    /// Captured event log, in append order. Monotonic by construction:
    /// each append uses `clock()`, which is itself monotonic (in production).
    private(set) var events: [CommentaryEvent] = []

    /// Last zoom value committed via `appendInitialZoom` / `appendZoom`. Held
    /// so `appendZoom` can emit an anchor keyframe at `t - 1ms` when the gap
    /// since the last capture exceeds 100ms.
    private var lastCapturedZoom: Zoom = .identity

    /// Record-time of the most recent zoom capture. Initialized to `-.infinity`
    /// so the first `appendInitialZoom` call (which sets it to 0) doesn't
    /// trigger an anchor on the first subsequent `appendZoom`.
    private var lastCaptureTime: Double = -.infinity

    init(t0Seconds: Double, clock: @escaping () -> Double = { CACurrentMediaTime() }) {
        self.t0Seconds = t0Seconds
        self.clock = clock
    }

    private var now: Double { clock() - t0Seconds }

    /// Append a `.play` event at the given host time WITH mpv's actual
    /// source playhead. Use this from the keystroke handler:
    ///   - capture `CACurrentMediaTime()` BEFORE calling `player.play()`
    ///     so mpv-internal latency doesn't push the recordTime late
    ///   - capture `player.timePos` at the same moment so the playback
    ///     segment-builder can anchor the freeze frame to where the
    ///     source ACTUALLY was, not a 1×-wall-clock estimate that drifts
    ///     when mpv lagged on a prior play/pause toggle
    func appendPlay(atHostTime hostTime: Double, sourceTime: Double) {
        events.append(.init(
            recordTime: hostTime - t0Seconds,
            kind: .play(sourceTime: sourceTime)
        ))
    }

    /// See `appendPlay(atHostTime:sourceTime:)`.
    func appendPause(atHostTime hostTime: Double, sourceTime: Double) {
        events.append(.init(
            recordTime: hostTime - t0Seconds,
            kind: .pause(sourceTime: sourceTime)
        ))
    }

    func appendSkip(delta: Double) {
        events.append(.init(recordTime: now, kind: .skip(delta: delta)))
    }

    func appendStroke(_ stroke: Stroke) {
        events.append(.init(recordTime: now, kind: .stroke(stroke)))
    }

    func appendClearAll() {
        events.append(.init(recordTime: now, kind: .clearAll))
    }

    /// Called at start-of-recording with the inherited zoom from
    /// `Workspace.currentZoom`. Always emits a `.zoom` event at `recordTime=0`
    /// so playback has a defined zoom value at the start of the clip.
    func appendInitialZoom(_ z: Zoom) {
        events.append(.init(recordTime: 0, kind: .zoom(z)))
        lastCapturedZoom = z
        lastCaptureTime = 0
    }

    /// Called at start-of-recording to anchor the event log with `.pause`
    /// at `recordTime=0`. Pinned to 0 (rather than `now`) because the
    /// async hop between `capture.startRecording` and `MainActor.run` can
    /// land at `now > 0`, which would insert a phantom leading `.play`
    /// segment that didn't actually happen. The `sourceTime` parameter
    /// pins the freeze to the exact mpv playhead at R-press (also
    /// captured in `clip.startSourceSeconds` — passing it here makes the
    /// .pause event self-contained for the segment-builder's anchoring
    /// path).
    func appendInitialPause(sourceTime: Double) {
        events.append(.init(recordTime: 0, kind: .pause(sourceTime: sourceTime)))
    }

    /// Append a zoom keyframe at the current recordTime (via injected clock).
    ///
    /// Captures every distinct zoom value the gesture pipeline produces.
    /// An earlier version of this method throttled to ~20Hz to cut the
    /// number of events stored on disk, but throttling is **visually
    /// load-bearing** during gesture-while-drawing: AVPlayer's
    /// `setTransform` is applied stepwise per recorded keyframe, so any
    /// keyframe gap on the recording side means the replay holds a stale
    /// transform during the gap. A user who pans-while-drawing-on-the-ball
    /// at 60Hz of gesture events sees the recording-time ball position
    /// (smooth ~60Hz mpv output) but the replay shows the ball at a
    /// keyframe-stepped position up to one throttle-interval behind —
    /// ending up with the drawing offset from the ball by the
    /// unmatched-pan delta. Dropping the throttle keeps every gesture
    /// event so replay matches recording exactly.
    ///
    /// Skips back-to-back identical zoom values: when the gesture
    /// pipeline fires but `Zoom.snapped().clamped()` collapses the
    /// committed value to the same notch as last time, there's nothing
    /// new to record. (This catches the common "user holds the snap
    /// notch" case at almost no runtime cost and keeps redundant
    /// keyframes off disk without affecting visual accuracy.)
    ///
    /// If the gap since the last distinct capture is > 100ms, emit an
    /// anchor keyframe at `(t - 1ms)` holding the previous value, so
    /// lerp lookup snaps instead of drifting backward through a quiet
    /// period.
    func appendZoom(_ z: Zoom) {
        let t = now
        if z == lastCapturedZoom { return }
        if t - lastCaptureTime > 0.1 {
            events.append(.init(recordTime: t - 0.001, kind: .zoom(lastCapturedZoom)))
        }
        events.append(.init(recordTime: t, kind: .zoom(z)))
        lastCapturedZoom = z
        lastCaptureTime = t
    }

    /// Returns the captured event log for assembly into a `Clip`.
    func finish() -> [CommentaryEvent] {
        events
    }
}
