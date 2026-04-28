import Foundation

/// A pure-data description of an output composition built from one or more clips.
/// No AVFoundation dependency: the export layer consumes this to drive composition,
/// instructions, and overlays.
public struct CompilationPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var clipID: UUID
        /// Zero-based position in the output, used for "i/N" overlays.
        public var indexInOutput: Int
        /// Offset in seconds from the start of the output composition.
        public var compositionStart: Double
        /// Walked playback segments (`.play` / `.freeze`) for the clip.
        public var segments: [PlaybackSegment]
        /// The clip's recording duration (== sum of `segments[].outDuration`).
        public var recordingDuration: Double

        public init(
            clipID: UUID,
            indexInOutput: Int,
            compositionStart: Double,
            segments: [PlaybackSegment],
            recordingDuration: Double
        ) {
            self.clipID = clipID
            self.indexInOutput = indexInOutput
            self.compositionStart = compositionStart
            self.segments = segments
            self.recordingDuration = recordingDuration
        }
    }

    public var totalDurationSeconds: Double
    public var entries: [Entry]

    public init(totalDurationSeconds: Double, entries: [Entry]) {
        self.totalDurationSeconds = totalDurationSeconds
        self.entries = entries
    }
}

public extension Project {
    /// Build a compilation plan from clips carrying `tag`, ordered by `sortIndex`.
    func compilationPlan(for tag: String, sourceDurations: [Int: Double]) -> CompilationPlan {
        let filtered = clips.filter { $0.tags.contains(tag) }
        return Self.buildPlan(from: filtered, sourceDurations: sourceDurations)
    }

    /// Build a compilation plan from every clip in the project, ordered by `sortIndex`.
    func allClipsCompilationPlan(sourceDurations: [Int: Double]) -> CompilationPlan {
        Self.buildPlan(from: clips, sourceDurations: sourceDurations)
    }

    private static func buildPlan(
        from clips: [Clip],
        sourceDurations: [Int: Double]
    ) -> CompilationPlan {
        let ordered = clips.sorted { $0.sortIndex < $1.sortIndex }
        var entries: [CompilationPlan.Entry] = []
        entries.reserveCapacity(ordered.count)
        var cursor = 0.0
        for (index, clip) in ordered.enumerated() {
            // Fall back to a duration that never causes the segment builder to
            // clamp a forward skip (the only place it consults sourceDuration).
            // `recordingDuration + startSourceSeconds` is the smallest value that
            // is guaranteed to cover any in-range source position the clip
            // actually visits at rate=1.
            let sourceDuration = sourceDurations[clip.sourceIndex]
                ?? (clip.startSourceSeconds + clip.recordingDuration)
            let segments = clip.playbackSegments(sourceDuration: sourceDuration)
            entries.append(.init(
                clipID: clip.id,
                indexInOutput: index,
                compositionStart: cursor,
                segments: segments,
                recordingDuration: clip.recordingDuration
            ))
            cursor += clip.recordingDuration
        }
        return CompilationPlan(totalDurationSeconds: cursor, entries: entries)
    }
}
