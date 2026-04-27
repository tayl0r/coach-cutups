import XCTest
@testable import VideoCoachCore

final class CommentaryEventTests: XCTestCase {
    func test_allKindsRoundtripThroughJSON() throws {
        let stroke = Stroke(color: .red, lineWidth: 0.005,
            points: [.init(x: 0.1, y: 0.1, t: 0)], autoClearAfterSeconds: nil)
        let events: [CommentaryEvent] = [
            .init(recordTime: 0.0, kind: .play),
            .init(recordTime: 1.5, kind: .pause),
            .init(recordTime: 2.0, kind: .play),
            .init(recordTime: 3.0, kind: .skip(delta: -3)),
            .init(recordTime: 3.2, kind: .skip(delta: 3)),
            .init(recordTime: 4.0, kind: .stroke(stroke)),
            .init(recordTime: 5.0, kind: .clearAll),
        ]
        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([CommentaryEvent].self, from: data)
        XCTAssertEqual(decoded.count, 7)
        if case .skip(let d) = decoded[3].kind { XCTAssertEqual(d, -3) } else { XCTFail() }
        if case .stroke(let s) = decoded[5].kind { XCTAssertEqual(s.points.count, 1) } else { XCTFail() }
    }
}
