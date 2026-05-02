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
    /// At scale=2, panX=0.1: scale up by 2 around the viewport center,
    /// then translate by 0.1 of viewport width.
    func deltaTransform(viewportSize: CGSize) -> CGAffineTransform {
        guard scale != 1.0 || panX != 0 || panY != 0 else { return .identity }
        let cx = viewportSize.width / 2
        let cy = viewportSize.height / 2
        let tx = -panX * viewportSize.width
        let ty = -panY * viewportSize.height
        return CGAffineTransform.identity
            .translatedBy(x: cx + tx, y: cy + ty)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -cx, y: -cy)
    }
}
