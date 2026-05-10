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

    // MARK: - transform tests

    func test_identity_transform_is_letterbox_fit() {
        let src = CGSize(width: 1920, height: 1080)
        let dst = CGSize(width: 1920, height: 1080)
        let t = Zoom.identity.transform(sourceSize: src, destSize: dst)
        // No scaling change, no offset.
        XCTAssertEqual(t.a, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.d, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.tx, 0, accuracy: 1e-9)
        XCTAssertEqual(t.ty, 0, accuracy: 1e-9)
    }

    func test_scale_2_centers_zoomed_source_in_dest() {
        let src = CGSize(width: 1000, height: 500)
        let dst = CGSize(width: 1000, height: 500)
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        let t = z.transform(sourceSize: src, destSize: dst)
        XCTAssertEqual(t.a, 2.0, accuracy: 1e-9)
        // Origin (0,0) of the source must map to (-500, -250) in dest space so
        // the source center stays centered.
        let origin = CGPoint.zero.applying(t)
        XCTAssertEqual(origin.x, -500, accuracy: 1e-9)
        XCTAssertEqual(origin.y, -250, accuracy: 1e-9)
    }

    // MARK: - deltaTransform tests

    func test_deltaTransform_at_identity_is_identity() {
        let t = Zoom.identity.deltaTransform(viewportSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(t, .identity)
    }

    func test_deltaTransform_at_scale_2_centers_zoomed_viewport() {
        let vp = CGSize(width: 1000, height: 500)
        let t = Zoom(scale: 2, panX: 0, panY: 0).deltaTransform(viewportSize: vp)
        // Center of viewport (500, 250) should map to itself.
        let center = CGPoint(x: 500, y: 250).applying(t)
        XCTAssertEqual(center.x, 500, accuracy: 1e-9)
        XCTAssertEqual(center.y, 250, accuracy: 1e-9)
        // Top-left of viewport (0,0) should map to (-500, -250) — pulled outside.
        let origin = CGPoint.zero.applying(t)
        XCTAssertEqual(origin.x, -500, accuracy: 1e-9)
        XCTAssertEqual(origin.y, -250, accuracy: 1e-9)
    }

    /// `deltaTransform` is the visual inverse of `sourcePoint(atViewPosition:)`:
    /// the source point that `sourcePoint` says is shown at viewport position v
    /// must map *to* viewport position v under deltaTransform. With a non-zero
    /// pan this catches a regression where the pan magnitude is missing a
    /// factor of `scale` (which made the visible region drift toward the
    /// source center as the user panned).
    func test_deltaTransform_with_pan_matches_sourcePoint() {
        let vpSize = CGSize(width: 1280, height: 720)
        let z = Zoom(scale: 2, panX: 0.25, panY: -0.1)
        let t = z.deltaTransform(viewportSize: vpSize)
        let probes: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.75, y: 0.75),
        ]
        for probe in probes {
            let expectedSourceNorm = z.sourcePoint(atViewPosition: probe)
            // sourcePoint returns normalized; convert to source pixels (the
            // input space deltaTransform expects when source size == viewport).
            let srcPx = CGPoint(
                x: expectedSourceNorm.x * vpSize.width,
                y: expectedSourceNorm.y * vpSize.height
            )
            let mapped = srcPx.applying(t)
            // The roundtrip should land at viewport pixels (probe * vpSize).
            XCTAssertEqual(mapped.x, probe.x * vpSize.width, accuracy: 1e-6,
                "deltaTransform should map sourcePoint(\(probe)) → viewport(\(probe))")
            XCTAssertEqual(mapped.y, probe.y * vpSize.height, accuracy: 1e-6,
                "deltaTransform should map sourcePoint(\(probe)) → viewport(\(probe))")
        }
    }
}
