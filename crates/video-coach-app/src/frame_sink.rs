//! Phase 7 Task 4. Bridge from `video_coach_media::source_player::FrameSink`
//! (called on GStreamer's streaming thread, 30 fps, 8 MB per 1080p RGBA
//! frame) to a Slint `Image` property (read on the main thread by a
//! display-rate timer).
//!
//! Adversarial-review compliance:
//!
//! - **Single-slot overwrite, not per-frame `invoke_from_event_loop`.**
//!   The naïve "queue one closure per frame" pattern unbounded-queues
//!   when the UI thread is busy (slider drag, menu interaction, etc.) —
//!   GStreamer keeps decoding at 30 fps regardless of UI back-pressure
//!   and the Slint event loop fills with 8 MB pixel payloads. Instead,
//!   the streaming thread overwrites a single shared `Mutex<Option<...>>`
//!   slot. A 30 Hz timer on the UI thread reads the latest value and
//!   pushes it to the `source-frame` property exactly once per display
//!   tick. Old frames are dropped, never queued.
//!
//! - **Pool not implemented yet.** At 1080p×30fps the allocator sees
//!   ~250 MB/s of `Vec<u8>` churn from `clone_from_slice`. Modern
//!   macOS/Linux allocators handle large short-lived allocs well — if
//!   profiling later shows visible jitter, swap in a fixed-size buffer
//!   pool here. The single-slot overwrite design above means the pool
//!   only needs ~2 buffers (one being-written, one being-read).

#![allow(dead_code)] // referenced by ui::run when feature = "media"

use std::sync::{Arc, Mutex};

#[cfg(feature = "media")]
use video_coach_media::source_player::FrameSink;

/// Holds the latest decoded frame as a Slint-native `SharedPixelBuffer`
/// so the timer can hand it directly to `set_source_frame` without
/// another conversion. Cheap to clone (Arc-backed).
pub type FrameSlot = Arc<Mutex<Option<slint::SharedPixelBuffer<slint::Rgba8Pixel>>>>;

pub fn new_slot() -> FrameSlot {
    Arc::new(Mutex::new(None))
}

#[cfg(feature = "media")]
pub struct SlintFrameSink {
    slot: FrameSlot,
}

#[cfg(feature = "media")]
impl SlintFrameSink {
    pub fn new(slot: FrameSlot) -> Self {
        Self { slot }
    }
}

#[cfg(feature = "media")]
impl FrameSink for SlintFrameSink {
    fn push_frame(&self, width: u32, height: u32, data: &[u8]) {
        // clone_from_slice copies into a freshly-allocated buffer;
        // SharedPixelBuffer is internally Arc'd so subsequent clones
        // (in the timer below) are free.
        let buf =
            slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(data, width, height);
        // overwrite the slot, dropping any prior un-displayed frame.
        let mut guard = self.slot.lock().expect("frame slot poisoned");
        *guard = Some(buf);
    }
}
