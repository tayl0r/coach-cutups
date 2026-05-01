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
        mpv_observe_property(h, 1, "pause",          MPV_FORMAT_FLAG)
        mpv_observe_property(h, 2, "playlist-count", MPV_FORMAT_INT64)
        mpv_observe_property(h, 3, "playlist-pos",   MPV_FORMAT_INT64)
        mpv_observe_property(h, 4, "time-pos",       MPV_FORMAT_DOUBLE)
        let pump = Thread { [handle = h] in
            while true {
                guard let evt = mpv_wait_event(handle, 0.1) else { continue }
                let id = evt.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_PROPERTY_CHANGE {
                    let prop = UnsafeMutableRawPointer(evt.pointee.data)?
                        .assumingMemoryBound(to: mpv_event_property.self).pointee
                    let userdata = evt.pointee.reply_userdata
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch userdata {
                        case 1:
                            if let data = prop?.data {
                                self.isPaused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            }
                        case 2:
                            if let data = prop?.data {
                                self.playlistCount = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                            }
                        case 3:
                            if let data = prop?.data {
                                self.playlistPos = Int(max(0, data.assumingMemoryBound(to: Int64.self).pointee))
                            }
                        case 4:
                            if let data = prop?.data {
                                let v = data.assumingMemoryBound(to: Double.self).pointee
                                if v.isFinite { self.timePos = v }
                            }
                        default: break
                        }
                    }
                    continue
                }
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

    public func setPlaylist(_ paths: [String]) {
        // Bump generation FIRST so any in-flight pending seek's completion
        // is dropped before we issue the playlist-clear (which itself can
        // generate a PLAYBACK_RESTART that we don't want fired). See
        // adversarial review history in plan front-matter.
        bumpGeneration()
        playlistPaths = paths
        runCommandSync(["playlist-clear"])
        for p in paths {
            runCommandSync(["loadfile", p, "append"])
        }
    }

    public func play() {
        var flag: Int32 = 0
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func pause() {
        var flag: Int32 = 1
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func togglePlay() {
        if isPaused { play() } else { pause() }
    }

    public func setVolume(_ v: Double) {
        var mpvVolume = max(0, min(100, v * 100))
        mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &mpvVolume)
    }

    private func runCommandSync(_ args: [String]) {
        var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
        defer { cstrings.forEach { if let p = $0 { free(p) } } }
        cstrings.withUnsafeMutableBufferPointer { buf in
            let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            _ = mpv_command(handle, p)
        }
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
    case alreadyAttached
    case renderContextFailed(code: Int)
}
