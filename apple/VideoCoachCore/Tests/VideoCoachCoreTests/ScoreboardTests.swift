import XCTest
@testable import VideoCoachCore

final class ScoreboardMutatorTests: XCTestCase {
    func test_appendHomeGoal_appendsEachTime() {
        var p = Project(name: "x")
        p.appendHomeGoal(sourceIndex: 0, sourceSeconds: 100)
        p.appendHomeGoal(sourceIndex: 0, sourceSeconds: 200)
        XCTAssertEqual(p.matchEvents.count, 2)
        XCTAssertNotEqual(p.matchEvents[0].id, p.matchEvents[1].id)
    }

    func test_appendStartStop_appendsRecord() {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red)
        )
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 100)
        XCTAssertEqual(p.matchEvents.count, 1)
        XCTAssertEqual(p.matchEvents[0].kind, .startStop)
        XCTAssertEqual(p.matchEvents[0].sourceSeconds, 100)
    }

    func test_appendStartStop_respectsCap() {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red)
        )
        for i in 1...4 {
            p.appendStartStop(sourceIndex: 0, sourceSeconds: Double(i * 100))
        }
        XCTAssertEqual(p.matchEvents.count, 4)
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 500)
        XCTAssertEqual(p.matchEvents.count, 4)
    }

    func test_appendStartStop_noOpsWhenScoreboardNil() {
        var p = Project(name: "x")
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 100)
        XCTAssertEqual(p.matchEvents.count, 0)
    }
}

final class FormatClockTests: XCTestCase {
    func test_running_zero() { XCTAssertEqual(formatClock(.running(seconds: 0)), ClockLabels(main: "00:00", trailing: "")) }
    func test_running_padding() {
        XCTAssertEqual(formatClock(.running(seconds: 5)), ClockLabels(main: "00:05", trailing: ""))
        XCTAssertEqual(formatClock(.running(seconds: 125)), ClockLabels(main: "02:05", trailing: ""))
    }
    func test_running_drops_fractions() {
        XCTAssertEqual(formatClock(.running(seconds: 125.9)), ClockLabels(main: "02:05", trailing: ""))
    }
    func test_stoppage() {
        XCTAssertEqual(formatClock(.stoppage(baseSeconds: 2700, plusSeconds: 47)),
                       ClockLabels(main: "45:00", trailing: "+0:47"))
        XCTAssertEqual(formatClock(.stoppage(baseSeconds: 5400, plusSeconds: 305)),
                       ClockLabels(main: "90:00", trailing: "+5:05"))
    }
    func test_halftime_fulltime() {
        XCTAssertEqual(formatClock(.onBreak(label: "HT")), ClockLabels(main: "HT", trailing: ""))
        XCTAssertEqual(formatClock(.onBreak(label: "BREAK")), ClockLabels(main: "BREAK", trailing: ""))
        XCTAssertEqual(formatClock(.fulltime), ClockLabels(main: "FT", trailing: ""))
    }
}

