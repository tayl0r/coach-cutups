import SwiftUI
import AppKit
import QuartzCore
import Libmpv  // for MPVSourcePlayerError surfaced from attachLayer
import VideoCoachCore  // for Zoom

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

    /// Called whenever the user produces a zoom/pan input. The handler is
    /// expected to clamp and route the new Zoom to MPVSourcePlayer.setZoom.
    /// Bring-up window passes a closure that updates an internal Zoom var
    /// and calls player.setZoom directly. Production passes a closure that
    /// updates Workspace.currentZoom (whose setCurrentZoom calls setZoom).
    var onZoomChange: ((Zoom) -> Void)?

    /// Most recent Zoom committed by onZoomChange. Mirrored locally so the
    /// view can compute incremental updates (e.g. cursor-pivot zoom needs
    /// the current state to compute the next state). Synced by the
    /// production representable's updateNSView via setCurrentZoom (Task 3.4).
    private var currentZoom: Zoom = .identity

    private var dragAnchor: CGPoint?       // mouseDown location, in view local coords
    private var dragStartZoom: Zoom?       // zoom at mouseDown
    private var didCrossDragThreshold: Bool = false
    private static let dragThresholdSqr: CGFloat = 16  // 4 px squared

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
        dragAnchor = convert(event.locationInWindow, from: nil)
        dragStartZoom = currentZoom
        didCrossDragThreshold = false
        // Do NOT grab first-responder yet — defer until mouseUp without drag.
        // (The existing first-responder steal is moved out of mouseDown into
        // mouseUp's no-drag path, preserving the focus-out-of-TextField fix
        // from commit 3ab22aa.)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor, let startZoom = dragStartZoom,
              startZoom.scale > 1.0 else { return }
        let now = convert(event.locationInWindow, from: nil)
        let dx = now.x - anchor.x
        let dy = now.y - anchor.y
        if !didCrossDragThreshold && dx * dx + dy * dy < Self.dragThresholdSqr {
            return
        }
        didCrossDragThreshold = true
        // Pan delta: dragging right reveals more of right-hand source, so pan
        // moves in the opposite direction from the cursor.
        let viewW = max(1, bounds.width)
        let viewH = max(1, bounds.height)
        let nextPanX = startZoom.panX - (dx / (viewW * startZoom.scale))
        let nextPanY = startZoom.panY + (dy / (viewH * startZoom.scale))  // y-axis flip
        let next = Zoom(scale: startZoom.scale, panX: nextPanX, panY: nextPanY)
        commit(next)
    }

    override func mouseUp(with event: NSEvent) {
        if !didCrossDragThreshold {
            // Plain click — original first-responder grab semantics.
            window?.makeFirstResponder(self)
        }
        dragAnchor = nil
        dragStartZoom = nil
        didCrossDragThreshold = false
    }

    @MainActor
    func setCurrentZoom(_ zoom: Zoom) { currentZoom = zoom }

    override func magnify(with event: NSEvent) {
        let cursor = cursorInBounds(event)
        // event.magnification is a delta (-1...1 typical per gesture step).
        // Compounding into scale: nextScale = scale * (1 + magnification).
        let nextScale = currentZoom.scale * (1.0 + event.magnification)
        let next = currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor)
        commit(next)
    }

    override func scrollWheel(with event: NSEvent) {
        let cursor = cursorInBounds(event)
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger swipe → pan.
            // Direction: positive scrollingDeltaY = swipe up = expose more of top
            // (so the visible center moves toward smaller y in source). The flip
            // already incorporates the user's natural-scrolling preference; mpv
            // and Apple's docs both treat scrollingDeltaY as content-direction.
            guard currentZoom.scale > 1.0 else { return }
            let viewW = max(1, bounds.width)
            let viewH = max(1, bounds.height)
            let dx = -event.scrollingDeltaX / (viewW * currentZoom.scale)
            let dy = -event.scrollingDeltaY / (viewH * currentZoom.scale)
            let next = Zoom(
                scale: currentZoom.scale,
                panX: currentZoom.panX + dx,
                panY: currentZoom.panY + dy
            )
            commit(next)
        } else {
            // Coarse mouse wheel → zoom toward cursor.
            // Direction: scrollingDeltaY > 0 = wheel scrolled up (away from user)
            // = zoom IN. This matches Maps, Safari, Final Cut, every macOS app
            // that supports wheel-to-zoom. macOS's natural-scrolling preference
            // is already baked into scrollingDeltaY; we don't read
            // isDirectionInvertedFromDevice separately. (Verified against reviewer
            // finding 7 in v2 review history.)
            let step = 0.1
            let factor = 1.0 + step * (event.scrollingDeltaY > 0 ? 1.0 : -1.0)
            let nextScale = currentZoom.scale * factor
            let next = currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor)
            commit(next)
        }
    }

    /// Cursor position normalized to [0,1] in view bounds.
    private func cursorInBounds(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let x = bounds.width > 0 ? p.x / bounds.width : 0.5
        let y = bounds.height > 0 ? (bounds.height - p.y) / bounds.height : 0.5
        return CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
    }

    private func commit(_ zoom: Zoom) {
        let clamped = zoom.clamped()
        currentZoom = clamped
        onZoomChange?(clamped)
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // contentsScale must match backingScale so the layer interprets its
        // drawable's pixel dimensions correctly relative to its point-sized
        // bounds. Without this the default 1.0 makes the layer treat the
        // 2x-resolution drawable as if it were 1× content, producing a
        // zoomed/cropped picture on Retina displays. (MPVKit's demo sets
        // this explicitly in viewDidLoad for the same reason.)
        metalLayer.contentsScale = scale
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
