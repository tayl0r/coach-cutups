import CoreGraphics

/// Maps a stored normalized stroke point (top-left origin, x and y in `0...1`)
/// into a pixel position inside an output canvas of `size`.
///
/// `flipY` is the CRITICAL knob — call sites differ in whether they're drawing
/// into a top-left-origin or bottom-left-origin space:
///
/// - **Live overlay** (`NSView` with `isFlipped == false`, bottom-left origin):
///   pass `flipY: true` so the stored top-left y becomes a bottom-left y.
/// - **Export compositor** (`CGContext` over `CVPixelBuffer` with the
///   `translateBy(0, h); scaleBy(1, -1)` flip already applied): pass
///   `flipY: false`, since user-space is already top-left after the flip.
///
/// See `docs/plans/2026-04-27-video-coach-design.md` § "Drawing capture" for
/// the misuse table; passing `flipY: true` in the export compositor renders
/// strokes upside-down (a known footgun the smoke test guards against).
public enum Denormalize {
    public static func point(_ x: Double, _ y: Double, into size: CGSize, flipY: Bool) -> CGPoint {
        let px = CGFloat(x) * size.width
        let py = CGFloat(y) * size.height
        return flipY ? CGPoint(x: px, y: size.height - py) : CGPoint(x: px, y: py)
    }
}
