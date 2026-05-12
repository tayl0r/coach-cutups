import Foundation

public struct Zoom: Codable, Hashable, Sendable {
    public var scale: Double
    public var panX: Double
    public var panY: Double

    public static let identity = Zoom(scale: 1.0, panX: 0, panY: 0)

    public init(scale: Double, panX: Double, panY: Double) {
        self.scale = scale
        self.panX = panX
        self.panY = panY
    }

    /// Hard floor 1.0× (no zooming out past full frame), soft cap 10×.
    /// Pan range narrows as scale → 1.0; at scale=1 pan is forced to 0.
    public func clamped() -> Zoom {
        let s = max(1.0, min(10.0, scale))
        guard s > 1.0 else { return Zoom(scale: 1.0, panX: 0, panY: 0) }
        let limit = (s - 1.0) / (2.0 * s)
        let px = max(-limit, min(limit, panX))
        let py = max(-limit, min(limit, panY))
        return Zoom(scale: s, panX: px, panY: py)
    }

    /// Standard snap notches — common camera/video multipliers users tend to
    /// expect. Match these in any UI tick-mark rendering so the visible track
    /// agrees with the snap behavior.
    public static let snapNotches: [Double] = [1.0, 1.25, 1.5, 2.0, 3.0, 5.0, 7.5, 10.0]

    /// Snap `scale` to the nearest notch when within 3% relative tolerance,
    /// otherwise return self. Pan is preserved. Called from interactive
    /// gesture commits — replay paths skip this so authored zoom values
    /// pass through unchanged.
    public func snapped() -> Zoom {
        let tol = 0.03
        for n in Self.snapNotches where abs(scale - n) <= n * tol {
            return Zoom(scale: n, panX: panX, panY: panY)
        }
        return self
    }
}

public extension Zoom {
    /// Source point currently visible at view-relative position
    /// `viewPos` (each component 0...1). Inverse of the rendering transform.
    func sourcePoint(atViewPosition viewPos: CGPoint) -> CGPoint {
        // Visible window in source coordinates: width = 1/scale, centered at
        // 0.5 + pan. So source = (0.5 + pan) + (viewPos - 0.5) / scale.
        CGPoint(
            x: (0.5 + panX) + (Double(viewPos.x) - 0.5) / scale,
            y: (0.5 + panY) + (Double(viewPos.y) - 0.5) / scale
        )
    }

    /// Apply a new scale while keeping the source point under `cursor`
    /// fixed under the cursor. Pan is clamped via `.clamped()`.
    func zoomedToCursor(newScale: Double, cursor: CGPoint) -> Zoom {
        let s2 = max(1.0, min(10.0, newScale))
        guard s2 > 1.0 else { return .identity }
        // Source point under cursor before the zoom (uses self.scale and pan).
        let src = sourcePoint(atViewPosition: cursor)
        // Solve for pan' such that source = src remains under cursor at s2.
        let panX2 = (src.x - (Double(cursor.x) - 0.5) / s2) - 0.5
        let panY2 = (src.y - (Double(cursor.y) - 0.5) / s2) - 0.5
        return Zoom(scale: s2, panX: panX2, panY: panY2).clamped()
    }
}

public extension Zoom {
    /// Transform that maps source-frame pixel coords → destination pixel
    /// coords using a letterbox-fit base scale. At identity (and matching
    /// aspect ratios), this is the identity transform.
    func transform(sourceSize: CGSize, destSize: CGSize) -> CGAffineTransform {
        let baseScale = min(destSize.width / sourceSize.width,
                            destSize.height / sourceSize.height)
        let s = scale * baseScale
        let dx = (destSize.width - sourceSize.width * s) / 2
        let dy = (destSize.height - sourceSize.height * s) / 2
        let tx = dx - panX * sourceSize.width * s
        let ty = dy - panY * sourceSize.height * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty)
    }

    /// Zoom-and-pan delta in viewport pixel coordinates, to be applied
    /// AFTER any existing layout transform. At identity returns the
    /// identity transform (no behavior change for existing compositors).
    ///
    /// Visual inverse of `sourcePoint(atViewPosition:)`: the source point
    /// at viewport-center is `(0.5 + panX, 0.5 + panY)` (in normalized
    /// coords), and `scale` is the viewport-pixel-per-source-pixel ratio.
    /// Forward map: viewport = scale·source + (cx − scale·(0.5+pan)·W, cy − scale·(0.5+pan)·H).
    func deltaTransform(viewportSize: CGSize) -> CGAffineTransform {
        guard scale != 1.0 || panX != 0 || panY != 0 else { return .identity }
        let cx = viewportSize.width / 2
        let cy = viewportSize.height / 2
        // Build as: translate(-(0.5+pan)·viewport)  →  scale  →  translate(center).
        // The `scaledBy` chain pre-multiplies the new op, so this matches the
        // intended semantics: shift the desired-center-source-point to origin,
        // scale around origin, shift origin back to viewport center.
        return CGAffineTransform.identity
            .translatedBy(x: cx, y: cy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(0.5 + panX) * viewportSize.width,
                          y: -(0.5 + panY) * viewportSize.height)
    }

    /// Same as ``deltaTransform(viewportSize:)`` but for callers that apply
    /// the transform to a `CIImage` (or any geometry in bottom-left origin).
    ///
    /// `deltaTransform` is authored for TOP-LEFT origin (matching
    /// `AVMutableVideoCompositionLayerInstruction.setTransform`, the AppKit
    /// view-tree, and `CGContext` after the standard `translateBy(0,h);
    /// scaleBy(1,-1)` flip). `CIImage` lives in BOTTOM-LEFT space, so a
    /// `panY > 0` ("show lower content") would translate the image the
    /// wrong direction along Y. The fix is one sign flip: where the
    /// top-left formula uses `(0.5 + panY)`, the bottom-left formula uses
    /// `(0.5 − panY)` — equivalent to reflecting the desired-center-source
    /// point across the image's mid-Y line before building the transform.
    func deltaTransformForCIImage(viewportSize: CGSize) -> CGAffineTransform {
        guard scale != 1.0 || panX != 0 || panY != 0 else { return .identity }
        let cx = viewportSize.width / 2
        let cy = viewportSize.height / 2
        return CGAffineTransform.identity
            .translatedBy(x: cx, y: cy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(0.5 + panX) * viewportSize.width,
                          y: -(0.5 - panY) * viewportSize.height)
    }
}
