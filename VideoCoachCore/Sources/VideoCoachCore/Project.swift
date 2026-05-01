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
        sortIndex: Int,
        createdAt: Date = .init()
    ) {
        self.id = id; self.name = name; self.notes = notes; self.tags = tags
        self.sourceIndex = sourceIndex; self.startSourceSeconds = startSourceSeconds
        self.recordingDuration = recordingDuration; self.recordingFilename = recordingFilename
        self.events = events; self.sortIndex = sortIndex; self.createdAt = createdAt
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int = 1
    public var name: String
    public var sourceVideos: [SourceRef] = []
    public var clips: [Clip] = []
    public var preferences: Preferences = .init()
    public init(name: String) { self.name = name }
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
}
