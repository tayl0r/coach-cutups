pub mod compositor;
pub mod frame;

pub use compositor::{Compositor, CompositorError};
pub use frame::Frame;
// Re-export so callers don't need to depend on video-coach-core just to get
// the type that `compose()` / `compose_tick()` accept.
pub use video_coach_core::stroke_replay::VisibleStroke;

/// Canonical "one tick of preview/export work" entry point. Per phase-9
/// adversarial fix #24: the preview pipeline driver, Phase 5's
/// `compose.rs::compose_two_files`, and the parity test in Task 6 all call
/// this exact function so byte-for-byte parity across paths is structurally
/// enforced. Today it's a thin wrapper around `Compositor::compose`; future
/// per-tick orchestration (frame timing, stats counters, color-space
/// conversions) lands here without forking call sites.
pub fn compose_tick(
    compositor: &Compositor,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError> {
    compositor.compose(source, webcam, strokes)
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        // Module wiring verified — runtime tests in subsequent tasks.
    }
}
