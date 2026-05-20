import Foundation

// MARK: - Clock display + state

public enum ClockDisplay: Equatable, Sendable {
    case running(seconds: Double)
    case stoppage(baseSeconds: Double, plusSeconds: Double)
    case onBreak(label: String)   // e.g. "HT" for soccer halftime, "BREAK" for other inter-period gaps
    case fulltime
}

public struct ClockLabels: Equatable, Sendable {
    public let main: String
    public let trailing: String
    public init(main: String, trailing: String) {
        self.main = main; self.trailing = trailing
    }
}

public func formatClock(_ d: ClockDisplay) -> ClockLabels {
    func mmss(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    func plusMSS(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "+%d:%02d", total / 60, total % 60)
    }
    switch d {
    case .running(let s):           return .init(main: mmss(s), trailing: "")
    case .stoppage(let b, let p):   return .init(main: mmss(b), trailing: plusMSS(p))
    case .onBreak(let label):       return .init(main: label, trailing: "")
    case .fulltime:                 return .init(main: "FT", trailing: "")
    }
}

public struct ScoreboardState: Equatable, Sendable {
    public let home: TeamConfig
    public let away: TeamConfig
    public let homeScore: Int
    public let awayScore: Int
    public let clock: ClockDisplay
}

/// Canonical pure function. Compositors call this directly.
///
/// Per-period walk: filters `events` into start/stops vs goals, runs
/// `interpret(_:format:)` on the start/stops to assign positional period roles,
/// then derives the clock display from the highest-indexed `.start` whose
/// `absSeconds <= now`. Multi-period formats (quarters, OT, single-period)
/// fall out naturally — no kind hard-coding.
public func scoreboardState(
    absoluteTime now: Double,
    config: ScoreboardConfig,
    events: [AbsoluteMatchEvent]
) -> ScoreboardState? {
    guard !config.home.name.isEmpty, !config.away.name.isEmpty else { return nil }

    let startStops = events.filter { $0.kind == .startStop }
    let goals = events.filter { $0.kind == .homeGoal || $0.kind == .awayGoal }

    let interp = interpret(startStops, format: config.format)

    // Highest-indexed .start with absSeconds <= now is the "current period".
    // `interp` is sorted by absSeconds (and within a tie, by input order via
    // `interpret(_:format:)`'s stable sort), so `.last(where:)` is the
    // top-most eligible start without a manual scan. This also subsumes the
    // pre-game guard — no eligible start means we haven't begun yet.
    guard let currentStart = interp.last(where: { ev in
        if case .start = ev.role, ev.absSeconds <= now { return true }
        return false
    }), case .start(let curIdx) = currentStart.role else { return nil }
    let currentStartAbs = currentStart.absSeconds

    // Goal-window lower bound is period-0's start (always the first event in
    // `interp` — `interpret(_:format:)` assigns the first sorted start to
    // periodIndex 0, and the `currentStart` guard above proved interp is
    // non-empty).
    let firstStartAbs = interp[0].absSeconds

    let curEnd = interp.first(where: {
        if case .end(let i) = $0.role, i == curIdx { return true } else { return false }
    })

    let cumulativePriorPeriods: Double = (0..<curIdx).reduce(0) { $0 + config.format.periodSeconds($1) }
    let clock: ClockDisplay
    if let end = curEnd, now >= end.absSeconds {
        let isLastExpected = (curIdx == config.format.totalPeriods - 1)
        if isLastExpected {
            clock = .fulltime
        } else {
            clock = .onBreak(label: config.format.breakLabel(afterPeriodIndex: curIdx))
        }
    } else {
        let elapsedInPeriod = now - currentStartAbs
        let perSec = config.format.periodSeconds(curIdx)
        let displayedSeconds = cumulativePriorPeriods + elapsedInPeriod
        if elapsedInPeriod <= perSec {
            clock = .running(seconds: displayedSeconds)
        } else {
            clock = .stoppage(
                baseSeconds: cumulativePriorPeriods + perSec,
                plusSeconds: elapsedInPeriod - perSec
            )
        }
    }

    // Score window upper bound: when the cap is reached, `interpret` has
    // assigned the final slot the `.end` role (odd indices are ends), so
    // the last event's absSeconds is the final whistle. Otherwise the
    // match isn't yet over — leave the bound open.
    let lastEndAbs = interp.count == config.format.expectedStartStopEvents
        ? interp.last!.absSeconds
        : .infinity

    func countGoals(_ kind: MatchEventKind) -> Int {
        goals.reduce(into: 0) { acc, e in
            guard e.kind == kind,
                  e.absSeconds <= now,
                  e.absSeconds >= firstStartAbs,
                  e.absSeconds <= lastEndAbs else { return }
            acc += 1
        }
    }

    return ScoreboardState(
        home: config.home, away: config.away,
        homeScore: countGoals(.homeGoal),
        awayScore: countGoals(.awayGoal),
        clock: clock
    )
}

/// Convenience for live (scan/record/preview) call sites.
public func scoreboardState(
    atSourceIndex sourceIndex: Int,
    sourceSeconds: Double,
    project: Project
) -> ScoreboardState? {
    guard let cfg = project.scoreboard else { return nil }
    let absNow = project.absSeconds(sourceIndex: sourceIndex, sourceSeconds: sourceSeconds)
    return scoreboardState(absoluteTime: absNow, config: cfg, events: project.absoluteMatchEvents)
}
