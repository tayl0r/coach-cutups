import XCTest
@testable import VideoCoachCore

final class ZoomTests: XCTestCase {
    func test_identity_is_full_frame() {
        XCTAssertEqual(Zoom.identity.scale, 1.0)
        XCTAssertEqual(Zoom.identity.panX, 0)
        XCTAssertEqual(Zoom.identity.panY, 0)
    }

    func test_clamped_scale_floor_is_1() {
        XCTAssertEqual(Zoom(scale: 0.5, panX: 0, panY: 0).clamped().scale, 1.0)
    }

    func test_clamped_scale_ceiling_is_10() {
        XCTAssertEqual(Zoom(scale: 99, panX: 0, panY: 0).clamped().scale, 10.0)
    }

    func test_clamped_pan_is_zero_at_scale_1() {
        let z = Zoom(scale: 1.0, panX: 0.3, panY: -0.4).clamped()
        XCTAssertEqual(z.panX, 0)
        XCTAssertEqual(z.panY, 0)
    }

    func test_clamped_pan_constrains_visible_to_source_at_scale_2() {
        // At scale=2 the visible window is half the source. Maximum pan is
        // ±0.25 (so visible region edge sits at source edge).
        let limit = (2.0 - 1.0) / (2 * 2.0)
        let z = Zoom(scale: 2.0, panX: 1.0, panY: -1.0).clamped()
        XCTAssertEqual(z.panX, limit, accuracy: 1e-9)
        XCTAssertEqual(z.panY, -limit, accuracy: 1e-9)
    }

    func test_zoomedToCursor_keeps_source_point_under_cursor() {
        // Cursor at view-relative (0.75, 0.5) — right edge midline.
        // Start at identity; zoom to scale=2 toward the cursor.
        // The source point that was at (0.75, 0.5) before must still be at
        // (0.75, 0.5) in the new viewport.
        let before = Zoom.identity
        let cursor = CGPoint(x: 0.75, y: 0.5)
        let after = before.zoomedToCursor(newScale: 2.0, cursor: cursor)
        let sourcePointBefore = before.sourcePoint(atViewPosition: cursor)
        let sourcePointAfter = after.sourcePoint(atViewPosition: cursor)
        XCTAssertEqual(sourcePointBefore.x, sourcePointAfter.x, accuracy: 1e-9)
        XCTAssertEqual(sourcePointBefore.y, sourcePointAfter.y, accuracy: 1e-9)
    }

    func test_zoomedToCursor_preserves_cursor_pivot_through_chained_zooms() {
        let cursor = CGPoint(x: 0.3, y: 0.7)
        var z = Zoom.identity
        z = z.zoomedToCursor(newScale: 1.5, cursor: cursor)
        z = z.zoomedToCursor(newScale: 3.0, cursor: cursor)
        let src = z.sourcePoint(atViewPosition: cursor)
        let identitySrc = Zoom.identity.sourcePoint(atViewPosition: cursor)
        XCTAssertEqual(src.x, identitySrc.x, accuracy: 1e-9)
        XCTAssertEqual(src.y, identitySrc.y, accuracy: 1e-9)
    }
}
