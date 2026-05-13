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
        // Source at recordTime 2 = 102 (started at 100 + 2s of play).
        // User resumes at recordTime 4 from same source-time (102).
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 2.0, kind: .pause(sourceTime: 102)),
            .init(recordTime: 4.0, kind: .play(sourceTime: 102)),
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
            .init(recordTime: 2, kind: .pause(sourceTime: 12)),
            .init(recordTime: 4, kind: .play(sourceTime: 12)),
        ])
        let segs = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs.map(\.kind), [.play, .freeze, .play])
        XCTAssertEqual(segs[0].outDuration, 2)
        XCTAssertEqual(segs[1].outDuration, 2)
        XCTAssertEqual(segs[2].outDuration, 6)
    }

    /// Skipping past sourceDuration converts the post-skip "play" tail into
    /// a `.freeze` on the last available source frame — mirrors mpv's
    /// behavior at EOF and, critically, avoids the AVPlayer compositor
    /// stall caused by a `.play` segment whose CMTimeRange read range falls
    /// past the source asset's bounds (which silently fails the
    /// `insertTimeRange` and leaves a hole in the source track).
    func test_segments_clampSourceToBounds_onSkip() {
        let clip = makeClip(start: 998, events: [
            .init(recordTime: 1, kind: .skip(delta: 100)),
        ])
        let segs = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs[1].kind, .freeze,
            "play tail past sourceDuration must be realized as a freeze on the last frame")
        XCTAssertLessThan(segs[1].sourceStart, 1000,
            "freeze sourceStart must stay strictly inside source bounds so the 1-tick read range doesn't read past EOF")
        // Freeze sourceStart sits ~50ms back from EOF so the 1-tick read
        // slice is safely inside the last source sample at any reasonable
        // source fps; see `freezeMaxSource` in playbackSegments.
        XCTAssertEqual(segs[1].sourceStart, 999.95, accuracy: 1e-9)
    }

    /// Continuous-gesture zoom (~60Hz pinch) produces hundreds of `.zoom`
    /// events. Those must NOT split the timeline into hundreds of
    /// segments — only state-changing events (play/pause/skip) get
    /// boundaries. Without this invariant, ClipPreviewBuilder turns each
    /// zoom-event boundary into a separate `insertTimeRange +
    /// scaleTimeRange` call on the source track, and AVPlayer's
    /// playback compositor stalls on the 900-slice composition
    /// (manifests as "video freezes after first zoom, audio plays on" —
    /// the user-reported regression that drove this fix).
    func test_segments_zoomEventsDoNotMultiplySegmentCount() {
        var events: [CommentaryEvent] = [
            .init(recordTime: 0, kind: .pause(sourceTime: 0)),
        ]
        // Simulate a 3-second continuous pinch at 60Hz = 180 zoom events.
        // Real user clips have hit ~860; even 180 catches the regression
        // because the buggy implementation produced segments.count = N+1
        // (one per event boundary).
        for i in 0..<180 {
            let t = 0.5 + Double(i) * (3.0 / 180.0)
            events.append(.init(recordTime: t,
                kind: .zoom(Zoom(scale: 1.0 + Double(i) * 0.005, panX: 0, panY: 0))))
        }
        let clip = Clip(
            name: "pinch", sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 5,
            recordingFilename: "p.mov",
            events: events,
            sortIndex: 0
        )
        let segs = clip.playbackSegments(sourceDuration: 100)
        // The whole clip is one continuous freeze (rate=0 set by the
        // single .pause and never changed). Zoom events don't change
        // rate, so they shouldn't produce additional segments.
        XCTAssertEqual(segs.count, 1,
            "180 zoom events on top of a single pause must produce 1 segment, got \(segs.count) — zoom events are leaking into segment boundaries again")
        XCTAssertEqual(segs[0].kind, .freeze)
        XCTAssertEqual(segs[0].outDuration, 5, accuracy: 1e-9)
    }

    /// Every `.play` segment must have a fully in-bounds source range —
    /// otherwise `insertTimeRange` silently fails on the AVPlayer playback
    /// path, leaving a hole that stalls both source and webcam video while
    /// audio keeps playing.
    func test_segments_allPlayRangesAreInBounds_evenAfterFFPastEnd() {
        let sourceDuration: Double = 30
        let clip = Clip(
            name: "ff",
            sourceIndex: 0,
            startSourceSeconds: 25,
            recordingDuration: 20,
            recordingFilename: "f.mov",
            events: [
                .init(recordTime: 1, kind: .skip(delta: 10)),   // jumps to 30 (clamped)
                .init(recordTime: 5, kind: .pause(sourceTime: 30)),
                .init(recordTime: 8, kind: .play(sourceTime: 30)),
            ],
            sortIndex: 0
        )
        let segs = clip.playbackSegments(sourceDuration: sourceDuration)
        for (i, seg) in segs.enumerated() where seg.kind == .play {
            XCTAssertLessThanOrEqual(
                seg.sourceStart + seg.outDuration, sourceDuration,
                "segment \(i) (\(seg.kind)) reads past sourceDuration: " +
                "\(seg.sourceStart) + \(seg.outDuration) > \(sourceDuration)"
            )
        }
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
                .init(recordTime: 1.0,    kind: .pause(sourceTime: 1.0)),
                .init(recordTime: 1.0005, kind: .play(sourceTime: 1.0)),
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
