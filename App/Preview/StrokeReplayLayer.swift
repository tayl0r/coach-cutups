import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import VideoCoachCore

/// AppKit overlay that replays a clip's strokes on top of the Mode C
/// `AVPlayerView`. Sits in the view hierarchy above the player layer; observes
/// player time at 60Hz via `AVPlayer.addPeriodicTimeObserver` and diffs the
/// displayed `CAShapeLayer`s against the result of the shared
/// `visibleStrokes(in:atRecordTime:)` helper.
///
/// Coordinate system: AppKit default (`isFlipped = false`, bottom-left
/// origin) — same as the live drawing overlay. Path coordinates use
/// `Denormalize.point(_, _, into:size, flipY: true)` to convert top-left
/// stored points into bottom-left view space.
final class StrokeReplayLayer: NSView {
    private struct Live {
        var layer: CAShapeLayer
        var drawnPointCount: Int
    }

    private(set) var clip: Clip
    /// Always `.zero` for Mode C (one clip per preview composition), but kept
    /// as a stored property to mirror the per-tick math for clarity.
    var clipCompositionStart: CMTime

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var displayed: [Stroke.ID: Live] = [:]

    /// The view's size at the time of the last layout pass, used to detect
    /// resize events that require all paths to be rebuilt at the new scale.
    private var lastLayoutSize: CGSize = .zero

    override var isFlipped: Bool { false }

    init(clip: Clip, player: AVPlayer, clipCompositionStart: CMTime = .zero) {
        self.clip = clip
        self.player = player
        self.clipCompositionStart = clipCompositionStart
        super.init(frame: .zero)
        wantsLayer = true
        // Critical for transparency over the player layer.
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        attachObserver(to: player)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        // Always remove the observer — the closure retains the player
        // otherwise, and the player would leak across clip switches.
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
    }

    /// Detach lifecycle hook for the SwiftUI representable's
    /// `dismantleNSView` so the observer doesn't outlive the view via the
    /// closure-retained player reference.
    func tearDown() {
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        player = nil
    }

    /// Re-point the overlay at a different player. Removes the prior
    /// observer first; otherwise both observers fire and old layers thrash.
    func setPlayer(_ newPlayer: AVPlayer) {
        if let token = timeObserver, let prior = player {
            prior.removeTimeObserver(token)
        }
        timeObserver = nil
        player = newPlayer
        // Reset the displayed set — the new player may be at any time, the
        // next periodic tick will repopulate.
        clearAllLayers()
        attachObserver(to: newPlayer)
    }

    /// Swap the clip whose events drive the replay (useful if the same view
    /// is reused across selections; in practice SwiftUI tears down via
    /// `dismantleNSView` and rebuilds, but this keeps the API symmetric).
    func setClip(_ newClip: Clip) {
        clip = newClip
        clearAllLayers()
    }

