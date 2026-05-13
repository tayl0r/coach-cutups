import Foundation
import os.log

/// Shared `os.Logger` namespace for the whole app.
///
/// All loggers route to subsystem `com.coachcutups.app`; categories let us
/// filter / route per concern. Use the system `log` CLI to tail:
///
///     log stream --predicate 'subsystem == "com.coachcutups.app"'
///     log stream --predicate 'subsystem == "com.coachcutups.app" AND category == "export"'
///     log show --last 5m --predicate 'subsystem == "com.coachcutups.app"' --style compact
///
/// Apple frameworks (AVFoundation, CoreMedia, VideoToolbox) emit on their own
/// subsystems; pair our stream with those when chasing a failure mode that
/// straddles us and AVFoundation:
///
///     log stream --predicate '(subsystem == "com.coachcutups.app") OR
///                              (subsystem CONTAINS "com.apple.coremedia") OR
///                              (subsystem CONTAINS "com.apple.avfoundation")'
public enum Log {
    public static let subsystem = "com.coachcutups.app"

    /// Pure-logic core: data model, timeline reconstruction, project IO.
    public static let core = Logger(subsystem: subsystem, category: "core")
    /// Export pipeline: composition build, video composition, audio mix,
    /// AVAssetExportSession lifecycle, error chains.
    public static let export = Logger(subsystem: subsystem, category: "export")
    /// Mode C preview: ClipPreviewBuilder, freeze-frame pre-decode, cache
    /// inflight/failure tracking.
    public static let preview = Logger(subsystem: subsystem, category: "preview")
    /// Both CompilationCompositor and PreviewCompositor: subclass-cast
    /// outcomes, frame-level fallbacks. Per-frame logs use `.debug` to
    /// avoid spamming `info`-and-above streams.
    public static let compositor = Logger(subsystem: subsystem, category: "compositor")
}
