import Foundation

public enum Tag {
    public static func normalize(input: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for fragment in input.split(separator: ",") {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }
}

public enum Resolution: String, Codable, Sendable, CaseIterable { case source, r1080, r720 }
public enum Quality: String, Codable, Sendable, CaseIterable { case low, medium, high }

public struct Preferences: Codable, Hashable, Sendable {
    public var scanVolume: Double = 1.0
    public var previewSourceVolume: Double = 1.0
    public var previewCommentaryVolume: Double = 1.0
    public var lastExportResolution: Resolution = .r1080
    public var lastExportQuality: Quality = .medium
    /// `AVCaptureDevice.uniqueID` of the user's preferred camera. `nil` means
    /// "use the system default." If the saved device is not present at launch
    /// (e.g. an unplugged USB cam), the app falls back to the system default
    /// without clearing this — so the preference is restored if the device
    /// reappears.
    public var preferredCameraID: String? = nil
    /// `AVCaptureDevice.uniqueID` of the user's preferred microphone. Same
    /// fallback semantics as `preferredCameraID`.
    public var preferredMicID: String? = nil
    public var pipForNewRecordings: Bool = true
    public init() {}
}

public struct SourceRef: Codable, Hashable, Sendable {
    public var bookmark: Data
    public var displayName: String
    public var durationSeconds: Double
    public init(bookmark: Data, displayName: String, durationSeconds: Double) {
        self.bookmark = bookmark; self.displayName = displayName; self.durationSeconds = durationSeconds
    }
}

public struct Clip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var tags: [String]

    public var sourceIndex: Int
    public var startSourceSeconds: Double
    public var recordingDuration: Double

    public var recordingFilename: String

    public var events: [CommentaryEvent]
    public var showPiP: Bool
    public var sortIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        tags: [String] = [],
        sourceIndex: Int,
        startSourceSeconds: Double,
        recordingDuration: Double,
        recordingFilename: String,
        events: [CommentaryEvent] = [],
        showPiP: Bool = true,
        sortIndex: Int,
        createdAt: Date = .init()
    ) {
        self.id = id; self.name = name; self.notes = notes; self.tags = tags
        self.sourceIndex = sourceIndex; self.startSourceSeconds = startSourceSeconds
        self.recordingDuration = recordingDuration; self.recordingFilename = recordingFilename
        self.events = events
        self.showPiP = showPiP
        self.sortIndex = sortIndex; self.createdAt = createdAt
    }
}

public struct Project: Codable, Hashable, Sendable {
    /// JSON schema version. See `currentFormatVersion` for migration history.
    public var formatVersion: Int = Project.currentFormatVersion
    public var name: String
    public var sourceVideos: [SourceRef] = []
    public var clips: [Clip] = []
    public var preferences: Preferences = .init()
    public var scoreboard: ScoreboardConfig? = nil
    public var matchEvents: [MatchEventRecord] = []
    public init(name: String) { self.name = name }

    // Custom decoder so legacy JSON (v1/v2) lacking `matchEvents` decodes
    // cleanly with the field defaulting to []. `scoreboard` is Optional so it
    // already decodes to nil when missing — but we still need to teach the
    // synthesised decoder to tolerate the missing array key.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, sourceVideos, clips, preferences, scoreboard, matchEvents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Default to 1 (not `currentFormatVersion`) when the key is missing:
        // a file with no `formatVersion` predates the field, which means v1.
        // Defaulting to current would silently bypass the `ProjectStore.read`
        // upper-bound guard.
        self.formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        self.name = try c.decode(String.self, forKey: .name)
        self.sourceVideos = try c.decodeIfPresent([SourceRef].self, forKey: .sourceVideos) ?? []
        self.clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        self.preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? .init()
        self.scoreboard = try c.decodeIfPresent(ScoreboardConfig.self, forKey: .scoreboard)
        self.matchEvents = try c.decodeIfPresent([MatchEventRecord].self, forKey: .matchEvents) ?? []
    }
}

public extension Project {
    /// Migration history:
    /// - v1: original schema (no formatVersion field)
    /// - v2: added `.zoom` event variant
    /// - v3: added per-clip PiP visibility (`Clip.showPiP`,
    ///   `Preferences.pipForNewRecordings`). v1/v2 files migrate via
    ///   `ProjectStore.migrateIfNeeded` (in-blob field injection).
    /// - v4: added `scoreboard` (TeamConfig + MatchFormat) and `matchEvents`.
    ///   v3 files lacking these keys decode cleanly via `Project.init(from:)`'s
    ///   `decodeIfPresent`.
    static let currentFormatVersion: Int = 4
}

public extension Project {
    /// Sum of all sourceVideos' durations.
    var totalSourceDuration: Double {
        sourceVideos.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Cumulative offset of the source at `forSourceIndex` within the
    /// virtual concat. Equal to `sum(durations[0..<i])` clamped to
    /// `[0, totalSourceDuration]`.
    func cumulativeOffset(forSourceIndex i: Int) -> Double {
        if sourceVideos.isEmpty { return 0 }
        let clamped = max(0, min(i, sourceVideos.count))
        var sum: Double = 0
        for k in 0..<clamped { sum += sourceVideos[k].durationSeconds }
        return sum
    }

    /// Absolute time on the virtual-concat timeline for a (sourceIndex, sourceSeconds) pair.
    func absSeconds(sourceIndex: Int, sourceSeconds: Double) -> Double {
        cumulativeOffset(forSourceIndex: sourceIndex) + sourceSeconds
    }
}
