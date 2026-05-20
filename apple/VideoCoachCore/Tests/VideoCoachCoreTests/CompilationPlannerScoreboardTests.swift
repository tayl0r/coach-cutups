import XCTest
@testable import VideoCoachCore

final class CompilationPlannerScoreboardTests: XCTestCase {
    func test_absSeconds_addsCumulativeOffsetToSourceSeconds() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 100),
            SourceRef(bookmark: Data(), displayName: "b", durationSeconds: 60),
        ]
        // sourceIndex 1 has cumulativeOffset 100, plus 30 = 130.
        XCTAssertEqual(p.absSeconds(sourceIndex: 1, sourceSeconds: 30), 130)
    }

    func test_absSeconds_outOfRangeClampsCumulativeOffset() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 100),
        ]
        // sourceIndex 99 clamps to sourceVideos.count == 1, giving 100 + 7 = 107.
        XCTAssertEqual(p.absSeconds(sourceIndex: 99, sourceSeconds: 7), 107)
    }

    /// Direct assertion that `Project.absoluteMatchEvents` (the same projection
    /// `ExportSheet` uses) maps records through cumulative offsets correctly.
    func test_absoluteMatchEvents_mapsThroughCumulativeOffset() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 100),
            SourceRef(bookmark: Data(), displayName: "b", durationSeconds: 60),
        ]
        // appendStartStop no-ops without a scoreboard, so configure one.
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red)
        )
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 10)
        p.appendHomeGoal(sourceIndex: 1, sourceSeconds: 5)
        let abs = p.absoluteMatchEvents
        XCTAssertEqual(abs.count, 2)
        XCTAssertEqual(abs[0], AbsoluteMatchEvent(absSeconds: 10, kind: .startStop))
        XCTAssertEqual(abs[1], AbsoluteMatchEvent(absSeconds: 105, kind: .homeGoal))
    }
}
