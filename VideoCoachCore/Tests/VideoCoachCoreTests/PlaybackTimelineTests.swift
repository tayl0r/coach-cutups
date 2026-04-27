import XCTest
@testable import VideoCoachCore

final class PlaybackTimelineTests: XCTestCase {
    func test_noEvents_advancesAtRate1() {
        let clip = makeClip(start: 100, events: [])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 0), 100, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 5), 105, accuracy: 1e-9)
    }

    func test_pauseAndResume_freezesSource() {
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 2.0, kind: .pause),
            .init(recordTime: 4.0, kind: .play),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 1.0), 101, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 102, accuracy: 1e-9) // frozen
        XCTAssertEqual(clip.sourceTime(atRecordTime: 5.0), 103, accuracy: 1e-9) // resumed
    }

    func test_skipForwardJumpsSourceWithoutAdvancingRecord() {
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 2.0, kind: .skip(delta: 3)),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 1.0), 101, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 2.0), 105, accuracy: 1e-9) // jumped
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 106, accuracy: 1e-9)
    }

    func test_strokeAndClearAllAreNoOps_forSourceTime() {
        let stroke = Stroke(color: .red, lineWidth: 0.005, points: [], autoClearAfterSeconds: nil)
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 1.0, kind: .stroke(stroke)),
            .init(recordTime: 2.0, kind: .clearAll),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 103, accuracy: 1e-9)
    }

    private func makeClip(start: Double, events: [CommentaryEvent]) -> Clip {
        Clip(name: "t", sourceIndex: 0, startSourceSeconds: start,
             recordingDuration: 10, recordingFilename: "t.mov",
             events: events, sortIndex: 0)
    }
}
