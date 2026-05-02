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

    func appendPlay() {
        events.append(.init(recordTime: now, kind: .play))
    }

    func appendPause() {
        events.append(.init(recordTime: now, kind: .pause))
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

    /// Append a zoom keyframe at the current recordTime (via injected clock).
    /// If the gap since the last capture is > 100ms, emit an anchor keyframe
    /// at `(t - 1ms)` holding the previous value, so lerp lookup snaps
    /// instead of drifting backward through a quiet period.
    func appendZoom(_ z: Zoom) {
        let t = now
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
