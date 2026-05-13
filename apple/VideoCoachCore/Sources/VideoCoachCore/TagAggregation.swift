import Foundation

public struct TagSummary: Hashable, Sendable {
    public var tag: String
    public var clipCount: Int
    public var totalDurationSeconds: Double

    public init(tag: String, clipCount: Int, totalDurationSeconds: Double) {
        self.tag = tag
        self.clipCount = clipCount
        self.totalDurationSeconds = totalDurationSeconds
    }
}

public enum TagAggregation {
    public static func aggregate(project: Project) -> [TagSummary] {
        var byTag: [String: (count: Int, dur: Double)] = [:]
        for clip in project.clips {
            for tag in clip.tags {
                let cur = byTag[tag] ?? (0, 0)
                byTag[tag] = (cur.count + 1, cur.dur + clip.recordingDuration)
            }
        }
        return byTag
            .map { TagSummary(tag: $0.key, clipCount: $0.value.count, totalDurationSeconds: $0.value.dur) }
            .sorted { $0.tag < $1.tag }
    }
}
