import Foundation

public extension Array where Element == CommentaryEvent {
    /// Active Zoom at recordTime t, with linear interpolation between
    /// adjacent .zoom keyframes. Empty / before-first → identity (or first
    /// value if any). After-last → last value. Non-zoom events are ignored.
    func zoomAt(recordTime t: Double) -> Zoom {
        var prev: (time: Double, zoom: Zoom)?
        var next: (time: Double, zoom: Zoom)?
        for e in self {
            guard case let .zoom(z) = e.kind else { continue }
            if e.recordTime <= t {
                prev = (e.recordTime, z)
            } else {
                next = (e.recordTime, z)
                break
            }
        }
        switch (prev, next) {
        case (nil, nil):
            return .identity
        case (let p?, nil):
            return p.zoom
        case (nil, let n?):
            return n.zoom
        case (let p?, let n?):
            let span = n.time - p.time
            guard span > 0 else { return n.zoom }
            let alpha = (t - p.time) / span
            return Zoom.lerp(p.zoom, n.zoom, alpha: alpha)
        }
    }
}

public extension Clip {
    /// Active Zoom at recordTime t. Thin delegator over events.zoomAt.
    func zoomAt(recordTime t: Double) -> Zoom {
        events.zoomAt(recordTime: t)
    }
}

public extension Zoom {
    static func lerp(_ a: Zoom, _ b: Zoom, alpha: Double) -> Zoom {
        let t = max(0, min(1, alpha))
        return Zoom(
            scale: a.scale + (b.scale - a.scale) * t,
            panX: a.panX + (b.panX - a.panX) * t,
            panY: a.panY + (b.panY - a.panY) * t
        )
    }
}
