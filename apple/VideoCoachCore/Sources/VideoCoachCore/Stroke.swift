import Foundation

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let red = RGBA(r: 1, g: 0.2, b: 0.2, a: 1)
}

public struct StrokePoint: Codable, Hashable, Sendable {
    public var x: Double          // 0...1 of frame width
    public var y: Double          // 0...1 of frame height
    public var t: Double          // seconds since stroke start
    public init(x: Double, y: Double, t: Double) {
        self.x = x; self.y = y; self.t = t
    }
}

public struct Stroke: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var color: RGBA
    public var lineWidth: Double                    // normalized to frame height
    public var points: [StrokePoint]
    public var autoClearAfterSeconds: Double?       // nil = persist
    public init(id: UUID = UUID(),
                color: RGBA,
                lineWidth: Double,
                points: [StrokePoint],
                autoClearAfterSeconds: Double?) {
        self.id = id
        self.color = color
        self.lineWidth = lineWidth
        self.points = points
        self.autoClearAfterSeconds = autoClearAfterSeconds
    }
}
