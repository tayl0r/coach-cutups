import Foundation
import Observation
import AppKit
import QuartzCore
import Libmpv  // module name confirmed in Phase 1 (NOT "MPVKit"; MPVKit's modulemap names the umbrella module Libmpv)
import VideoCoachCore

// Render path history:
//   Phase 1 of mpv migration: vo=libmpv + MPV_RENDER_API_TYPE_SW
//     (per-frame CPU staging copy; intentional bring-up choice).
//   Phase 7: vo=libmpv + MPV_RENDER_API_TYPE_OPENGL bridged via IOSurface
//     to a Metal layer (Path A). Eliminated CPU staging copy but pulled
//     in deprecated GL APIs. Persistent mpv handle survived view mount/
//     unmount cycles via attachRenderGL/detachRenderGL.
//   Phase 8 (current): vo=gpu-next + wid=<CAMetalLayer*> (Path B). mpv
//     renders directly via libplacebo → Vulkan → MoltenVK → Metal into a
//     layer we own. The mpv_handle is created on attachLayer (with wid
//     set before mpv_initialize) and torn down on detachLayer; persistent-
//     handle is not possible because mpv's wid option/property is read-
//     only at runtime (verified in plan v2 review). Swift-side fields
//     (playlist paths, position, paused, volume) replay onto the fresh
//     handle on each attach. The MPVKit demo's MPVMetalViewController is
//     the load-bearing reference implementation.

/// Wraps an mpv_handle for source-playback. The handle is not persistent
/// — it is created lazily by `attachLayer(_:)` and torn down by
/// `detachLayer()`. One Swift instance per Workspace; setPlaylist() and
/// other mutations update Swift-side cached state and (when attached)
/// also issue mpv calls. State replays onto the fresh handle on each
/// attach, so the player is "headless" between mounts.
@MainActor
@Observable
public final class MPVSourcePlayer {
    /// hwdec value chosen during Phase 1's gate. Recorded here as the
    /// source of truth.
    private static let hwdecOption = "videotoolbox"

    /// nonisolated(unsafe) because the event-pump thread and detachLayer
    /// access the handle off-main; mpv's C API on a single mpv_handle is
    /// documented thread-safe in client.h. nil between detach and re-
    /// attach. @ObservationIgnored so the @Observable macro doesn't wrap
    /// accesses (which would defeat nonisolated(unsafe)).
    @ObservationIgnored
    private nonisolated(unsafe) var handle: OpaquePointer?

    /// Strong reference to the layer that's currently embedded. Set in
    /// `attachLayer` *after* `mpv_initialize` succeeds; cleared in
    /// `detachLayer` *after* `mpv_terminate_destroy` returns. The
    /// `wid` we set on mpv is `Unmanaged.passUnretained(layer).toOpaque()`
    /// which does NOT retain — this field is the strong ref keeping the
    /// layer alive while mpv has the pointer.
    @ObservationIgnored
    private var attachedLayer: CAMetalLayer?

    private let audioOff: Bool

    /// Cached playlist paths in the order setPlaylist received them.
    /// Replayed onto a fresh handle in attachLayer.
    fileprivate var playlistPaths: [String] = []

    // Observed state — updated from the event pump while attached, and
    // also written directly by play/pause/setVolume so the Swift-side
    // truth is correct even between detach and re-attach (state replays).
    public private(set) var isPaused: Bool = true
    public private(set) var playlistCount: Int = 0
    public private(set) var playlistPos: Int = 0
    public private(set) var timePos: Double = 0
    public private(set) var generation: UInt64 = 0

    /// Cached volume (linear, 0...1). Replayed onto the fresh handle.
    private var volume: Double = 1.0

    /// Cached zoom state. Replayed onto the fresh handle in `attachLayer`
    /// so the user's zoom/pan survives the view-tree swap when they enter
    /// preview mode and return to scanning. `setZoom` is the single
    /// mutation point: it both updates this and writes to mpv (when attached).
    private var zoom: Zoom = .identity

    /// True when at least one file is loaded in the playlist. `playlistPos`
    /// is clamped to 0 even when mpv would report -1 (no file), so callers
    /// must check this instead of `playlistPos >= 0`.
    public var hasLoadedFile: Bool { playlistCount > 0 }

