import Foundation

/// One output `.mp4` in a multi-video export run. The `id` is either a tag
/// key (e.g. `"shot"`) or the `all-clips` sentinel string supplied by the
/// caller — it just needs to be unique within the run.
public struct VideoExportItem: Sendable, Identifiable, Equatable {
    public enum Status: Sendable, Equatable {
        case pending
        case active(fractionCompleted: Float)
        case done(encodeWallSeconds: Double, averageFps: Double)
    }

    public let id: String
    public let displayName: String
    public let videoDurationSeconds: Double
    public var status: Status

    public init(
        id: String,
        displayName: String,
        videoDurationSeconds: Double,
        status: Status = .pending
    ) {
        self.id = id
        self.displayName = displayName
        self.videoDurationSeconds = videoDurationSeconds
        self.status = status
    }
}

/// Snapshot of the export run handed to the UI on every sampler tick or
/// status transition. All fields are derived; `ExportSheet` recomputes the
/// whole struct on each update.
public struct ExportProgress: Sendable, Equatable {
    public let items: [VideoExportItem]
    public let currentRenderingFps: Double?
    public let totalVideoSecondsRemaining: Double
    public let totalEtaSeconds: Double?
    public let projectedCompletionDate: Date?

    public init(
        items: [VideoExportItem],
        currentRenderingFps: Double?,
        totalVideoSecondsRemaining: Double,
        totalEtaSeconds: Double?,
        projectedCompletionDate: Date?
    ) {
        self.items = items
        self.currentRenderingFps = currentRenderingFps
        self.totalVideoSecondsRemaining = totalVideoSecondsRemaining
        self.totalEtaSeconds = totalEtaSeconds
        self.projectedCompletionDate = projectedCompletionDate
    }
}

/// Result of projecting the remaining run against a measured (or fallback)
/// encoding rate. Pure data; the UI reads it directly.
public struct RunProjection: Sendable, Equatable {
    /// Wall-time seconds remaining across active + pending items.
    public let totalSecondsRemaining: Double
    /// Per-item wall-time remaining, keyed by `VideoExportItem.id`. Pending
    /// items get their full duration ÷ rate; the active item gets the
    /// remaining fraction ÷ rate. Done items are absent.
    public let perItemRemaining: [String: Double]
    /// Per-item absolute clock time at which it's projected to finish,
    /// keyed by `VideoExportItem.id`. Includes done items at their actual
    /// finish time when supplied.
    public let perItemDoneDate: [String: Date]

    public init(
        totalSecondsRemaining: Double,
        perItemRemaining: [String: Double],
        perItemDoneDate: [String: Date]
    ) {
        self.totalSecondsRemaining = totalSecondsRemaining
        self.perItemRemaining = perItemRemaining
        self.perItemDoneDate = perItemDoneDate
    }

    public static let empty = RunProjection(
        totalSecondsRemaining: 0,
        perItemRemaining: [:],
        perItemDoneDate: [:]
    )
}

/// Rolling-window estimator of composition-seconds-per-wall-second. Used by
/// `ExportSheet` to drive the run-level rate. See spec for the sufficiency
/// gate (≥5 samples AND ≥2s wall time across surviving samples).
public struct RollingRate: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let wallTime: Double
        let encodedCompSeconds: Double
    }

    public let windowSeconds: Double
    var samples: [Sample] = []

    public init(windowSeconds: Double = 30) {
        self.windowSeconds = windowSeconds
    }

    /// Append a sample (clamped to non-decreasing encoded seconds) and evict
    /// samples older than `windowSeconds` from the front.
    public mutating func record(wallTime: Double, encodedCompSeconds: Double) {
        // Body implemented in Task 2.
        _ = wallTime
        _ = encodedCompSeconds
    }

    /// Composition seconds per wall second, or nil when the sample window
    /// hasn't reached the sufficiency gate.
    public func compositionSecondsPerWallSecond() -> Double? {
        // Body implemented in Task 2.
        return nil
    }
}

/// Project the remaining run forward at the given rate. See spec for math.
/// `rate` MUST be > 0; callers fall back to `1.0` (realtime) before a real
/// measurement is available.
public func projectRun(
    items: [VideoExportItem],
    rate: Double,
    now: Date
) -> RunProjection {
    // Body implemented in Task 3.
    _ = items
    _ = rate
    _ = now
    return .empty
}
