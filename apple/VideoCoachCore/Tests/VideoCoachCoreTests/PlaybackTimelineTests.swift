import CoreMedia
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

    func test_segments_simpleClip_oneSegmentEntireDuration() {
        let clip = makeClip(start: 10, events: [])
        let segs = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, .play)
        XCTAssertEqual(segs[0].sourceStart, 10)
        XCTAssertEqual(segs[0].outDuration, 10) // recordingDuration
    }

    func test_segments_pauseProducesFreezeAndPlaySegments() {
        let clip = makeClip(start: 10, events: [
            .init(recordTime: 2, kind: .pause),
            .init(recordTime: 4, kind: .play),
        ])
        let segs = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs.map(\.kind), [.play, .freeze, .play])
        XCTAssertEqual(segs[0].outDuration, 2)
        XCTAssertEqual(segs[1].outDuration, 2)
        XCTAssertEqual(segs[2].outDuration, 6)
    }

    func test_segments_clampSourceToBounds_onSkip() {
        let clip = makeClip(start: 998, events: [
            .init(recordTime: 1, kind: .skip(delta: 100)),
        ])
        let segs = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs[1].sourceStart, 1000) // clamped at end
    }

    /// Regression: two events <1ms apart can produce a play segment whose
    /// `outDuration` rounds to **zero** ticks at AVFoundation's preferred
    /// 600 Hz timescale (since `0.5ms × 600 = 0.3 < 0.5`). Downstream
    /// `insertTimeRange(_:of:at:)` rejects empty CMTimeRanges with
    /// `AVFoundationErrorDomain -11800 / OSStatus -12780`, which broke
    /// preview build for any clip whose continuous-pinch zoom gestures
    /// straddled a play/pause boundary. ClipPreviewBuilder and
    /// CompilationExporter defend against this by skipping zero-tick
    /// segments. This test documents the trigger condition so the guard
    /// can't silently regress.
    func test_segments_subMillisecondEventGap_roundsToZeroCMTime() {
        let clip = Clip(
            name: "tiny",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 10,
            recordingFilename: "t.mov",
            events: [
                .init(recordTime: 1.0,    kind: .pause),
                .init(recordTime: 1.0005, kind: .play),
            ],
            sortIndex: 0
        )
        let segs = clip.playbackSegments(sourceDuration: 100)
        guard let tiny = segs.first(where: { $0.outDuration > 0 && $0.outDuration < 0.001 }) else {
            XCTFail("expected a sub-millisecond segment from 0.5ms-spaced events; got \(segs)")
            return
        }
        let cmDur = CMTime(seconds: tiny.outDuration, preferredTimescale: 600)
        XCTAssertEqual(
            cmDur, .zero,
            "sub-millisecond outDuration should round to zero ticks at timescale 600 — this is the AVFoundation rejection trigger that callers guard against"
        )
    }

    private func makeClip(start: Double, events: [CommentaryEvent]) -> Clip {
        Clip(name: "t", sourceIndex: 0, startSourceSeconds: start,
             recordingDuration: 10, recordingFilename: "t.mov",
             events: events, sortIndex: 0)
    }
}