    // Single-slot pending-seek tracking.
    fileprivate struct PendingSeek {
        let replyID: UInt64
        let generation: UInt64
        let completion: @MainActor () -> Void
        /// Holds the strdup'd argv alive past mpv_command_async's return,
        /// freed on MPV_EVENT_COMMAND_REPLY.
        var cstrings: [UnsafeMutablePointer<CChar>?]
        var commandReplied: Bool
    }
    fileprivate var pending: PendingSeek?
    fileprivate var nextReplyID: UInt64 = 100

    @ObservationIgnored
    private nonisolated(unsafe) var pumpThread: Thread?

    /// Signaled by the pump thread when it exits its loop. detachLayer
    /// blocks on this BEFORE calling mpv_terminate_destroy so the pump
    /// can never iterate wait_event on a freed handle. Allocated fresh
    /// per attach (one-shot semaphore: signal() once, wait() once).
    @ObservationIgnored
    private nonisolated(unsafe) var pumpExited: DispatchSemaphore?

    public init(audioOff: Bool = false) {
        self.audioOff = audioOff
        // Handle is created lazily in attachLayer. This makes the player
        // Swift-side construct cheap and aligns lifecycle with the layer
        // it draws into.
    }

    deinit {
        detachLayer()  // idempotent if already detached
    }

    // MARK: - Layer attach / detach

    /// Create a fresh mpv_handle bound to `layer`, replay Swift-side
    /// cached state onto it, and start the event pump. `wid` MUST be set
    /// before `mpv_initialize` — mpv's wid option is documented pre-init-
    /// only and the property is read-only after init.
    public func attachLayer(_ layer: CAMetalLayer) throws {
        precondition(handle == nil, "attachLayer called twice without intervening detachLayer")

        guard let h = mpv_create() else { throw MPVSourcePlayerError.createFailed }

        // wid: integer reinterpretation of an unretained pointer to the
        // layer. attachedLayer (set after mpv_initialize succeeds below)
        // holds the strong reference for the duration of this attach.
        var wid: Int64 = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)

        for (k, v) in [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", Self.hwdecOption),
            ("prefetch-playlist", "yes"),
            ("keep-open", "yes"),
            ("keep-open-pause", "yes"),
            ("pause", "yes"),
            ("msg-level", "all=warn"),
            ("audio-display", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("target-colorspace-hint", "yes"),
            // panscan starts at 0 (letterbox) so the source's aspect is
            // preserved at identity zoom. setZoom flips panscan to 1.0
            // (cover-fill) once scale > 1.0, so no black pixels are exposed
            // by pan once the user has zoomed in.
        ] {
            mpv_set_option_string(h, k, v)
        }
        if audioOff {
            // The debug window passes audioOff=true so it doesn't fight
            // CoreAudio with the production source player. ao=null must
            // be set BEFORE mpv_initialize — it's not a runtime property.
            mpv_set_option_string(h, "ao", "null")
        }

        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_destroy(h)
            throw MPVSourcePlayerError.initializeFailed(code: Int(rc))
        }

        // Only commit the handle/layer references AFTER successful init.
        // A failed init must not leak ownership of the layer.
        self.handle = h
        self.attachedLayer = layer

        mpv_observe_property(h, 1, "pause",          MPV_FORMAT_FLAG)
        mpv_observe_property(h, 2, "playlist-count", MPV_FORMAT_INT64)
        mpv_observe_property(h, 3, "playlist-pos",   MPV_FORMAT_INT64)
        mpv_observe_property(h, 4, "time-pos",       MPV_FORMAT_DOUBLE)

        startEventPump()

