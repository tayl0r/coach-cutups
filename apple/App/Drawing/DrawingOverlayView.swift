import AppKit
import VideoCoachCore

/// `NSView` that overlays an `AVPlayerLayer` and turns mouse drags into
/// `Stroke`s. Each in-progress stroke gets its own `CAShapeLayer` whose path
/// extends as new points are committed — no overlay-wide repaints, GPU
/// composites the per-stroke layer.
///
/// Coordinate system: AppKit default (`isFlipped = false`, bottom-left
/// origin). Strokes are stored top-left-normalized; the conversion happens
/// in `pointFromView` (Y-flip on capture) and `Denormalize.point(...,
/// flipY: true)` on render. See the design's "Drawing capture" section for
/// the full coordinate-system table — passing `flipY: false` here would
/// render strokes mirrored vertically.
final class DrawingOverlayView: NSView {
    var onStrokeFinished: (Stroke) -> Void = { _ in }
    var autoClearAfterSeconds: Double? = 5.0

    private struct InProgress {
        var startedAt: TimeInterval
        var points: [StrokePoint]
        var lastTime: TimeInterval
        var lastPxPoint: NSPoint
        var layer: CAShapeLayer
        /// Grown incrementally with `addLine(to:)`; never re-walked. Mutating
        /// CGMutablePath is O(1) per point; rebuilding from `points` would
        /// be O(N) per drag event.
        var path: CGMutablePath
    }

    private var inProgress: InProgress?
    private var liveLayers: [UUID: CAShapeLayer] = [:]
    private let minDt: TimeInterval = 1.0 / 60.0
    private let minPx: CGFloat = 1.0

    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Defensive: discard any abandoned in-progress stroke (e.g. a
        // synthesized mouseDown during a window resize). Otherwise its
        // CAShapeLayer leaks.
        if let prior = inProgress {
            prior.layer.removeFromSuperlayer()
            inProgress = nil
        }
        let p = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        let layer = CAShapeLayer()
        // Match the saved Stroke.color = RGBA.red exactly so the live
        // drawing matches the export.
        layer.strokeColor = NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0).cgColor
        layer.fillColor = nil
        // CAShapeLayer.lineWidth is in points; Core Animation handles the
        // Retina backing-store upscale automatically. Do NOT multiply by
        // backingScaleFactor — that would render at 2× thickness on Retina.
        layer.lineWidth = 0.005 * bounds.height
        layer.lineCap = .round
        layer.lineJoin = .round
        self.layer?.addSublayer(layer)
        let path = CGMutablePath()
        let firstSP = pointFromView(p, sinceStart: 0)
        path.move(to: Denormalize.point(firstSP.x, firstSP.y, into: bounds.size, flipY: true))
        layer.path = path
        inProgress = InProgress(
            startedAt: now,
            points: [firstSP],
            lastTime: now,
            lastPxPoint: p,
            layer: layer,
            path: path
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var ip = inProgress else { return }
        let p = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        if now - ip.lastTime < minDt { return }
        if hypot(p.x - ip.lastPxPoint.x, p.y - ip.lastPxPoint.y) < minPx { return }
        let strokeT = now - ip.startedAt
        let newSP = pointFromView(p, sinceStart: strokeT)
        ip.points.append(newSP)
        ip.lastTime = now
        ip.lastPxPoint = p
        // O(1) path growth — no re-walk of all prior points.
        ip.path.addLine(to: Denormalize.point(newSP.x, newSP.y, into: bounds.size, flipY: true))
        ip.layer.path = ip.path
        inProgress = ip
    }

    override func mouseUp(with event: NSEvent) {
        guard let ip = inProgress else { return }
        let strokeID = UUID()
        let stroke = Stroke(
            id: strokeID,
            color: .red,
            lineWidth: 0.005,
            points: ip.points,
            autoClearAfterSeconds: autoClearAfterSeconds
        )
        onStrokeFinished(stroke)
        liveLayers[strokeID] = ip.layer
        inProgress = nil

        // Schedule auto-clear so the recording overlay matches what the
        // export will replay. If autoClearAfterSeconds is nil, the layer
        // persists until clearAll() is called.
        if let auto = autoClearAfterSeconds {
            let id = strokeID
            DispatchQueue.main.asyncAfter(deadline: .now() + auto) { [weak self] in
                guard let self, let layer = self.liveLayers[id] else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeFromSuperlayer()
                CATransaction.commit()
                self.liveLayers.removeValue(forKey: id)
            }
        }
    }

    func clearAll() {
        // Abort any in-progress stroke too — otherwise its layer becomes
        // orphaned on mouseUp (it'd be re-added to liveLayers right after
        // we just emptied liveLayers).
        if let ip = inProgress {
            ip.layer.removeFromSuperlayer()
            inProgress = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in liveLayers.values { layer.removeFromSuperlayer() }
        CATransaction.commit()
        liveLayers.removeAll()
    }

    private func pointFromView(_ p: NSPoint, sinceStart strokeT: Double) -> StrokePoint {
        StrokePoint(
            x: p.x / bounds.width,
            y: 1.0 - p.y / bounds.height,    // flip Y so 0 = top
            t: strokeT
        )
    }
}
