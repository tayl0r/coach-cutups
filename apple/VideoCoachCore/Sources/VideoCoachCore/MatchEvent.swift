import Foundation

public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case startStop
    case homeGoal
    case awayGoal
}

public extension MatchEventKind {
    /// User-facing label, single source of truth shared by the inspector
    /// panel's tag buttons and its events list.
    var displayName: String {
        switch self {
        case .homeGoal:  return "Home Goal"
        case .awayGoal:  return "Away Goal"
        case .startStop: return "Start/Stop"
        }
    }
}

public struct MatchEventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var sourceIndex: Int
    public var sourceSeconds: Double

    public init(id: UUID = UUID(), kind: MatchEventKind, sourceIndex: Int, sourceSeconds: Double) {
        self.id = id
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.sourceSeconds = sourceSeconds
    }
}

public struct AbsoluteMatchEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let kind: MatchEventKind

    public init(absSeconds: Double, kind: MatchEventKind) {
        self.absSeconds = absSeconds
        self.kind = kind
    }
}

public extension Project {
    /// All match-event records projected to absolute time on the concat timeline.
    var absoluteMatchEvents: [AbsoluteMatchEvent] {
        matchEvents.map {
            .init(absSeconds: absSeconds(sourceIndex: $0.sourceIndex,
                                          sourceSeconds: $0.sourceSeconds),
                  kind: $0.kind)
        }
    }

    mutating func appendHomeGoal(sourceIndex: Int, sourceSeconds: Double) {
        matchEvents.append(.init(kind: .homeGoal, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }

    mutating func appendAwayGoal(sourceIndex: Int, sourceSeconds: Double) {
        matchEvents.append(.init(kind: .awayGoal, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }

    /// Append a start/stop record. No-op if the configured format's
    /// `expectedStartStopEvents` cap is already reached, or if no scoreboard
    /// is configured.
    mutating func appendStartStop(sourceIndex: Int, sourceSeconds: Double) {
        guard let cap = scoreboard?.format.expectedStartStopEvents else { return }
        let count = matchEvents.lazy.filter({ $0.kind == .startStop }).count
        guard count < cap else { return }
        matchEvents.append(.init(kind: .startStop, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }
}