        // Replay Swift-side state onto the fresh handle. mpv was started
        // with pause=yes so video doesn't start before our state replay
        // finishes; we explicitly unpause at the end if we were playing.
        NSLog("[MPVSourcePlayer] attach replay: playlistCount=\(playlistPaths.count) playlistPos=\(playlistPos) timePos=\(timePos) zoom.scale=\(zoom.scale) zoom.panX=\(zoom.panX) zoom.panY=\(zoom.panY)")
        if !playlistPaths.isEmpty {
            // Bake the start time into the loadfile command via `start=<t>`
            // when the active file is index 0. A separate `seek` issued
            // after `loadfile replace` races with mpv's load — mpv often
            // resets time to 0 partway through, dropping our seek and
            // landing at the start of the file. The start= option avoids
            // the race entirely.
            if playlistPos == 0 && timePos > 0 {
                runCommandSync(["loadfile", playlistPaths[0], "replace", "0", "start=\(timePos)"])
            } else {
                runCommandSync(["loadfile", playlistPaths[0], "replace"])
            }
            for p in playlistPaths.dropFirst() {
                runCommandSync(["loadfile", p, "append"])
            }
            if playlistPos > 0 && playlistPos < playlistPaths.count {
                runCommandSync(["playlist-play-index", String(playlistPos)])
                if timePos > 0 {
                    // playlist-play-index restarts at t=0 on the new file;
                    // exact-seek to the user's saved position. (Same loadfile
                    // race exists here in theory, but multi-file playlists
                    // are rare in this app and the user-visible drift is
                    // acceptable as a follow-up if needed.)
                    runCommandSync(["seek", String(timePos), "absolute+exact"])
                }
            }
        }
        // Replay volume (independent of playlist).
        var mpvVolume = max(0, min(100, volume * 100))
        mpv_set_property(h, "volume", MPV_FORMAT_DOUBLE, &mpvVolume)
        // Replay zoom/pan onto the fresh handle. The user's gesture state
        // lives on Workspace.currentZoom and is mirrored here by setZoom;
        // without this replay, returning from a preview clip would reset
        // the user's zoom to identity even though Workspace still has it.
        // Skip when identity to avoid a redundant write at startup.
        if zoom != .identity {
            setZoom(zoom)
        }
        // Restore paused state — mpv is currently paused; only unpause
        // if we were playing.
        if !isPaused {
            var flag: Int32 = 0
            mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag)
        }
    }

    /// Tear down the mpv_handle. Idempotent. `nonisolated` because deinit
    /// (always nonisolated) calls it; updating @MainActor properties from
    /// here uses `runOnMain` so we don't deadlock when SwiftUI tears the
    /// view down on the main thread.
    public nonisolated func detachLayer() {
        guard let h = handle else { return }
        // Setting handle=nil before terminate_destroy means concurrent
        // public-method writes (which guard on handle != nil) become
        // no-ops, so by the time we clear attachedLayer no one is racing
        // with us on the layer pointer.
        self.handle = nil

        // Drop any pending strdup'd argv from in-flight async commands.
        runOnMain { [weak self] in self?.dropPending() }

        // Stop the pump BEFORE destroying mpv. The pump captured the handle
        // pointer by value, so once mpv_terminate_destroy frees it any
        // subsequent wait_event call dereferences freed memory → SIGSEGV.
        // cancel() flips Thread.isCancelled, the pump observes it at the top
        // of its next iteration and signals pumpExited. Worst-case latency
        // is one wait_event timeout (~100 ms) if it was mid-wait when we
        // cancelled.
        pumpThread?.cancel()
        pumpExited?.wait()
        pumpThread = nil
        pumpExited = nil

        // Nil the wakeup callback BEFORE terminate_destroy (mirrors the
        // MPVKit demo). Without this, mpv could fire one last wakeup with
        // a nil context after destroy starts.
        mpv_set_wakeup_callback(h, nil, nil)
        mpv_terminate_destroy(h)

        // Clear the layer reference AFTER mpv is fully torn down. Releasing
        // the layer earlier could free the IOSurface mpv's MoltenVK context
        // was sampling.
        runOnMain { [weak self] in self?.attachedLayer = nil }
    }

    /// Run a @MainActor closure synchronously. If we're already on the
    /// main thread, run it inline (DispatchQueue.main.sync from the main
    /// thread is a deadlock trap). Otherwise sync-hop. Used by detachLayer,
    /// which can be called either from SwiftUI's view-removal path
    /// (main thread) or from deinit (any thread).
    private nonisolated func runOnMain(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { block() }
            }
        }
    }

    /// Start the event pump bound to the current handle. Captures the
    /// handle by value — resilient to `self.handle = nil` racing the pump
    /// during detach. The pump exits when (a) cancel() flips
    /// Thread.isCancelled (observed at the top of each iteration), or
    /// (b) mpv_wait_event returns MPV_EVENT_SHUTDOWN. On exit it signals
    /// `pumpExited` so detachLayer can wait before destroying mpv.
    private func startEventPump() {
        guard let h = handle else { return }
        let exited = DispatchSemaphore(value: 0)
        self.pumpExited = exited
        let pump = Thread { [handle = h] in
            defer { exited.signal() }
            while !Thread.current.isCancelled {
                guard let evt = mpv_wait_event(handle, 0.1) else { continue }
                let id = evt.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_COMMAND_REPLY {
                    let replyID = evt.pointee.reply_userdata
                    let cmdError = evt.pointee.error
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            guard var p = self.pending, p.replyID == replyID else { return }
                            // Free the strdup'd argv — mpv has consumed them by now.
                            for c in p.cstrings { if let c { free(c) } }
                            p.cstrings = []
                            if cmdError < 0 {
                                // Command rejected. Drop the pending entry; SkipCoordinator
                                // will time out via its debounce. Don't fire completion, or
                                // it would advance the coordinator on a non-event.
                                self.pending = nil
                            } else {
                                p.commandReplied = true
                                self.pending = p
                            }
                        }
                    }
                    continue
                }
                if id == MPV_EVENT_PLAYBACK_RESTART {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            // Only fire when (a) a pending seek exists, (b) its command
                            // already replied (so this PLAYBACK_RESTART is for our seek,
                            // not for a natural playlist auto-advance with no seek in
                            // flight), and (c) the generation matches.
                            guard let p = self.pending,
                                  p.commandReplied,
                                  p.generation == self.generation else { return }
                            self.pending = nil
                            p.completion()
                        }
                    }
                    continue
                }
                if id == MPV_EVENT_PROPERTY_CHANGE {
                    let prop = UnsafeMutableRawPointer(evt.pointee.data)?
                        .assumingMemoryBound(to: mpv_event_property.self).pointee
                    let userdata = evt.pointee.reply_userdata
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
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
                    }
                    continue
                }
            }
        }
        pump.name = "mpv-event-pump"
        pump.start()
        self.pumpThread = pump
    }

    // MARK: - Public mutation API
    //
    // All public mutation methods update Swift-side cached state
    // unconditionally; they additionally issue mpv calls only when
    // attached. Detached state replays on next attachLayer.

    public func bumpGeneration() {
        generation &+= 1
        // Drop any pending completion that hasn't fired — the bump means
        // we're transitioning to a state where the completion is no
        // longer meaningful. dropPending also frees the strdup'd argv.
        dropPending()
    }

    public func setPlaylist(_ paths: [String]) {
        // Bump generation FIRST so any in-flight pending seek's completion
        // is dropped before we issue the playlist-clear (which itself can
        // generate a PLAYBACK_RESTART that we don't want fired).
        bumpGeneration()
        playlistPaths = paths
        guard handle != nil else { return }
        if paths.isEmpty {
            runCommandSync(["playlist-clear"])
            return
        }
        // `loadfile <path> replace` clears + loads + auto-starts (matches
        // Phase 1's working bring-up). Bare `append` after a `playlist-clear`
        // leaves no current entry, so mpv won't begin playback even with
        // pause=no — that's what produced the black bring-up window.
        runCommandSync(["loadfile", paths[0], "replace"])
        for p in paths.dropFirst() {
            runCommandSync(["loadfile", p, "append"])
        }
    }

    public func play() {
        isPaused = false  // local truth; pump's pause event will be redundant
        guard let h = handle else { return }
        var flag: Int32 = 0
        mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func pause() {
        isPaused = true  // local truth; pump's pause event will be redundant
        guard let h = handle else { return }
        var flag: Int32 = 1
        mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func togglePlay() {
        if isPaused { play() } else { pause() }
    }

    /// Synchronously fetch mpv's current `time-pos` property, bypassing
    /// the property-observer-event cache (`self.timePos`). The cache is
    /// updated only when mpv emits a property-change event AND that event
    /// has been dispatched to the main actor — both contribute up to a
    /// frame of staleness. For features that need the freshest possible
    /// playback-time value (capturing the source-frame the user paused
    /// on, so the recorded freeze matches what was on screen at keystroke
    /// time), call this instead of reading `timePos`.
    ///
    /// Returns `timePos` (the cached value) when no mpv handle is
    /// attached — the fallback matches the legacy code path so callers
    /// don't have to special-case the detached state.
    public func currentSourceTimeSync() -> Double {
        guard let h = handle else { return timePos }
        var v: Double = 0
        let rc = mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &v)
        guard rc >= 0, v.isFinite else { return timePos }
        return v
    }

    public func setVolume(_ v: Double) {
        volume = v
        guard let h = handle else { return }
        var mpvVolume = max(0, min(100, v * 100))
        mpv_set_property(h, "volume", MPV_FORMAT_DOUBLE, &mpvVolume)
    }

    public func setZoom(_ zoom: Zoom) {
        // Cache the value so attachLayer can replay it after a detach
        // (preview round-trip). Update unconditionally — when detached the
        // mpv writes are skipped below but the next attach will replay this.
        self.zoom = zoom
        guard let h = handle else { return }
        // mpv's video-zoom is logarithmic (each unit = 2x). Our Zoom.scale is
        // linear, so log2 the scale.
        var mpvZoom = log2(zoom.scale)
        // mpv's video-pan-x/-y semantics in this build: "fraction of the
        // zoomed source size" — already zoom-invariant. The plan v2 review
        // cited mpv issue #3038 saying we needed `* scale`, but empirical
        // testing on the bundled MPVKit binary shows that produces over-shoot
        // (visible black at the source edges when zoomed). Send the raw
        // negated panX/panY instead.
        //
        // Sign convention: mpv's pan is "shift the video by pan" — positive
        // pan-x moves the video right (visible window sees LEFT side of
        // source). Our Zoom.panX is "fraction of source from the center,
        // positive = visible center on RIGHT." Opposite signs → negate.
        var px = -zoom.panX
        var py = -zoom.panY
        // panscan stays at 0 (letterbox-fit, preserves source aspect). The
        // SwiftUI player viewport is aspect-locked to the source, so there
        // are no black bars to expose at any zoom — and keeping panscan=0
        // means mpv's framing matches AVPlayer's letterbox-into-renderSize
        // playback math exactly, so what the user records is what they see
        // on playback.
        mpv_set_property(h, "video-zoom",  MPV_FORMAT_DOUBLE, &mpvZoom)
        mpv_set_property(h, "video-pan-x", MPV_FORMAT_DOUBLE, &px)
        mpv_set_property(h, "video-pan-y", MPV_FORMAT_DOUBLE, &py)
    }

    private func runCommandSync(_ args: [String]) {
        guard let h = handle else { return }
        var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
        defer { cstrings.forEach { if let p = $0 { free(p) } } }
        cstrings.withUnsafeMutableBufferPointer { buf in
            let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            _ = mpv_command(h, p)
        }
    }

    // MARK: - Skip primitive

    public func seek(
        playlistPos targetPos: Int,
        timeSeconds targetTime: Double,
        exact: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        // No in-flight seek across detach: if no handle, fire completion
        // immediately so SkipCoordinator advances. The next attach replays
        // playlistPos/timePos that's already on this Swift object.
        guard handle != nil else {
            Task { @MainActor in completion() }
            return
        }

        // Single-slot pending model: SkipCoordinator guarantees only one
        // seek in flight at a time, so we never need to track more than
        // one pending. Any prior pending entry was either fired (and would
        // have caused SkipCoordinator to issue this new seek) or was
        // dropped via bumpGeneration — either way it's gone here.
        // dropPending also frees the strdup'd argv if any was held.
        dropPending()

        if targetPos == playlistPos {
            let flags = exact ? "absolute+exact" : "absolute+keyframes"
            issueAsync(
                args: ["seek", String(targetTime), flags],
                completion: completion
            )
        } else {
            guard playlistPaths.indices.contains(targetPos) else {
                // Defensive: out-of-range playlist pos. Fire completion so
                // SkipCoordinator advances; the next user input will recover.
                Task { @MainActor in completion() }
                return
            }
            issueAsync(
                args: ["loadfile", playlistPaths[targetPos], "replace", "0", "start=\(targetTime)"],
                completion: completion
            )
        }
    }

    private func issueAsync(
        args: [String],
        completion: @escaping @MainActor () -> Void
    ) {
        // Caller (`seek`) has already guarded `handle != nil`.
        guard let h = handle else { return }
        let id = nextReplyID
        nextReplyID &+= 1

        // strdup each arg; ownership transfers to the PendingSeek struct,
        // which holds them until MPV_EVENT_COMMAND_REPLY frees them.
        var cstrings: [UnsafeMutablePointer<CChar>?] =
            args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
        pending = PendingSeek(
            replyID: id,
            generation: generation,
            completion: completion,
            cstrings: cstrings,
            commandReplied: false
        )

        cstrings.withUnsafeMutableBufferPointer { buf in
            let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            _ = mpv_command_async(h, id, p)
        }
    }

    /// Free the strdup'd argv currently held by `pending`, then clear it.
    /// Idempotent against `pending == nil`. Swift-side only — safe to
    /// call when handle is nil.
    private func dropPending() {
        if let p = pending {
            for c in p.cstrings { if let c { free(c) } }
        }
        pending = nil
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
}
