import Foundation
import Observation
import Metal
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
    // Render-context state lives outside the actor so the CVDisplayLink
    // thread can call renderInto without hopping to the main actor. The
    // NSLock guards both renderContext lifecycle and reads.
    // @ObservationIgnored so the @Observable macro doesn't wrap accesses
    // (which would defeat nonisolated(unsafe)).
    @ObservationIgnored
    nonisolated(unsafe) fileprivate var renderContext: OpaquePointer?
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

    public init(audioOff: Bool = false) throws {
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

    // MARK: - Skip primitive (Task 3.6)

    public func seek(
        playlistPos targetPos: Int,
        timeSeconds targetTime: Double,
        exact: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        // Single-slot pending model: SkipCoordinator guarantees only one
        // seek in flight at a time, so we never need to track more than
        // one pending. Any prior pending entry was either fired (and would
        // have caused SkipCoordinator to issue this new seek) or was
        // dropped via bumpGeneration — either way it's gone here.
        pending = nil

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
        let id = nextReplyID
        nextReplyID &+= 1

        // strdup each arg; ownership transfers to the PendingSeek struct,
        // which holds them until MPV_EVENT_COMMAND_REPLY frees them. The
        // freed-too-soon UAF that motivates this comment was identified in
        // the v1 plan's adversarial review.
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
            _ = mpv_command_async(handle, id, p)
        }
    }

    /// Called from the event-pump's COMMAND_REPLY branch (Task 3.7) to free
    /// the strdup'd args.
    fileprivate func freePendingCstrings() {
        if var p = pending {
            for c in p.cstrings { if let c { free(c) } }
            p.cstrings = []
            pending = p
        }
    }

    // MARK: - Render lifecycle (Task 3.5)
    //
    // The render context is created/freed here so the production
    // MPVPlayerView(player:) path can attach/detach against the shared
    // player. The CVDisplayLink lives on the view; renderInto is called
    // from that link's callback.

    public func attachRender() throws {
        renderLock.lock(); defer { renderLock.unlock() }
        guard renderContext == nil else { throw MPVSourcePlayerError.alreadyAttached }

        // MPV_RENDER_PARAM_API_TYPE wants a `char *` pointing to "sw".
        // Hold the C buffer in a local so the pointer survives the call.
        var apiTypeBuf = Array("sw".utf8CString)
        var advancedControl: Int32 = 0  // SW backend; advancedControl=1 risks deadlock per render.h

        let rc: CInt = apiTypeBuf.withUnsafeMutableBufferPointer { apiBuf -> CInt in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                 data: UnsafeMutableRawPointer(apiBuf.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                                 data: withUnsafeMutableBytes(of: &advancedControl) { $0.baseAddress }),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var ctx: OpaquePointer?
            let r = params.withUnsafeMutableBufferPointer {
                mpv_render_context_create(&ctx, handle, $0.baseAddress)
            }
            if r >= 0, let ctx {
                self.renderContext = ctx
            }
            return r
        }
        guard rc >= 0, renderContext != nil else {
            throw MPVSourcePlayerError.renderContextFailed(code: Int(rc))
        }
    }

    public nonisolated func detachRender() {
        renderLock.lock(); defer { renderLock.unlock() }
        if let ctx = renderContext {
            mpv_render_context_free(ctx)
            renderContext = nil
        }
    }

    /// Called by MPVRenderingNSView's CVDisplayLink. Try-locks to avoid
    /// blocking the display-link thread on a teardown in flight; nil
    /// renderContext means a teardown happened, so we skip this frame.
    public nonisolated func renderInto(layer: CAMetalLayer, drawableSize: CGSize, commandQueue: MTLCommandQueue) {
        guard renderLock.try() else {
            return
        }
        defer { renderLock.unlock() }
        guard let renderContext else {
            return
        }

        let w = Int32(drawableSize.width)
        let h = Int32(drawableSize.height)
        guard w > 0, h > 0 else {
            return
        }

        let bytesPerRow = Int(w) * 4
        let bufferSize = bytesPerRow * Int(h)
        let pixelBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { pixelBuffer.deallocate() }

        var size: [Int32] = [w, h]
        var stride = Int(bytesPerRow)
        var format = "bgr0".utf8CString  // matches Metal bgra8Unorm memory order

        format.withUnsafeMutableBufferPointer { fmtBuf in
            size.withUnsafeMutableBufferPointer { sizeBuf in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                         data: UnsafeMutableRawPointer(sizeBuf.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                         data: UnsafeMutableRawPointer(fmtBuf.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                         data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                         data: pixelBuffer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = params.withUnsafeMutableBufferPointer {
                        mpv_render_context_render(renderContext, $0.baseAddress)
                    }
                }
            }
        }

        guard let drawable = layer.nextDrawable() else {
            return
        }
        drawable.texture.replace(
            region: MTLRegionMake2D(0, 0, Int(w), Int(h)),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )
        if let cmdBuf = commandQueue.makeCommandBuffer() {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
    case alreadyAttached
    case renderContextFailed(code: Int)
}
