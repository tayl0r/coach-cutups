import XCTest
import VideoCoachCore

@MainActor
final class RecordingZoomCaptureTests: XCTestCase {
    func test_inherit_at_t0_emits_initial_zoom_event() {
        let rc = RecordingController(t0Seconds: 0)
        let initial = Zoom(scale: 2.0, panX: 0.1, panY: 0)
        rc.appendInitialZoom(initial)
        let events = rc.finish()
        XCTAssertEqual(events.count, 1)
        if case let .zoom(z) = events[0].kind {
            XCTAssertEqual(z, initial)
            XCTAssertEqual(events[0].recordTime, 0, accuracy: 1e-9)
        } else {
            XCTFail("Expected .zoom event")
        }
    }

    func test_continuous_capture_emits_keyframes_without_anchor() {
        // Two appends 50ms apart should produce just two keyframes (no anchor).
        var clockTime = 0.0
        let rc = RecordingController(t0Seconds: 0, clock: { clockTime })
        rc.appendInitialZoom(.identity)
        clockTime = 0.05
        rc.appendZoom(Zoom(scale: 1.5, panX: 0, panY: 0))
        clockTime = 0.10
        rc.appendZoom(Zoom(scale: 2.0, panX: 0, panY: 0))
        let zooms = rc.finish().filter { if case .zoom = $0.kind { return true } else { return false } }
        XCTAssertEqual(zooms.count, 3, "Expected 3 keyframes (initial + 2 continuous), got \(zooms.count)")
    }

    /// Every distinct zoom value the gesture pipeline produces must land
    /// in the events list — no time-based throttling. Throttling was
    /// removed because dropping keyframes during a gesture-while-drawing
    /// session means replay's stepwise `setTransform` lags mpv's smooth
    /// recording-time output, and any drawing made on top of a moving
    /// subject ends up offset by the dropped-pan delta. Storage savings
    /// from throttling were small (single-digit KB per long clip) and
    /// not worth the visual artifact.
    func test_appendZoom_capturesEveryDistinctValue_noTimeThrottling() {
        var clockTime = 0.0
        let rc = RecordingController(t0Seconds: 0, clock: { clockTime })
        rc.appendInitialZoom(.identity)
        // 100 calls at exactly 60Hz spacing — well below the previous
        // 50ms throttle window.
        for i in 1...100 {
            clockTime = Double(i) * (1.0 / 60.0)
            rc.appendZoom(Zoom(scale: 1.0 + Double(i) * 0.005, panX: 0, panY: 0))
        }
        let zooms = rc.finish().filter {
            if case .zoom = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(zooms.count, 101,
            "every distinct zoom value must pass through; got \(zooms.count) (1 initial + 100 distinct = 101 expected)")
    }

    /// Back-to-back identical zoom values are deduped. When the user
    /// holds a gesture at a snap notch, AppKit may keep firing events
    /// but `Zoom.snapped().clamped()` collapses them to the same value;
    /// recording every one would inflate project.json without benefit.
    /// (The anchor-after-quiet-period pattern still fires when the next
    /// distinct value lands more than 100ms after the prior distinct
    /// keyframe, so the resulting count includes that anchor.)
    func test_appendZoom_dedupsBackToBackIdenticalValues() {
        var clockTime = 0.0
        let rc = RecordingController(t0Seconds: 0, clock: { clockTime })
        rc.appendInitialZoom(.identity)
        clockTime = 0.05
        let z = Zoom(scale: 2.0, panX: 0.1, panY: 0)
        rc.appendZoom(z)
        // Same value 5 more times at increasing clock — should all dedup.
        for i in 1...5 {
            clockTime = 0.05 + Double(i) * 0.02
            rc.appendZoom(z)
        }
        // A different value lands 150ms after the last DISTINCT keyframe
        // — fires the anchor pattern.
        clockTime = 0.20
        rc.appendZoom(Zoom(scale: 2.5, panX: 0.1, panY: 0))
        let zooms = rc.finish().filter {
            if case .zoom = $0.kind { return true } else { return false }
        }
        // Expect: initial(identity) + first-distinct(z@0.05) + anchor(z@0.199) + second-distinct(2.5@0.20) = 4.
        XCTAssertEqual(zooms.count, 4,
            "expected 4 keyframes (initial + first-distinct + anchor-after-quiet + second-distinct); got \(zooms.count)")
    }

    func test_discrete_change_after_quiet_period_emits_anchor_keyframe() {
        var clockTime = 0.0
        let rc = RecordingController(t0Seconds: 0, clock: { clockTime })
        rc.appendInitialZoom(.identity)
        clockTime = 5.0
        rc.appendZoom(Zoom(scale: 2.0, panX: 0, panY: 0))
        let zooms = rc.finish().filter { if case .zoom = $0.kind { return true } else { return false } }
        XCTAssertEqual(zooms.count, 3)  // initial + anchor + new
        XCTAssertEqual(zooms[1].recordTime, 4.999, accuracy: 1e-6)
        if case let .zoom(z) = zooms[1].kind {
            XCTAssertEqual(z, .identity, "Anchor keyframe must hold the previous value")
        } else {
            XCTFail()
        }
    }
}
