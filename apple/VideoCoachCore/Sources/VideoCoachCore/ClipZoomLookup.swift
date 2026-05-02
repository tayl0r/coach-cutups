import Foundation

public extension Clip {
    /// Active Zoom at recordTime t, with linear interpolation between
    /// adjacent keyframes. Empty / before-first → identity (or first
    /// value if any). After-last → last value. Non-zoom events
    /// (.play, .pause, .skip, .stroke, .clearAll, .unknown) are ignored.
    func zoomAt(recordTime t: Double) -> Zoom {
        var prev: (time: Double, zoom: Zoom)?
        var next: (time: Double, zoom: Zoom)?
        for e in events {
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
