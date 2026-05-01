import XCTest
@testable import VideoCoachCore

final class ProjectCumulativeTests: XCTestCase {
    private func project(durations: [Double]) -> Project {
        var p = Project(name: "test")
        p.sourceVideos = durations.map { d in
            SourceRef(bookmark: Data(), displayName: "x", durationSeconds: d)
        }
        return p
    }

    func test_totalSourceDuration_emptyIsZero() {
        XCTAssertEqual(project(durations: []).totalSourceDuration, 0)
    }
    func test_totalSourceDuration_sumsDurations() {
        XCTAssertEqual(project(durations: [120, 90, 60]).totalSourceDuration, 270)
    }
    func test_cumulativeOffsetForFirstSourceIsZero() {
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: 0), 0)
    }
    func test_cumulativeOffsetForLaterSourceIsSumOfPrior() {
        XCTAssertEqual(project(durations: [120, 90, 60]).cumulativeOffset(forSourceIndex: 2), 210)
    }
    func test_cumulativeOffsetClampsOutOfRange() {
        // Pos > last clamps to total. Pos < 0 clamps to 0.
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: 99), 210)
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: -1), 0)
    }
    func test_cumulativeOffsetEmptyProjectIsZero() {
        XCTAssertEqual(project(durations: []).cumulativeOffset(forSourceIndex: 0), 0)
    }
}