final class ScoreboardStateTests: XCTestCase {
    private func cfg(
        homeName: String = "H",
        awayName: String = "A",
        format: MatchFormat = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45 * 60)
    ) -> ScoreboardConfig {
        ScoreboardConfig(
            home: TeamConfig(name: homeName, primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: awayName, primaryColor: .red, secondaryColor: .red),
            format: format
        )
    }
    private func evt(_ kind: MatchEventKind, at: Double) -> AbsoluteMatchEvent { .init(absSeconds: at, kind: kind) }

    func test_nil_whenNoGameStart() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(), events: [])) }
    func test_nil_whenHomeNameEmpty() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(homeName: ""), events: [evt(.startStop, at: 0)])) }
    func test_nil_whenAwayNameEmpty() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(awayName: ""), events: [evt(.startStop, at: 0)])) }
    func test_nil_whenNowBeforeGameStart() { XCTAssertNil(scoreboardState(absoluteTime: 5, config: cfg(), events: [evt(.startStop, at: 10)])) }

    func test_firstHalfRunning() {
        XCTAssertEqual(scoreboardState(absoluteTime: 100, config: cfg(), events: [evt(.startStop, at: 0)])?.clock, .running(seconds: 100))
    }
    func test_firstHalfStoppage() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2750, config: cfg(), events: [evt(.startStop, at: 0)])?.clock,
                       .stoppage(baseSeconds: 2700, plusSeconds: 50))
    }
    func test_halftime() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2800, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750)])?.clock, .onBreak(label: "HT"))
    }
    func test_secondHalfRunning() {
        XCTAssertEqual(scoreboardState(absoluteTime: 3000, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750), evt(.startStop, at: 2900)])?.clock,
            .running(seconds: 2800))
    }
    func test_secondHalfStoppage() {
        XCTAssertEqual(scoreboardState(absoluteTime: 5650, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750), evt(.startStop, at: 2900)])?.clock,
            .stoppage(baseSeconds: 5400, plusSeconds: 50))
    }
    func test_fulltime() {
        XCTAssertEqual(scoreboardState(absoluteTime: 6000, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750),
                     evt(.startStop, at: 2900), evt(.startStop, at: 5800)])?.clock, .fulltime)
    }

    func test_goalsInGameSpan_count() {
        let s = scoreboardState(absoluteTime: 1000, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.homeGoal, at: 100), evt(.homeGoal, at: 500), evt(.awayGoal, at: 700)])
        XCTAssertEqual(s?.homeScore, 2); XCTAssertEqual(s?.awayScore, 1)
    }
    func test_goalsBeforeGameStart_ignored() {
        XCTAssertEqual(scoreboardState(absoluteTime: 1000, config: cfg(),
            events: [evt(.homeGoal, at: -10), evt(.startStop, at: 0)])?.homeScore, 0)
    }
    func test_goalsAfterGameEnd_ignored() {
        // All 4 start/stops present (cap reached) → final whistle is the
        // 4th event at 5800. Goal at 6000 is past it.
        XCTAssertEqual(scoreboardState(absoluteTime: 10_000, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750),
                     evt(.startStop, at: 2900), evt(.startStop, at: 5800),
                     evt(.homeGoal, at: 6000)])?.homeScore, 0)
    }
    func test_goalsDuringHT_count() {
        let s = scoreboardState(absoluteTime: 2800, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.startStop, at: 2750), evt(.homeGoal, at: 2780)])
        XCTAssertEqual(s?.clock, .onBreak(label: "HT")); XCTAssertEqual(s?.homeScore, 1)
    }
    func test_goalsNotYetReached_notCounted() {
        XCTAssertEqual(scoreboardState(absoluteTime: 100, config: cfg(),
            events: [evt(.startStop, at: 0), evt(.homeGoal, at: 500)])?.homeScore, 0)
    }

    func test_oddMinuteMatch_halfLenIsHalfPrecise() {
        // 91-minute match split into two 45.5-minute halves. Half length is
        // an integer-second quantity (Int seconds), so we drop the fractional
        // half-second and use 2730s (45.5 min) per half.
        let format = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: (91 * 60) / 2)
        XCTAssertEqual(scoreboardState(absoluteTime: 2730, config: cfg(format: format),
            events: [evt(.startStop, at: 0)])?.clock, .running(seconds: 2730))
    }

    func test_projectWrapper_walksCumulativeOffset() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 60),
            SourceRef(bookmark: Data(), displayName: "b", durationSeconds: 60),
        ]
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red))
        p.appendStartStop(sourceIndex: 1, sourceSeconds: 5)
        XCTAssertEqual(scoreboardState(atSourceIndex: 1, sourceSeconds: 10, project: p)?.clock,
                       .running(seconds: 5))
    }
    func test_projectWrapper_nilWhenScoreboardMissing() {
        let p = Project(name: "x")
        XCTAssertNil(scoreboardState(atSourceIndex: 0, sourceSeconds: 10, project: p))
    }

    // MARK: - Multi-period formats (quarters, fulltime after final period)

    func test_quarters_betweenQ1AndQ2_showsBreak() {
        let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
        let config = cfg(format: format)
        let events = [
            AbsoluteMatchEvent(absSeconds: 0,    kind: .startStop),  // Q1 start
            AbsoluteMatchEvent(absSeconds: 720,  kind: .startStop),  // Q1 end
        ]
        let s = scoreboardState(absoluteTime: 750, config: config, events: events)
        XCTAssertEqual(s?.clock, .onBreak(label: "BREAK"))
    }

    func test_quarters_fulltimeAfterQ4End() {
        let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 720)
        let config = cfg(format: format)
        let events: [AbsoluteMatchEvent] = (0..<8).map { i in
            AbsoluteMatchEvent(absSeconds: Double(i) * 1000, kind: .startStop)
        }
        let s = scoreboardState(absoluteTime: 8000, config: config, events: events)
        XCTAssertEqual(s?.clock, .fulltime)
    }

    func test_quarters_inQ2_clockAccumulates() {
        // 4 periods, 12-min quarters. Q1 [0..720], Q2 starts at 800. At
        // now=830 we're 30s into Q2 → displayed clock is cumulative prior
        // (720) + elapsed (30) = 750s of game time.
        let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12 * 60)
        let config = cfg(format: format)
        let events = [
            evt(.startStop, at: 0),    // Q1 start
            evt(.startStop, at: 720),  // Q1 end
            evt(.startStop, at: 800),  // Q2 start
        ]
        XCTAssertEqual(scoreboardState(absoluteTime: 830, config: config, events: events)?.clock,
                       .running(seconds: 750))
    }

    func test_quarters_inQ3_stoppage() {
        // 4 periods, 12-min quarters. Q1 [0..720], Q2 [800..1600], Q3 starts
        // at 1700. At now=1700 + 720 + 50 = 2470 we're 50s past Q3's
        // regulation end → stoppage with base = 3 quarters of 720 = 2160 and
        // plus = 50s.
        let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12 * 60)
        let config = cfg(format: format)
        let events = [
            evt(.startStop, at: 0),     // Q1 start
            evt(.startStop, at: 720),   // Q1 end
            evt(.startStop, at: 800),   // Q2 start
            evt(.startStop, at: 1600),  // Q2 end
            evt(.startStop, at: 1700),  // Q3 start
        ]
        XCTAssertEqual(scoreboardState(absoluteTime: 2470, config: config, events: events)?.clock,
                       .stoppage(baseSeconds: 2160, plusSeconds: 50))
    }

    func test_overtime_clockProgressesPastRegulation() {
        // 2 regulation periods (45 min each) + 2 OT periods (15 min each).
        // Regulation ends at abs=10800 (2nd half ends); OT1 starts at 10900.
        // At OT1_start + 60 = 10960 the clock is the cumulative prior (two
        // regulation periods = 90*60 = 5400s) plus 60s elapsed in OT1 = 5460s.
        let format = MatchFormat(
            regulationPeriods: 2, regulationPeriodSeconds: 45 * 60,
            overtimePeriods: 2, overtimePeriodSeconds: 15 * 60)
        let config = cfg(format: format)
        let events = [
            evt(.startStop, at: 0),       // 1H start
            evt(.startStop, at: 2700),    // 1H end
            evt(.startStop, at: 2800),    // 2H start
            evt(.startStop, at: 10800),   // 2H end (after stoppage)
            evt(.startStop, at: 10900),   // OT1 start
        ]
        XCTAssertEqual(scoreboardState(absoluteTime: 10960, config: config, events: events)?.clock,
                       .running(seconds: 90 * 60 + 60))
    }

    func test_overtime_fulltimeAfterOTEnd() {
        // 2 regulation + 2 OT; tag all 8 start/stops (cap = 2 * totalPeriods).
        // After the last OT2 end the clock is .fulltime — the last period is
        // the last expected period.
        let format = MatchFormat(
            regulationPeriods: 2, regulationPeriodSeconds: 45 * 60,
            overtimePeriods: 2, overtimePeriodSeconds: 15 * 60)
        let config = cfg(format: format)
        let events: [AbsoluteMatchEvent] = (0..<8).map { i in
            evt(.startStop, at: Double(i) * 1000)
        }
        XCTAssertEqual(scoreboardState(absoluteTime: 8000, config: config, events: events)?.clock,
                       .fulltime)
    }

    func test_quarters_goalsCounted_acrossAllPeriods() {
        // Quarters format. Goals in Q1 (during play) and Q3 (during play)
        // both fall inside the [firstStart, lastEnd] window and count once
        // the score is sampled past Q3's end.
        let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12 * 60)
        let config = cfg(format: format)
        let events = [
            evt(.startStop, at: 0),     // Q1 start
            evt(.homeGoal,  at: 300),   // goal in Q1
            evt(.startStop, at: 720),   // Q1 end
            evt(.startStop, at: 800),   // Q2 start
            evt(.startStop, at: 1600),  // Q2 end
            evt(.startStop, at: 1700),  // Q3 start
            evt(.awayGoal,  at: 1900),  // goal in Q3
            evt(.startStop, at: 2500),  // Q3 end
        ]
        let s = scoreboardState(absoluteTime: 2600, config: config, events: events)
        XCTAssertEqual(s?.homeScore, 1)
        XCTAssertEqual(s?.awayScore, 1)
    }
}
