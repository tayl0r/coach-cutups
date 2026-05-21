import XCTest
@testable import VideoCoachCore

/// Direct coverage for `startStopRoles(in:)`. The function feeds the
/// inspector's events list, so the contract — "every start/stop record
/// within the format cap maps to its positional period role; anything else
/// is omitted" — needs explicit pinning beyond the indirect coverage from
/// `scoreboardState` callers.
final class StartStopRolesTests: XCTestCase {

    private func makeConfig(format: MatchFormat = MatchFormat()) -> ScoreboardConfig {
        ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
            format: format)
    }

    func test_emptyProject_returnsEmpty() {
        let p = Project(name: "x")
        XCTAssertTrue(startStopRoles(in: p).isEmpty)
    }

    func test_noStartStops_returnsEmpty() {
        var p = Project(name: "x")
        p.scoreboard = makeConfig()
        p.appendHomeGoal(sourceIndex: 0, sourceSeconds: 100)
        p.appendAwayGoal(sourceIndex: 0, sourceSeconds: 200)
        XCTAssertTrue(startStopRoles(in: p).isEmpty)
    }

    func test_mapsRecordIdsToRoles() {
        // 4 chronologically-ordered start/stops in a soccer format → first
        // is 1H start, second is 1H end, third is 2H start, fourth is 2H end.
        var p = Project(name: "x")
        p.scoreboard = makeConfig()
        let times: [Double] = [0, 2700, 2800, 5500]
        for t in times { p.appendStartStop(sourceIndex: 0, sourceSeconds: t) }
        let roles = startStopRoles(in: p)
        XCTAssertEqual(roles.count, 4)
        XCTAssertEqual(roles[p.matchEvents[0].id], .start(periodIndex: 0))
        XCTAssertEqual(roles[p.matchEvents[1].id], .end(periodIndex: 0))
        XCTAssertEqual(roles[p.matchEvents[2].id], .start(periodIndex: 1))
        XCTAssertEqual(roles[p.matchEvents[3].id], .end(periodIndex: 1))
    }

    func test_outOfOrderRecords_assignsRolesByAbsTime() {
        // Insertion order is not chronological order. The role assignment
        // is purely a function of abs time (via interpret()'s sort) — the
        // record at sourceSeconds=0 must be .start(0) regardless of where
        // it was appended.
        var p = Project(name: "x")
        p.scoreboard = makeConfig()
        // Build records directly so we control id assignment and insertion
        // order; appendStartStop's cap check would still allow this set
        // (count==4), but we want to be explicit about insertion order.
        let r30 = MatchEventRecord(kind: .startStop, sourceIndex: 0, sourceSeconds: 30)
        let r10 = MatchEventRecord(kind: .startStop, sourceIndex: 0, sourceSeconds: 10)
        let r20 = MatchEventRecord(kind: .startStop, sourceIndex: 0, sourceSeconds: 20)
        let r00 = MatchEventRecord(kind: .startStop, sourceIndex: 0, sourceSeconds: 0)
        p.matchEvents = [r30, r10, r20, r00]
        let roles = startStopRoles(in: p)
        XCTAssertEqual(roles.count, 4)
        XCTAssertEqual(roles[r00.id], .start(periodIndex: 0))
        XCTAssertEqual(roles[r10.id], .end(periodIndex: 0))
        XCTAssertEqual(roles[r20.id], .start(periodIndex: 1))
        XCTAssertEqual(roles[r30.id], .end(periodIndex: 1))
    }

    func test_overCapRecords_excluded() {
        // Soccer format expects 4 start/stops. If 6 are present (e.g. legacy
        // project with extras), only the first 4 chronologically get a role.
        var p = Project(name: "x")
        p.scoreboard = makeConfig()
        let times: [Double] = [0, 100, 200, 300, 400, 500]
        let records = times.map {
            MatchEventRecord(kind: .startStop, sourceIndex: 0, sourceSeconds: $0)
        }
        p.matchEvents = records
        let roles = startStopRoles(in: p)
        XCTAssertEqual(roles.count, 4)
        for i in 0..<4 {
            XCTAssertNotNil(roles[records[i].id])
        }
        XCTAssertNil(roles[records[4].id])
        XCTAssertNil(roles[records[5].id])
    }

    func test_goalsNotIncluded() {
        // Goal records share the [UUID: PeriodRole] dictionary space but
        // must never have an entry — only start/stops do.
        var p = Project(name: "x")
        p.scoreboard = makeConfig()
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 0)
        p.appendHomeGoal(sourceIndex: 0, sourceSeconds: 100)
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 2700)
        p.appendAwayGoal(sourceIndex: 0, sourceSeconds: 2800)
        let roles = startStopRoles(in: p)
        XCTAssertEqual(roles.count, 2)
        // Find the goal records and assert no entry.
        for rec in p.matchEvents where rec.kind == .homeGoal || rec.kind == .awayGoal {
            XCTAssertNil(roles[rec.id])
        }
    }
}
