import Foundation
import QuartzCore
import VideoCoachCore

/// Owns the in-memory event log for a single recording. A new
/// `RecordingController` instance is created per recording — `t0Seconds` is
/// stored as `let` and never mutated, so by construction every event's
/// timestamp is `CACurrentMediaTime() − t0Seconds`, which is monotonic.
///
/// Created on the main actor only after `CaptureSessionController.startRecording`
/// resolves (i.e. after the first sample buffer landed). The R / space /
/// arrow keys ignore presses until this controller exists.
@MainActor
final class RecordingController {
    /// Host-time PTS (seconds) of the first frame in the recording. Set once
    /// in `init`, read by every `appendXxx` to compute `recordTime`.
    let t0Seconds: Double

    /// Captured event log, in append order. Monotonic by construction:
    /// each append uses `CACurrentMediaTime()`, which is itself monotonic.
    private(set) var events: [CommentaryEvent] = []

    init(t0Seconds: Double) {
        self.t0Seconds = t0Seconds
    }

    private var now: Double { CACurrentMediaTime() - t0Seconds }

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

    /// Returns the captured event log for assembly into a `Clip`.
    func finish() -> [CommentaryEvent] {
        events
    }
}
