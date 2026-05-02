import SwiftUI
import AppKit
import QuartzCore
import Libmpv  // for MPVSourcePlayerError surfaced from attachLayer

/// NSView that hosts an `MPVMetalLayer`. mpv (vo=gpu-next + gpu-context=
/// moltenvk) draws directly into the layer via `wid`; the view exists to
/// own the layer, track size/scale changes, and drive first-responder
/// click handling. There's no CVDisplayLink, no MTLDevice cache, no
/// command queue, no bridge — mpv's render thread does all of it.
final class MPVRenderingNSView: NSView {
    private let metalLayer = MPVMetalLayer()

    /// Phase-1 bring-up path owns its player; production path takes a shared one.
    private var ownedPlayer: MPVSourcePlayer?
    private weak var sharedPlayer: MPVSourcePlayer?
    private var player: MPVSourcePlayer? { ownedPlayer ?? sharedPlayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.pixelFormat = .bgra8Unorm
        // gpu-next renders directly into the drawable; nothing on the
        // Swift side reads back the texture, so framebufferOnly=true is
        // safe and lets MoltenVK skip allocating shader-readable storage.
        metalLayer.framebufferOnly = true
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

    /// Bring-up entry — owns its own MPVSourcePlayer with audio off and a
    /// single-file playlist. The hwdec parameter is recorded here for
    /// historical reasons (Phase 1 gate (a)); MPVSourcePlayer hardcodes
    /// the chosen value at compile time.
    @MainActor
    func bringUp(filePath: String, hwdec: String) throws {
        NSLog("[MPV-debug] bringUp hwdec=\(hwdec) (note: MPVSourcePlayer hardcodes its own at this point)")
        let p = MPVSourcePlayer(audioOff: true)
        try p.attachLayer(metalLayer)
        p.setPlaylist([filePath])
        p.play()
        self.ownedPlayer = p
    }

    /// Production entry — view does not own the player.
    @MainActor
    func attach(player: MPVSourcePlayer) throws {
        try player.attachLayer(metalLayer)
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
        // NOT own the player — only detach the layer + drop the shared
        // ref. The owned-player path (bring-up window) is handled by
        // tearDown() on viewWillMove(toWindow: nil) and is mutually
        // exclusive with this code path.
        if let existing = sharedPlayer {
            existing.detachLayer()
            sharedPlayer = nil
        }

        if let newPlayer {
            do {
                try newPlayer.attachLayer(metalLayer)
                sharedPlayer = newPlayer
            } catch {
                NSLog("[MPV] attachLayer failed in updatePlayer: \(error)")
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDown() }
    }

    private func tearDown() {
        if let owned = ownedPlayer {
            owned.detachLayer()
            ownedPlayer = nil
        } else {
            sharedPlayer?.detachLayer()
            sharedPlayer = nil
        }
    }

    deinit { tearDown() }
}

/// SwiftUI bridge for the bring-up window.
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

/// Production representable — used by ContentView.
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
