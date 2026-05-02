import XCTest
@testable import VideoCoachCore

final class CommentaryEventZoomTests: XCTestCase {
    func test_zoom_event_roundtrips_through_codable() throws {
        let original = CommentaryEvent(
            recordTime: 1.5,
            kind: .zoom(Zoom(scale: 2.0, panX: 0.1, panY: -0.05))
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommentaryEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_unknown_kind_decodes_as_unknown_case_not_error() throws {
        // Simulates a future build's project file with a kind discriminator
        // we don't recognize. Old builds must not crash on this.
        let json = #"""
        {"recordTime":1.0,"kind":{"futureKind":{"someField":42}}}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CommentaryEvent.self, from: json)
        if case .unknown = decoded.kind {
            // Pass.
        } else {
            XCTFail("Expected .unknown for future discriminator, got \(decoded.kind)")
        }
    }
}
