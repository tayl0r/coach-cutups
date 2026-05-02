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
///
/// **Phase 11 Plan #4 cache contract:** `Compositor` holds four
/// internal caches (PiP pipeline, stroke pipeline, pooled stroke VBO,
/// and a freeze-segment compose LRU). All are populated lazily inside
/// `compose` / `compose_with_identity` under interior-mutex'd state;
/// cache hits MUST produce byte-identical output to cache misses (a
/// parity divergence is a ship-blocker). Tests in `parity_smoke.rs`
/// and `parity_n_frames.rs` guard the invariant. Compositor is no
/// longer "stateless from the inside" but its EXTERNAL contract (same
/// input → same output) is unchanged.
///
/// Per Fix #49: internal caches total ~128 MB peak at 1080p RGBA
/// (16-entry freeze cache of `Arc<Frame>` composed outputs + small
/// pipeline / VBO state). Per-process. Single shared
/// `Arc<Compositor>` per Phase 10 fix #15.
pub fn compose_tick(
    compositor: &Compositor,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError> {
    compositor.compose(source, webcam, strokes)
}

/// Plan #4 Task 3 sibling of `compose_tick`. Wraps
/// `Compositor::compose_with_identity` so callers that already hold
/// `Arc<Frame>` for the source + webcam slots (preview/export drivers
/// after the Fix #48 consumer-boundary wrap) can hit the freeze-segment
/// compose cache. On a cache hit the returned `Arc<Frame>` is the SAME
/// one inserted on the prior miss; on a miss the GPU compose runs and
/// the result is wrapped in a fresh `Arc` before being inserted +
/// returned.
pub fn compose_tick_with_identity(
    compositor: &Compositor,
    source: &std::sync::Arc<Frame>,
    webcam: &std::sync::Arc<Frame>,
    strokes: &[VisibleStroke],
) -> Result<std::sync::Arc<Frame>, CompositorError> {
    compositor.compose_with_identity(source, webcam, strokes)
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        // Module wiring verified — runtime tests in subsequent tasks.
    }
}
