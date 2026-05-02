import Foundation

public struct VisibleStroke: Equatable, Sendable {
    public let stroke: Stroke
    public let firstPointRecordTime: Double
    public let drawnPointCount: Int

    public init(stroke: Stroke, firstPointRecordTime: Double, drawnPointCount: Int) {
        self.stroke = stroke
        self.firstPointRecordTime = firstPointRecordTime
        self.drawnPointCount = drawnPointCount
    }
}

public func visibleStrokes(in clip: Clip, atRecordTime t: Double) -> [VisibleStroke] {
    let clearAllTimes: [Double] = clip.events.compactMap {
        guard case .clearAll = $0.kind, $0.recordTime <= t else { return nil }
        return $0.recordTime
    }

    var out: [VisibleStroke] = []
    for ev in clip.events {
        guard case .stroke(let s) = ev.kind else { continue }
        let firstT = ev.recordTime - (s.points.last?.t ?? 0)
        if t < firstT { continue }
        if let auto = s.autoClearAfterSeconds, t >= firstT + auto { continue }
        if clearAllTimes.contains(where: { $0 > firstT && $0 <= t }) { continue }

        let elapsed = t - firstT
        let k = s.points.firstIndex(where: { $0.t > elapsed }) ?? s.points.count
        out.append(.init(stroke: s, firstPointRecordTime: firstT, drawnPointCount: k))
    }
    return out
}
