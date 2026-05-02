import Foundation

public struct PlaybackSegment: Equatable, Sendable {
    public enum Kind: Sendable { case play, freeze }
    public var kind: Kind
    public var sourceStart: Double      // source-video offset at segment start
    public var outDuration: Double      // duration in the recording timeline (seconds)

    public init(kind: Kind, sourceStart: Double, outDuration: Double) {
        self.kind = kind
        self.sourceStart = sourceStart
        self.outDuration = outDuration
    }
}

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
            case .stroke, .clearAll, .zoom, .unknown: break
            }
        }
        sourceTime += (t - recordCursor) * rate
        return sourceTime
    }

    func playbackSegments(sourceDuration: Double) -> [PlaybackSegment] {
        var segments: [PlaybackSegment] = []
        var sourceCursor = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        func emit(to recordEnd: Double) {
            let dur = recordEnd - recordCursor
            if dur <= 0 { return }
            let kind: PlaybackSegment.Kind = (rate == 0.0) ? .freeze : .play
            segments.append(.init(kind: kind, sourceStart: sourceCursor, outDuration: dur))
            if rate == 1.0 { sourceCursor += dur }
            recordCursor = recordEnd
        }

        for ev in events {
            emit(to: ev.recordTime)
            switch ev.kind {
            case .play:           rate = 1.0
            case .pause:          rate = 0.0
            case .skip(let d):    sourceCursor = max(0, min(sourceDuration, sourceCursor + d))
            case .stroke, .clearAll, .zoom, .unknown: break
            }
        }
        emit(to: recordingDuration)
        return segments
    }
}
