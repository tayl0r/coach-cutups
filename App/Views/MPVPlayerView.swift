import SwiftUI
import AppKit
import Metal
import QuartzCore
import Libmpv

enum MPVRenderBackend: String {
    case sw
    case glToMetal

    /// UserDefaults key the Debug menu writes to. Read at view-init time —
    /// the production representable picks up the value when SwiftUI rebuilds
    /// the view (e.g. on app relaunch); the bring-up window picks it up next
    /// time it's opened. Default is `.glToMetal`.
    static let userDefaultsKey = "VideoCoach.mpvRenderBackend"

    /// Production default. Reads from UserDefaults; falls back to GL.
    static var production: MPVRenderBackend {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let value = MPVRenderBackend(rawValue: raw) {
            return value
        }
        return .glToMetal
    }

    var displayName: String {
        switch self {
        case .sw:        return "Software (legacy)"
        case .glToMetal: return "GL → IOSurface → Metal"
        }
    }
}

/// `@convention(c)` GL proc-address resolver for libmpv's render-context.
/// Defined as a closure (not a reference to the `@_cdecl`-marked
/// `vcGLGetProcAddress` in GLMetalBridge.swift) because referencing that
/// function as a value from another file causes the Swift compiler to
/// re-emit the C symbol here, producing a linker duplicate-symbol error.
/// The C inline `vc_cgl_get_proc_address` is in the bridging header and
/// emits no symbol, so this closure has no link-level conflict.
private let mpvGetProcAddress:
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? =
{ _, name in
    guard let name else { return nil }
    return vc_cgl_get_proc_address(name)
}

/// NSView that renders an MPVSourcePlayer's output into a CAMetalLayer.
/// Phase 3.5: render-context lifecycle now lives on MPVSourcePlayer; this
/// view just owns the CAMetalLayer + CVDisplayLink and delegates per-frame
/// rendering to the (owned or shared) player.
final class MPVRenderingNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let backend: MPVRenderBackend
    private var bridge: GLMetalBridge?

    /// Phase-1 bring-up path owns its player; production path takes a shared one.
    private var ownedPlayer: MPVSourcePlayer?
    private weak var sharedPlayer: MPVSourcePlayer?
    private var player: MPVSourcePlayer? { ownedPlayer ?? sharedPlayer }
    private var displayLink: CVDisplayLink?

    init(frame: NSRect, backend: MPVRenderBackend = .production) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        self.device = dev
        self.commandQueue = q
        self.backend = backend
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Steal first-responder status on click so a TextField currently
        // holding focus releases. KeyCommandView sits on top with
        // hitTest returning nil, so the click falls through to here.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    /// Phase 1 bring-up entry — owns its own MPVSourcePlayer with audio off
    /// and a single-file playlist. The hwdec parameter is recorded here for
    /// historical reasons (Phase 1 gate (a)); MPVSourcePlayer hardcodes the
    /// chosen value at compile time after Phase 1 ships.
    @MainActor
    func bringUp(filePath: String, hwdec: String) throws {
        NSLog("[MPV-debug] bringUp hwdec=\(hwdec) (note: MPVSourcePlayer hardcodes its own at this point)")
        let p = try MPVSourcePlayer(audioOff: true)
        try attachRenderAndStart(player: p)
        p.setPlaylist([filePath])
        p.play()
        self.ownedPlayer = p
    }

    /// Production entry — view does not own the player.
    @MainActor
    func attach(player: MPVSourcePlayer) throws {
        try attachRenderAndStart(player: player)
        self.sharedPlayer = player
    }

    /// Production-path attach update. Idempotent: if the same player is
    /// passed twice, no-op. If a different (or nil → non-nil) player
    /// arrives, tears down the old attachment and attaches the new one.
    @MainActor
    func updatePlayer(_ newPlayer: MPVSourcePlayer?) {
        let currentID = sharedPlayer.map { ObjectIdentifier($0) }
        let newID = newPlayer.map { ObjectIdentifier($0) }
        if currentID == newID { return }

        // Detach current (if any). For the production path the view does
        // NOT own the player — only detach the render context + drop the
        // shared ref. The owned-player path (bring-up window) is handled
        // by tearDown() on viewWillMove(toWindow: nil) and is mutually
        // exclusive with this code path.
        // Note: bridge is intentionally retained across updatePlayer swaps — it's
        // a view-scoped GPU resource. Only tearDown() (view leaving window) drops it.
        if sharedPlayer != nil {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }
            sharedPlayer?.detachRender()
            sharedPlayer = nil
        }

        if let newPlayer {
            do {
                try attachRenderAndStart(player: newPlayer)
                sharedPlayer = newPlayer
            } catch {
                NSLog("[MPV] attach failed in updatePlayer: \(error)")
            }
        }
    }

    @MainActor
    private func attachRenderAndStart(player: MPVSourcePlayer) throws {
        switch backend {
        case .sw:
            try player.attachRender()
        case .glToMetal:
            if bridge == nil {
                bridge = try GLMetalBridge(device: device)
            }
            try player.attachRenderGL(
                glContext: bridge!.glContext,
                getProcAddress: mpvGetProcAddress
            )
        }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.renderTick()
                return kCVReturnSuccess
            }
            _ = CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    /// Called from the CVDisplayLink callback (off-main). We capture the
    /// layer/queue on whatever thread the link callback runs on; the
    /// player's renderInto is thread-safe via its renderLock try-lock.
    private func renderTick() {
        let layer = self.metalLayer
        let size = layer.drawableSize
        let queue = self.commandQueue
        guard let player = self.player else { return }
        switch backend {
        case .sw:
            player.renderInto(layer: layer, drawableSize: size, commandQueue: queue)
        case .glToMetal:
            guard let bridge = self.bridge else { return }
            player.renderIntoGL(layer: layer, drawableSize: size, commandQueue: queue, bridge: bridge)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDown() }
    }

    private func tearDown() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        if let owned = ownedPlayer {
            owned.detachRender()
            ownedPlayer = nil
        } else {
            sharedPlayer?.detachRender()
            sharedPlayer = nil
        }
        // Release the bridge AFTER the render context is freed; the render context
        // referenced our FBO via the GL callbacks, so order matters.
        bridge = nil
    }

    deinit { tearDown() }
}

/// SwiftUI bridge for the bring-up window (Phase 1).
struct MPVDebugRepresentable: NSViewRepresentable {
    let filePath: String
    let hwdec: String
    let overlayTint: Bool
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}

/// Production representable — used by ContentView in Phase 4.
struct MPVPlayerView: NSViewRepresentable {
    let player: MPVSourcePlayer?
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        // Don't attach here — Workspace.sourcePlayer is lazy-init and
        // may be nil at first body evaluation. updateNSView handles
        // the actual attach (nil → non-nil transition + identity changes).
        v.updatePlayer(player)
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {
        nsView.updatePlayer(player)
    }
}
