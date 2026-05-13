import XCTest
@testable import VideoCoachCore

/// Locks in the invariant that `CompilationExporter.compositorEvents(from:)`
/// keeps every event the per-frame compositor needs and drops every event
/// the segment builder already collapsed. Regression test for the
/// 2026-05-05 bug where exported videos rendered at identity zoom because
/// the filter excluded `.zoom` events along with `.play`/`.pause`/`.skip`.
final class CompilationExporterEventFilterTests: XCTestCase {

    func test_compositorEvents_keepsZoomStrokeAndClearAll_dropsPlayPauseSkipUnknown() {
        let stroke = Stroke(color: .red, lineWidth: 0.005,
            points: [.init(x: 0.5, y: 0.5, t: 0)],
            autoClearAfterSeconds: nil)
        let events: [CommentaryEvent] = [
            .init(recordTime: 0,   kind: .zoom(.identity)),
            .init(recordTime: 0,   kind: .pause(sourceTime: 0)),
            .init(recordTime: 0.5, kind: .zoom(Zoom(scale: 2, panX: 0.1, panY: 0))),
            .init(recordTime: 1.0, kind: .play(sourceTime: 0)),
            .init(recordTime: 1.5, kind: .stroke(stroke)),
            .init(recordTime: 2.0, kind: .skip(delta: -1)),
            .init(recordTime: 2.5, kind: .clearAll),
            .init(recordTime: 3.0, kind: .unknown),
        ]
        let kept = CompilationExporter.compositorEvents(from: events)
        // Expect: 2 zooms + 1 stroke + 1 clearAll = 4.
        XCTAssertEqual(kept.count, 4,
            "filter should keep zoom + stroke + clearAll only; got \(kept.count) events: \(kept.map(\.kind))")

        let zoomCount = kept.reduce(into: 0) { acc, e in
            if case .zoom = e.kind { acc += 1 }
        }
        XCTAssertEqual(zoomCount, 2,
            "every .zoom must pass through to the compositor — without them, exports render at identity even if the user zoomed")

        let strokeCount = kept.reduce(into: 0) { acc, e in
            if case .stroke = e.kind { acc += 1 }
        }
        XCTAssertEqual(strokeCount, 1)

        let clearAllCount = kept.reduce(into: 0) { acc, e in
            if case .clearAll = e.kind { acc += 1 }
        }
        XCTAssertEqual(clearAllCount, 1)

        // None of the segment-driving kinds should leak through.
        for e in kept {
            switch e.kind {
            case .play, .pause, .skip, .unknown:
                XCTFail("filter let through a segment-driving event: \(e.kind)")
            case .stroke, .clearAll, .zoom:
                break
            }
        }
    }
}