    override func layout() {
        super.layout()
        // If the view was resized, rebuild every visible path so line widths
        // and coordinates re-scale to the new bounds. Cheap — at most a few
        // strokes are visible at once.
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            rebuildAllPaths()
        }
    }

    // MARK: - Observer

    private func attachObserver(to player: AVPlayer) {
        // 1/60s interval — high enough to look smooth, low enough that the
        // diff loop's CPU cost stays negligible at typical ≤4 visible
        // strokes per frame.
        let interval = CMTime(value: 1, timescale: 60)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.tick(at: time)
        }
        timeObserver = token
    }

    private func tick(at compositionTime: CMTime) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let recordSeconds = max(0, (compositionTime - clipCompositionStart).seconds)
        let visible = visibleStrokes(in: clip, atRecordTime: recordSeconds)

        // Build a quick lookup so we can detect removals in O(N).
        let visibleByID: [Stroke.ID: VisibleStroke] = Dictionary(
            uniqueKeysWithValues: visible.map { ($0.stroke.id, $0) }
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Remove layers whose strokes are no longer visible.
        for (id, live) in displayed where visibleByID[id] == nil {
            live.layer.removeFromSuperlayer()
            displayed.removeValue(forKey: id)
        }

        // 2. Add new layers; update partially-drawn ones whose drawn-point
        //    count grew (or shrank, if the user scrubbed back inside the
        //    same stroke's lifetime).
        for vs in visible {
            if let existing = displayed[vs.stroke.id] {
                if existing.drawnPointCount != vs.drawnPointCount {
                    existing.layer.path = makePath(for: vs)
                    displayed[vs.stroke.id] = Live(
                        layer: existing.layer,
                        drawnPointCount: vs.drawnPointCount
                    )
                }
            } else {
                let layer = makeShapeLayer(for: vs)
                self.layer?.addSublayer(layer)
                displayed[vs.stroke.id] = Live(
                    layer: layer,
                    drawnPointCount: vs.drawnPointCount
                )
            }
        }

        CATransaction.commit()
    }

    // MARK: - Layer helpers

    private func makeShapeLayer(for vs: VisibleStroke) -> CAShapeLayer {
        let s = vs.stroke
        let layer = CAShapeLayer()
        let cgColor = NSColor(
            red: CGFloat(s.color.r),
            green: CGFloat(s.color.g),
            blue: CGFloat(s.color.b),
            alpha: CGFloat(s.color.a)
        ).cgColor
        layer.strokeColor = cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineWidth = CGFloat(s.lineWidth) * bounds.height
        layer.path = makePath(for: vs)
        return layer
    }

    private func makePath(for vs: VisibleStroke) -> CGPath {
        let count = min(vs.drawnPointCount, vs.stroke.points.count)
        guard count > 0 else { return CGMutablePath() }

        let firstP = vs.stroke.points[0]
        let firstPt = Denormalize.point(firstP.x, firstP.y, into: bounds.size, flipY: true)

        if count == 1 {
            // Single-point stroke: a path with only `move(to:)` and no
            // segments doesn't render under `strokePath()`. A degenerate
            // `addLine(to: firstPt)` paired with `lineCap = .round` paints
            // one rounded dot of diameter `lineWidth` centered on the
            // point — same visual as the live overlay's first-mouseDown
            // tick.
            let p = CGMutablePath()
            p.move(to: firstPt)
            p.addLine(to: firstPt)
            return p
        }

        let path = CGMutablePath()
        path.move(to: firstPt)
        for i in 1..<count {
            let p = vs.stroke.points[i]
            let pt = Denormalize.point(p.x, p.y, into: bounds.size, flipY: true)
            path.addLine(to: pt)
        }
        return path
    }

    private func rebuildAllPaths() {
        guard !displayed.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Re-derive the current visible set so each path is rebuilt against
        // the new bounds (for both stored points and lineWidth scale).
        let now = player?.currentTime() ?? .zero
        let recordSeconds = max(0, (now - clipCompositionStart).seconds)
        for vs in visibleStrokes(in: clip, atRecordTime: recordSeconds) {
            if let existing = displayed[vs.stroke.id] {
                existing.layer.lineWidth = CGFloat(vs.stroke.lineWidth) * bounds.height
                existing.layer.path = makePath(for: vs)
            }
        }
        CATransaction.commit()
    }

    private func clearAllLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for live in displayed.values {
            live.layer.removeFromSuperlayer()
        }
        displayed.removeAll()
        CATransaction.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI representable that mounts a `StrokeReplayLayer` into the view
/// hierarchy above the `AVPlayerView`. The `dismantleNSView` hook is required
/// so the periodic time observer is removed when the overlay is detached;
/// otherwise the closure retains the player and leaks across clip switches.
struct StrokeReplayOverlay: NSViewRepresentable {
    let player: AVPlayer
    let clip: Clip

    func makeNSView(context: Context) -> StrokeReplayLayer {
        StrokeReplayLayer(clip: clip, player: player)
    }

    func updateNSView(_ nsView: StrokeReplayLayer, context: Context) {
        if nsView.clip.id != clip.id {
            nsView.setClip(clip)
        }
    }

    static func dismantleNSView(_ nsView: StrokeReplayLayer, coordinator: ()) {
        nsView.tearDown()
    }
}
