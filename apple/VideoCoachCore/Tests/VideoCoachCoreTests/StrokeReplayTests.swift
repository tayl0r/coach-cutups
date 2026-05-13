import XCTest
@testable import VideoCoachCore

final class StrokeReplayTests: XCTestCase {
    // The case the naive forward-walk misses: strokes added to `out`
    // BEFORE the .clearAll event is encountered. A correct algorithm must
    // know about every clearAll up to t before deciding stroke visibility.
    func test_laterClearAll_clearsEarlierStrokesEvenInForwardOrder() {
        let a = instantStroke(id: "A")
        let b = instantStroke(id: "B")
        let c = instantStroke(id: "C")
        let clip = makeClip(events: [
            .init(recordTime: 1, kind: .stroke(a)),
            .init(recordTime: 3, kind: .stroke(b)),
            .init(recordTime: 4, kind: .clearAll),
            .init(recordTime: 5, kind: .stroke(c)),
        ])
        let visible = visibleStrokes(in: clip, atRecordTime: 6)
        XCTAssertEqual(visible.map(\.stroke.id), [c.id])
    }

    func test_strokeIsInvisibleBeforeFirstPointRecordTime() {
        // 1-second drag stroke ending at recordTime 5 → firstPointRecordTime = 4.
        let s = dragStroke(id: "S", durationSeconds: 1.0, pointCount: 10)
        let clip = makeClip(events: [
            .init(recordTime: 5, kind: .stroke(s)),
        ])
        XCTAssertTrue(visibleStrokes(in: clip, atRecordTime: 3.5).isEmpty)
        XCTAssertFalse(visibleStrokes(in: clip, atRecordTime: 4.0).isEmpty,
                       "stroke should be visible at firstPointRecordTime")
    }

    func test_strokePartiallyVisibleMidDraw_yieldsCorrectDrawnPointCount() {
        // 10 points spaced 0.1s apart; stroke ends at recordTime 5 → firstPointRecordTime = 4.
        let s = dragStroke(id: "S", durationSeconds: 1.0, pointCount: 10)
        let clip = makeClip(events: [
            .init(recordTime: 5, kind: .stroke(s)),
        ])
        // At record-time 4.45 we're 0.45s into the stroke; points with t in {0, 0.1, 0.2, 0.3, 0.4}
        // are drawn (5 of them). Point with t = 0.5 is NOT yet drawn.
        let visible = visibleStrokes(in: clip, atRecordTime: 4.45)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.drawnPointCount, 5)
        XCTAssertEqual(visible.first?.firstPointRecordTime ?? .nan, 4.0, accuracy: 1e-9)
    }

    func test_autoClearMakesStrokeInvisibleAfterDuration() {
        let s = Stroke(id: UUID(uuidString: deterministicUUID("S"))!, color: .red,
                       lineWidth: 0.005,
                       points: [StrokePoint(x: 0.5, y: 0.5, t: 0)],
                       autoClearAfterSeconds: 5.0)
        let clip = makeClip(events: [
            .init(recordTime: 2, kind: .stroke(s)),  // firstPointRecordTime = 2
        ])
        XCTAssertEqual(visibleStrokes(in: clip, atRecordTime: 6.99).count, 1,
                       "still visible just before auto-clear deadline")
        XCTAssertEqual(visibleStrokes(in: clip, atRecordTime: 7.00).count, 0,
                       "invisible at exactly firstPointRecordTime + autoClearAfterSeconds")
    }

    func test_clearAllAffectsEarlierStrokesButNotLater() {
        // Asymmetric check: a stroke drawn BEFORE clearAll is gone; a stroke drawn AFTER survives.
        let a = instantStroke(id: "A")
        let b = instantStroke(id: "B")
        let clip = makeClip(events: [
            .init(recordTime: 1, kind: .stroke(a)),
            .init(recordTime: 2, kind: .clearAll),
            .init(recordTime: 3, kind: .stroke(b)),
        ])
        XCTAssertEqual(visibleStrokes(in: clip, atRecordTime: 4).map(\.stroke.id), [b.id])
    }

    // MARK: - Helpers

    /// A stroke whose mouseDown == mouseUp at the event's recordTime.
    /// (`points.last.t == 0` so `firstPointRecordTime == event.recordTime`.)
    private func instantStroke(id: String) -> Stroke {
        Stroke(
            id: UUID(uuidString: deterministicUUID(id))!,
            color: .red,
            lineWidth: 0.005,
            points: [StrokePoint(x: 0.5, y: 0.5, t: 0)],
            autoClearAfterSeconds: nil
        )
    }

    private func deterministicUUID(_ tag: String) -> String {
        // Pad/truncate to a stable UUID-ish string so test asserts can compare ids by name.
        let hex = tag.unicodeScalars.map { String(format: "%02X", min(UInt32($0.value), 0xFF)) }.joined()
        let padded = (hex + String(repeating: "0", count: 32)).prefix(32)
        let s = String(padded)
        let chunks = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4),
                      s.dropFirst(16).prefix(4), s.dropFirst(20).prefix(12)].map(String.init)
        return chunks.joined(separator: "-")
    }

    /// A drag stroke with `pointCount` evenly-spaced points over `durationSeconds`.
    /// The stored stroke event's `recordTime` is the END of the stroke.
    private func dragStroke(id: String, durationSeconds: Double, pointCount: Int) -> Stroke {
        let dt = durationSeconds / Double(pointCount - 1)
        let points = (0..<pointCount).map { i in
            StrokePoint(x: 0.5, y: 0.5, t: Double(i) * dt)
        }
        return Stroke(
            id: UUID(uuidString: deterministicUUID(id))!,
            color: .red,
            lineWidth: 0.005,
            points: points,
            autoClearAfterSeconds: nil
        )
    }

    private func makeClip(events: [CommentaryEvent]) -> Clip {
        Clip(name: "t", sourceIndex: 0, startSourceSeconds: 0,
             recordingDuration: 100, recordingFilename: "t.mov",
             events: events, sortIndex: 0)
    }
}
