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
    public var isAutoBackAnchor: Bool

    public init(
        id: UUID = UUID(),
        kind: MatchEventKind,
        sourceIndex: Int,
        sourceSeconds: Double,
        isAutoBackAnchor: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.sourceSeconds = sourceSeconds
        self.isAutoBackAnchor = isAutoBackAnchor
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, sourceIndex, sourceSeconds, isAutoBackAnchor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self,        forKey: .id)
        self.kind          = try c.decode(MatchEventKind.self, forKey: .kind)
        self.sourceIndex   = try c.decode(Int.self,         forKey: .sourceIndex)
        self.sourceSeconds = try c.decode(Double.self,      forKey: .sourceSeconds)
        self.isAutoBackAnchor = try c.decodeIfPresent(Bool.self, forKey: .isAutoBackAnchor) ?? false
    }
}

public struct AbsoluteMatchEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let kind: MatchEventKind
    public let isAutoBackAnchor: Bool

    public init(absSeconds: Double, kind: MatchEventKind, isAutoBackAnchor: Bool = false) {
        self.absSeconds = absSeconds
        self.kind = kind
        self.isAutoBackAnchor = isAutoBackAnchor
    }
}

public extension Project {
    /// All match-event records projected to absolute time on the concat timeline.
    var absoluteMatchEvents: [AbsoluteMatchEvent] {
        matchEvents.map {
            .init(
                absSeconds: absSeconds(sourceIndex: $0.sourceIndex,
                                       sourceSeconds: $0.sourceSeconds),
                kind: $0.kind,
                isAutoBackAnchor: $0.isAutoBackAnchor
            )
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

    var hasAutoBackAnchorP1: Bool {
        matchEvents.contains { $0.isAutoBackAnchor }
    }

    /// Inserts at index 0 (not appends) so the flagged event wins `interpret()`'s
    /// positional tie-break against any manual `(0, 0)` start/stop. Idempotent;
    /// `on=false` removes every flagged event.
    mutating func setAutoBackAnchorP1(_ on: Bool) {
        if on {
            guard !hasAutoBackAnchorP1 else { return }
            matchEvents.insert(.init(
                kind: .startStop,
                sourceIndex: 0,
                sourceSeconds: 0,
                isAutoBackAnchor: true
            ), at: 0)
        } else {
            matchEvents.removeAll { $0.isAutoBackAnchor }
        }
    }
}
