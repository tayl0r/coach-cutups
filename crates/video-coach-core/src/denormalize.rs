#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PixelPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CanvasSize {
    pub width: f64,
    pub height: f64,
}

/// Map a normalized (top-left origin, x and y in 0..1) stroke point into pixels.
///
/// `flip_y = true` for live overlays in a bottom-left-origin coordinate space.
/// `flip_y = false` for the export compositor, which already applies its own flip.
/// See `docs/plans/2026-04-27-video-coach-design.md` § "Drawing capture".
pub fn point(x: f64, y: f64, into: CanvasSize, flip_y: bool) -> PixelPoint {
    let px = x * into.width;
    let py = y * into.height;
    if flip_y {
        PixelPoint {
            x: px,
            y: into.height - py,
        }
    } else {
        PixelPoint { x: px, y: py }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_flip_passes_through() {
        let p = point(
            0.5,
            0.5,
            CanvasSize {
                width: 1920.0,
                height: 1080.0,
            },
            false,
        );
        assert_eq!(p, PixelPoint { x: 960.0, y: 540.0 });
    }

    #[test]
    fn flip_inverts_y() {
        let p = point(
            0.0,
            0.0,
            CanvasSize {
                width: 1920.0,
                height: 1080.0,
            },
            true,
        );
        assert_eq!(p, PixelPoint { x: 0.0, y: 1080.0 });
    }
}
