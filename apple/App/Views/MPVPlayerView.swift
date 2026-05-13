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
        commit(ZoomGesture.nextZoom(forMagnify: event, in: self, currentZoom: currentZoom))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let next = ZoomGesture.nextZoom(forScrollWheel: event, in: self, currentZoom: currentZoom) else { return }
        commit(next)
    }

    private func commit(_ zoom: Zoom) {
        let clamped = zoom.snapped().clamped()
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
        // Local zoom state for the bring-up window — owned player has no
        // Workspace to route through, so we apply the zoom directly.
        self.onZoomChange = { [weak p, weak self] z in
            guard let self else { return }
            self.setCurrentZoom(z)
            p?.setZoom(z)
        }
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
    let currentZoom: Zoom               // workspace-canonical (clamped) value
    let onZoomChange: (Zoom) -> Void
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        // Don't attach here — Workspace.sourcePlayer is lazy-init and
        // may be nil at first body evaluation. updateNSView handles
        // the actual attach (nil → non-nil transition + identity changes).
        v.updatePlayer(player)
        v.onZoomChange = onZoomChange
        v.setCurrentZoom(currentZoom)
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {
        nsView.updatePlayer(player)
        nsView.onZoomChange = onZoomChange
        // Sync the view's local Zoom mirror with the workspace canonical
        // (clamped) value after every body re-eval. Without this, the view's
        // internal mirror diverges from Workspace state at clamp boundaries
        // and the next gesture computes from stale state. (Reviewer finding 8.)
        nsView.setCurrentZoom(currentZoom)
    }
}

/// Static helpers shared by `MPVRenderingNSView` (scanning-mode source view)
/// and `DrawingOverlayView` (recording-mode overlay). Both surfaces need to
/// produce the same Zoom from the same NSEvents so the user's scroll/pinch/
/// pan gestures behave identically before and after R-press. The recording
/// drawing overlay sits ON TOP of the MPV view, so without these forwarded
/// to the overlay, scroll/pinch events die at the overlay (siblings in a
/// ZStack don't share events).
@MainActor
enum ZoomGesture {
    /// Cursor position normalized to [0,1] with origin at top-left.
    /// Both call sites have `isFlipped == false`, so we flip Y here.
    static func cursor(in view: NSView, event: NSEvent) -> CGPoint {
        let p = view.convert(event.locationInWindow, from: nil)
        let bw = view.bounds.width
        let bh = view.bounds.height
        let x = bw > 0 ? p.x / bw : 0.5
        let y = bh > 0 ? (bh - p.y) / bh : 0.5
        return CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
    }

    /// Compute the next zoom for a scroll-wheel event.
    ///
    /// `hasPreciseScrollingDeltas == true` → trackpad two-finger swipe.
    /// Modifier state is checked PER EVENT (not latched at gesture start),
    /// so pressing or releasing Cmd partway through a swipe flips
    /// pan↔zoom live — that's why `cf705f9` (latched at gesture start)
    /// was reverted as `f3eaf03`.
    ///   * `.command` held → cursor-pivoted zoom (`scrollingDeltaY` →
    ///     scale multiplier).
    ///   * `.command` released → pan (no-op at scale=1.0, returns nil).
    ///
    /// `hasPreciseScrollingDeltas == false` → coarse mouse wheel →
    /// cursor-pivoted zoom regardless of modifiers.
    ///
    /// Direction matches Maps/Safari/Final Cut: deltaY>0 = swipe away
    /// from user = zoom in. macOS's natural-scrolling preference is
    /// already baked into `scrollingDeltaY`.
    static func nextZoom(forScrollWheel event: NSEvent, in view: NSView, currentZoom: Zoom) -> Zoom? {
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.command) {
                // Trackpad zoom. `/300` chosen empirically as a reasonable
                // starting feel — comparable per-event scale change to a
                // mouse-wheel notch (~10% per ~30px of swipe). Tune as
                // needed.
                let nextScale = currentZoom.scale * (1.0 + event.scrollingDeltaY / 300.0)
                return currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor(in: view, event: event))
            }
            // Trackpad pan. No-op at scale=1.0 (nothing to pan).
            guard currentZoom.scale > 1.0 else { return nil }
            let viewW = max(1, view.bounds.width)
            let viewH = max(1, view.bounds.height)
            let dx = -event.scrollingDeltaX / (viewW * currentZoom.scale)
            let dy = -event.scrollingDeltaY / (viewH * currentZoom.scale)
            return Zoom(
                scale: currentZoom.scale,
                panX: currentZoom.panX + dx,
                panY: currentZoom.panY + dy
            )
        } else {
            let step = 0.1
            let factor = 1.0 + step * (event.scrollingDeltaY > 0 ? 1.0 : -1.0)
            let nextScale = currentZoom.scale * factor
            return currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor(in: view, event: event))
        }
    }

    /// Compute the next zoom for a trackpad pinch event. The 3x sensitivity
    /// multiplier brings per-event magnification (typical 0.001–0.02) into
    /// a perceptible scale change comparable to Maps/Photos pinch.
    static func nextZoom(forMagnify event: NSEvent, in view: NSView, currentZoom: Zoom) -> Zoom {
        let sensitivity: CGFloat = 3.0
        let nextScale = currentZoom.scale * (1.0 + event.magnification * sensitivity)
        return currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor(in: view, event: event))
    }
}
