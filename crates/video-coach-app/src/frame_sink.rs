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
use std::time::Instant;

#[cfg(feature = "media")]
use video_coach_media::source_player::FrameSink;

/// Holds the latest decoded frame as a Slint-native `SharedPixelBuffer`
/// so the timer can hand it directly to `set_source_frame` without
/// another conversion. Cheap to clone (Arc-backed).
pub type FrameSlot = Arc<Mutex<Option<slint::SharedPixelBuffer<slint::Rgba8Pixel>>>>;

pub fn new_slot() -> FrameSlot {
    Arc::new(Mutex::new(None))
}

/// Phase 7 Task 5: transport state shared between the position-poll
/// task (writer, ~10 Hz) and the UI's display-rate timer (reader,
/// 30 Hz). Position lags the wall clock by at most one poll interval
/// (100 ms), which is fine for a transport label.
#[derive(Debug, Clone, Default)]
pub struct PlayerStateSlotData {
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub is_playing: bool,
    /// When the bus last issued a seek. The poll task skips updates
    /// that arrive within ~200 ms of this so the position bar doesn't
    /// briefly snap back to the pre-seek value while the decoder is
    /// still flushing. (Adversarial-review fix #8.)
    pub last_seek_at: Option<Instant>,
}

pub type PlayerStateSlot = Arc<Mutex<PlayerStateSlotData>>;

pub fn new_player_state() -> PlayerStateSlot {
    Arc::new(Mutex::new(PlayerStateSlotData::default()))
}

/// Phase 8: recording-mode state shared between the bus task (writer,
/// at mode transitions) and the UI's display-rate timer (reader, 30
/// Hz). Carries the current `AppMode` plus the host-time anchor for
/// the in-progress recording so the UI can compute elapsed `M:SS`
/// without a separate poll task.
///
/// Read order in the UI timer: this slot is read BEFORE
/// `PlayerStateSlot` so a transition out of `Recording` (REC indicator
/// clears) lands in the same frame as the player resuming, rather than
/// the player updating one tick before the indicator (visually
/// distracting). Adversarial-review fix #8.
#[derive(Debug, Clone, Copy)]
pub struct RecordingStateSlotData {
    pub mode: RecordingMode,
    /// `Some(t0)` while `mode != Scanning`; `None` otherwise. Used by
    /// the UI to compute elapsed seconds at display rate.
    pub recording_started_at_host: Option<Instant>,
}

/// Mirror of `bus::AppMode` that doesn't drag the bus module's serde
/// derives into `frame_sink`. Kept in lockstep with `AppMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordingMode {
    Scanning,
    RecordingStarting,
    Recording,
}

impl Default for RecordingStateSlotData {
    fn default() -> Self {
        Self {
            mode: RecordingMode::Scanning,
            recording_started_at_host: None,
        }
    }
}

pub type RecordingStateSlot = Arc<Mutex<RecordingStateSlotData>>;

pub fn new_recording_state() -> RecordingStateSlot {
    Arc::new(Mutex::new(RecordingStateSlotData::default()))
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
