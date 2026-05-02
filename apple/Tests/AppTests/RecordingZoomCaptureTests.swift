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
