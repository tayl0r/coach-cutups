import Foundation

public enum PeriodRole: Equatable, Hashable, Sendable {
    case start(periodIndex: Int)
    case end(periodIndex: Int)
}

public struct InterpretedEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let role: PeriodRole
    /// Index into the input array passed to `interpret(_:format:)`. Lets
    /// callers map an interpreted role back to the originating record without
    /// re-deriving position via a parallel sort.
    public let originalIndex: Int

    public init(absSeconds: Double, role: PeriodRole, originalIndex: Int) {
        self.absSeconds = absSeconds
        self.role = role
        self.originalIndex = originalIndex
    }
}

public func interpret(
    _ startStops: [AbsoluteMatchEvent],
    format: MatchFormat
) -> [InterpretedEvent] {
    let sorted = startStops.enumerated()
        .sorted { lhs, rhs in
            if lhs.element.absSeconds != rhs.element.absSeconds {
                return lhs.element.absSeconds < rhs.element.absSeconds
            }
            return lhs.offset < rhs.offset
        }

    let cap = format.expectedStartStopEvents
    let capped = sorted.prefix(cap)
    return capped.enumerated().map { (i, pair) in
        let periodIndex = i / 2
        let role: PeriodRole = (i % 2 == 0) ? .start(periodIndex: periodIndex)
                                            : .end(periodIndex: periodIndex)
        return InterpretedEvent(
            absSeconds: pair.element.absSeconds,
            role: role,
            originalIndex: pair.offset
        )
    }
}

/// Returns the start/stop role for every `.startStop` record in `project`,
/// keyed by record id. Records without a role (cap exceeded, or no scoreboard
/// configured) are omitted. The inspector's events list calls this once per
/// render and looks up each row's role by id — no per-row re-interpretation.
public func startStopRoles(in project: Project) -> [UUID: PeriodRole] {
    guard let format = project.scoreboard?.format else { return [:] }
    let records = project.matchEvents.filter { $0.kind == .startStop }
    let abs = project.absoluteMatchEvents.filter { $0.kind == .startStop }
    let interp = interpret(abs, format: format)
    var result: [UUID: PeriodRole] = [:]
    result.reserveCapacity(interp.count)
    for ev in interp {
        result[records[ev.originalIndex].id] = ev.role
    }
    return result
}
