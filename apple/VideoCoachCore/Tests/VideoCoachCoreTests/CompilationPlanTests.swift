import XCTest
@testable import VideoCoachCore

final class CompilationPlanTests: XCTestCase {
    // MARK: - tag filtering

    func test_compilationPlan_filtersByTag_excludingClipsWithoutTag() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "a", tags: ["forehand"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 5, sortIndex: 0),
            makeClip(name: "b", tags: ["backhand"], sourceIndex: 0,
                     startSourceSeconds: 10, recordingDuration: 4, sortIndex: 1),
            makeClip(name: "c", tags: ["forehand", "serve"], sourceIndex: 0,
                     startSourceSeconds: 20, recordingDuration: 3, sortIndex: 2),
        ]

        let plan = project.compilationPlan(for: "forehand", sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries.map(\.clipID), [project.clips[0].id, project.clips[2].id])
    }

    // MARK: - sort order within tag

    func test_compilationPlan_sortsBySortIndexAscending() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "later", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 5, sortIndex: 9),
            makeClip(name: "earlier", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 5, sortIndex: 1),
            makeClip(name: "middle", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 5, sortIndex: 4),
        ]

        let plan = project.compilationPlan(for: "t", sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries.map(\.clipID),
                       [project.clips[1].id, project.clips[2].id, project.clips[0].id])
    }

    // MARK: - compositionStart accumulation

    func test_compilationPlan_compositionStart_accumulatesPrecedingDurations() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "a", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 4, sortIndex: 0),
            makeClip(name: "b", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 7, sortIndex: 1),
            makeClip(name: "c", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 2, sortIndex: 2),
        ]

        let plan = project.compilationPlan(for: "t", sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries.count, 3)
        XCTAssertEqual(plan.entries[0].compositionStart, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.entries[1].compositionStart, 4, accuracy: 1e-9)
        XCTAssertEqual(plan.entries[2].compositionStart, 11, accuracy: 1e-9)
        XCTAssertEqual(plan.totalDurationSeconds, 13, accuracy: 1e-9)
    }

    // MARK: - indexInOutput

    func test_compilationPlan_indexInOutput_isZeroBasedAndMonotonic() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "a", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 1, sortIndex: 5),
            makeClip(name: "b", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 1, sortIndex: 7),
        ]

        let plan = project.compilationPlan(for: "t", sourceDurations: [0: 10])

        XCTAssertEqual(plan.entries.map(\.indexInOutput), [0, 1])
    }

    // MARK: - empty tag

    func test_compilationPlan_emptyTagYieldsZeroEntriesAndZeroDuration() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "a", tags: ["forehand"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 5, sortIndex: 0),
        ]

        let plan = project.compilationPlan(for: "missing", sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries, [])
        XCTAssertEqual(plan.totalDurationSeconds, 0, accuracy: 1e-9)
    }

    // MARK: - all-clips ordering

    func test_allClipsCompilationPlan_includesEveryClipOrderedBySortIndex() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "tagged", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 3, sortIndex: 1),
            makeClip(name: "untagged", tags: [], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 2, sortIndex: 0),
            makeClip(name: "another", tags: ["x", "y"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 4, sortIndex: 2),
        ]

        let plan = project.allClipsCompilationPlan(sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries.map(\.clipID),
                       [project.clips[1].id, project.clips[0].id, project.clips[2].id])
        XCTAssertEqual(plan.entries.map(\.indexInOutput), [0, 1, 2])
        XCTAssertEqual(plan.totalDurationSeconds, 9, accuracy: 1e-9)
        XCTAssertEqual(plan.entries[0].compositionStart, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.entries[1].compositionStart, 2, accuracy: 1e-9)
        XCTAssertEqual(plan.entries[2].compositionStart, 5, accuracy: 1e-9)
    }

    // MARK: - segments populated via per-clip sourceDuration

    func test_compilationPlan_segments_useSourceDurationForCorrespondingClip() {
        // A clip with a forward skip event near the source's end. The skip should
        // clamp at sourceDuration as supplied for that clip's sourceIndex.
        let clip = makeClip(
            name: "edge",
            tags: ["t"],
            sourceIndex: 7,
            startSourceSeconds: 998,
            recordingDuration: 3,
            sortIndex: 0,
            events: [.init(recordTime: 1, kind: .skip(delta: 100))]
        )
        var project = Project(name: "p")
        project.clips = [clip]

        let plan = project.compilationPlan(for: "t", sourceDurations: [7: 1000])

        XCTAssertEqual(plan.entries.count, 1)
        let segs = plan.entries[0].segments
        let expected = clip.playbackSegments(sourceDuration: 1000)
        XCTAssertEqual(segs, expected)
        // Sanity-check: the post-skip segment is clamped at the supplied source duration.
        XCTAssertEqual(segs[1].sourceStart, 1000, accuracy: 1e-9)
    }

    func test_compilationPlan_recordingDuration_perEntryMatchesClip() {
        var project = Project(name: "p")
        project.clips = [
            makeClip(name: "a", tags: ["t"], sourceIndex: 0,
                     startSourceSeconds: 0, recordingDuration: 6.25, sortIndex: 0),
        ]

        let plan = project.compilationPlan(for: "t", sourceDurations: [0: 100])

        XCTAssertEqual(plan.entries[0].recordingDuration, 6.25, accuracy: 1e-9)
    }

    // MARK: - missing source duration falls back without crashing

    func test_compilationPlan_missingSourceDuration_fallsBackGracefully() {
        // Clip references sourceIndex 3 but the dictionary doesn't contain it.
        // The fallback must yield a sensible segment list (not crash, not produce NaN).
        let clip = makeClip(
            name: "fb",
            tags: ["t"],
            sourceIndex: 3,
            startSourceSeconds: 0,
            recordingDuration: 5,
            sortIndex: 0
        )
        var project = Project(name: "p")
        project.clips = [clip]

        let plan = project.compilationPlan(for: "t", sourceDurations: [:])

        XCTAssertEqual(plan.entries.count, 1)
        let segs = plan.entries[0].segments
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.map(\.outDuration).reduce(0, +), 5, accuracy: 1e-9)
    }

    // MARK: - helpers

    private func makeClip(
        name: String,
        tags: [String],
        sourceIndex: Int,
        startSourceSeconds: Double,
        recordingDuration: Double,
        sortIndex: Int,
        events: [CommentaryEvent] = []
    ) -> Clip {
        Clip(
            name: name,
            tags: tags,
            sourceIndex: sourceIndex,
            startSourceSeconds: startSourceSeconds,
            recordingDuration: recordingDuration,
            recordingFilename: "\(name).mov",
            events: events,
            sortIndex: sortIndex
        )
    }
}
