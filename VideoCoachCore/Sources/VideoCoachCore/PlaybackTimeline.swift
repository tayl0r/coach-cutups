import Foundation

public extension Clip {
    /// Source-video time the user was looking at, at the given record-time.
    /// Walks the event log applying play/pause/skip; stroke and clearAll do not affect source time.
    func sourceTime(atRecordTime t: Double) -> Double {
        var sourceTime = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        for ev in events where ev.recordTime <= t {
            sourceTime += (ev.recordTime - recordCursor) * rate
            recordCursor = ev.recordTime
            switch ev.kind {
            case .play:           rate = 1.0
            case .pause:          rate = 0.0
            case .skip(let d):    sourceTime += d
            case .stroke, .clearAll: break
            }
        }
        sourceTime += (t - recordCursor) * rate
        return sourceTime
    }
}
