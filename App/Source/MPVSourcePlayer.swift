import Foundation
import Observation
import QuartzCore
import Libmpv  // module name confirmed in Phase 1 (NOT "MPVKit"; MPVKit's modulemap names the umbrella module Libmpv)

/// Wraps a persistent mpv_handle for source-playback (D2 in the design).
/// One instance per Workspace; setPlaylist() reuses it across rebuilds.
@MainActor
@Observable
public final class MPVSourcePlayer {
    /// hwdec value chosen during Phase 1's gate. Recorded here as the
    /// source of truth. Phase 1 confirmed videotoolbox plays the test
    /// file smoothly — the assumption that mpv-via-VT shared
    /// AVFoundation's broken HEVC decoder turned out to be false.
    private static let hwdecOption = "videotoolbox"

    fileprivate let handle: OpaquePointer
    fileprivate var renderContext: OpaquePointer?
    fileprivate let renderLock = NSLock()

    /// Cached playlist paths in the order setPlaylist received them.
    /// Used by seek() to avoid mpv_get_property("playlist/<i>/filename")
    /// from the main actor.
    fileprivate var playlistPaths: [String] = []

    // Observed state — all updated from the event pump (Task 3.3).
    public private(set) var isPaused: Bool = true
    public private(set) var playlistCount: Int = 0
    public private(set) var playlistPos: Int = 0
    public private(set) var timePos: Double = 0
    public private(set) var generation: UInt64 = 0

    // Single-slot pending-seek tracking (Task 3.7).
    fileprivate struct PendingSeek {
        let replyID: UInt64
        let generation: UInt64
        let completion: @MainActor () -> Void
        /// Holds the strdup'd argv alive past mpv_command_async's return,
        /// freed on MPV_EVENT_COMMAND_REPLY (Task 3.7).
        var cstrings: [UnsafeMutablePointer<CChar>?]
        var commandReplied: Bool
    }
    fileprivate var pending: PendingSeek?
    fileprivate var nextReplyID: UInt64 = 100

    private var pumpThread: Thread?

    public init() throws {
        guard let h = mpv_create() else { throw MPVSourcePlayerError.createFailed }
        for (k, v) in [
            ("vo", "libmpv"),
            ("hwdec", Self.hwdecOption),
            ("prefetch-playlist", "yes"),
            ("keep-open", "yes"),
            ("keep-open-pause", "no"),
            ("pause", "yes"),
            ("msg-level", "all=warn"),
            ("audio-display", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("target-colorspace-hint", "yes"),
            // NOTE: "volume-correct" was in the design (D15) but is NOT
            // a real mpv option — Phase 1 implementer caught this.
            // mpv's "volume" property is already linear by default.
        ] {
            mpv_set_option_string(h, k, v)
        }
        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_destroy(h)
            throw MPVSourcePlayerError.initializeFailed(code: Int(rc))
        }
        self.handle = h
        let pump = Thread { [handle = h] in
            while true {
                guard let evt = mpv_wait_event(handle, 0.1) else { continue }
                let id = evt.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN { return }
                // Property + command-reply + playback-restart handlers added in 3.3 / 3.7.
            }
        }
        pump.name = "mpv-event-pump"
        pump.start()
        self.pumpThread = pump
    }

    deinit {
        // mpv_terminate_destroy makes mpv_wait_event return MPV_EVENT_SHUTDOWN
        // which the pump (Task 3.2) uses to exit its loop. The render context
        // is freed by detachRender (called from MPVPlayerView's tearDown).
        mpv_terminate_destroy(handle)
    }

    public func bumpGeneration() {
        generation &+= 1
        // Drop any pending completion that hasn't fired — the bump means
        // we're transitioning to a state where the completion is no
        // longer meaningful.
        pending = nil
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
    case alreadyAttached
    case renderContextFailed(code: Int)
}
