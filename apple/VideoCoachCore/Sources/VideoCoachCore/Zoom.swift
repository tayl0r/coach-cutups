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
