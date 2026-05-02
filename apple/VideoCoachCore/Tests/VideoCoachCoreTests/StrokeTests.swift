import XCTest
@testable import VideoCoachCore

final class StrokeTests: XCTestCase {
    func test_strokeRoundtripsThroughJSON() throws {
        let stroke = Stroke(
            color: .init(r: 1, g: 0, b: 0, a: 1),
            lineWidth: 0.005,
            points: [
                .init(x: 0.1, y: 0.2, t: 0.0),
                .init(x: 0.5, y: 0.6, t: 0.05),
            ],
            autoClearAfterSeconds: 5.0
        )
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(Stroke.self, from: data)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.autoClearAfterSeconds, 5.0)
        XCTAssertEqual(decoded.color.r, 1.0)
    }
}
