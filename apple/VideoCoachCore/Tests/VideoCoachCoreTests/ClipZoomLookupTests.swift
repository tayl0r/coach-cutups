import XCTest
@testable import VideoCoachCore

final class ClipZoomLookupTests: XCTestCase {
    private func clip(_ zooms: [(Double, Zoom)]) -> Clip {
        Clip(
            name: "test",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 10,
            recordingFilename: "x.mov",
            events: zooms.map { CommentaryEvent(recordTime: $0.0, kind: .zoom($0.1)) },
            sortIndex: 0
        )
    }

    func test_no_zoom_events_returns_identity() {
        XCTAssertEqual(clip([]).zoomAt(recordTime: 0), .identity)
        XCTAssertEqual(clip([]).zoomAt(recordTime: 99), .identity)
    }

    func test_single_keyframe_holds_for_all_times() {
        let z = Zoom(scale: 2, panX: 0.1, panY: 0)
        let c = clip([(1.0, z)])
        XCTAssertEqual(c.zoomAt(recordTime: 0), z)
        XCTAssertEqual(c.zoomAt(recordTime: 0.5), z)
        XCTAssertEqual(c.zoomAt(recordTime: 5), z)
    }

    func test_lerp_at_midpoint_is_average() {
        let a = Zoom(scale: 1, panX: 0, panY: 0)
        let b = Zoom(scale: 3, panX: 0.2, panY: -0.1)
        let c = clip([(0, a), (2, b)])
        let mid = c.zoomAt(recordTime: 1.0)
        XCTAssertEqual(mid.scale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(mid.panX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(mid.panY, -0.05, accuracy: 1e-9)
    }

    func test_anchor_pattern_produces_snap() {
        // Anchor at t-1ms holding the previous value, new value at t.
        let oldZ = Zoom(scale: 1, panX: 0, panY: 0)
        let newZ = Zoom(scale: 2, panX: 0, panY: 0)
        let c = clip([
            (0, oldZ),
            (5.0 - 0.001, oldZ),  // anchor
            (5.0, newZ),
        ])
        // Just before t: still oldZ.
        XCTAssertEqual(c.zoomAt(recordTime: 4.99).scale, 1.0, accuracy: 1e-3)
        // Just after t: newZ.
        XCTAssertEqual(c.zoomAt(recordTime: 5.01).scale, 2.0, accuracy: 1e-3)
    }

    func test_before_first_event_returns_first_value() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        XCTAssertEqual(clip([(1, z)]).zoomAt(recordTime: 0), z)
    }

    func test_after_last_event_returns_last_value() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        XCTAssertEqual(clip([(1, z)]).zoomAt(recordTime: 99), z)
    }

    func test_ignores_non_zoom_events() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        let c = Clip(
            name: "x", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 10, recordingFilename: "x.mov",
            events: [
                CommentaryEvent(recordTime: 0.5, kind: .play),
                CommentaryEvent(recordTime: 1.0, kind: .zoom(z)),
                CommentaryEvent(recordTime: 1.5, kind: .pause),
            ],
            sortIndex: 0
        )
        XCTAssertEqual(c.zoomAt(recordTime: 1.5), z)
    }

    func test_unknown_kind_does_not_appear_in_zoom_lookup() {
        // The .unknown variant from Task 1.3's forward-compat decoder must
        // be treated as a non-zoom event — same as .play/.pause/etc.
        let unknown = CommentaryEvent(recordTime: 1.0, kind: .unknown)
        let zoom = CommentaryEvent(recordTime: 2.0, kind: .zoom(Zoom(scale: 2, panX: 0, panY: 0)))
        let c = Clip(name: "x", sourceIndex: 0, startSourceSeconds: 0,
                     recordingDuration: 5, recordingFilename: "x.mov",
                     events: [unknown, zoom], sortIndex: 0)
        XCTAssertEqual(c.zoomAt(recordTime: 3.0).scale, 2.0, accuracy: 1e-9)
    }
}
