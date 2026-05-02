import XCTest
@testable import VideoCoachCore

final class TagAggregationTests: XCTestCase {
    func test_aggregatesByTag_withCountAndDuration() {
        let project = makeProject(clips: [
            ("c1", ["attacking-chance", "wing"], 4.0),
            ("c2", ["attacking-chance"], 6.0),
            ("c3", ["transitions"], 3.0),
        ])
        let agg = TagAggregation.aggregate(project: project)
        XCTAssertEqual(Set(agg.map(\.tag)), ["attacking-chance", "transitions", "wing"])
        let attacking = agg.first(where: { $0.tag == "attacking-chance" })!
        XCTAssertEqual(attacking.clipCount, 2)
        XCTAssertEqual(attacking.totalDurationSeconds, 10.0)
    }

    func test_isAlphabeticallySorted() {
        let p = makeProject(clips: [
            ("c1", ["zebra"], 1), ("c2", ["alpha"], 1), ("c3", ["mango"], 1),
        ])
        XCTAssertEqual(TagAggregation.aggregate(project: p).map(\.tag), ["alpha", "mango", "zebra"])
    }

    private func makeProject(clips: [(String, [String], Double)]) -> Project {
        var p = Project(name: "t")
        for (i, c) in clips.enumerated() {
            p.clips.append(Clip(name: c.0, tags: c.1,
                                sourceIndex: 0, startSourceSeconds: 0,
                                recordingDuration: c.2, recordingFilename: "x.mov",
                                sortIndex: i))
        }
        return p
    }
}
