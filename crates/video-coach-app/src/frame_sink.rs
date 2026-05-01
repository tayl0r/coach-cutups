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

#[cfg(any(feature = "media", test))]
use std::sync::atomic::Ordering;
use std::sync::atomic::{AtomicBool, AtomicU64};
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
///
/// Phase 9: gains `PreviewClip` for the preview-mode UI states. The
/// mirror only needs to distinguish "is the REC indicator visible" vs.
/// "is the preview transport visible"; the bus task is the source of
/// truth for which clip is in preview, so the mirror carries no UUID.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordingMode {
    Scanning,
    RecordingStarting,
    Recording,
    PreviewClip,
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

/// Phase 9 (fix #18). Snapshot of a project's `Clip` shaped for the
/// sidebar list. The bus task hydrates `Vec<ClipSummary>` on
/// OpenProject / NewProject / StopClipRecording (per fix #13). The UI
/// reads the slot in its 30 Hz timer and converts to the Slint model.
#[derive(Debug, Clone)]
pub struct ClipSummary {
    pub id: uuid::Uuid,
    pub name: String,
    pub recording_duration: f64,
    pub source_index: usize,
}

/// Shared list of clip summaries for the sidebar. Same shape as
/// `RecordingStateSlot` — bus writes, UI reads at display rate.
pub type ClipListSlot = Arc<Mutex<Vec<ClipSummary>>>;

pub fn new_clip_list() -> ClipListSlot {
    Arc::new(Mutex::new(Vec::new()))
}

/// Phase 9 (fix #3 + #26). Atomic handles exposed by a mounted FrameSink.
/// The bus owns one set per active pipeline (`current_player_mount`,
/// `current_preview_mount`) and uses them to:
///
/// - Flip `active=false` BEFORE pausing/teardown so straggler frames
///   from GStreamer's streaming thread land on the floor instead of
///   racing the next mount's first frame.
/// - Read `frames_pushed` on `clip_preview.closed` to populate the
///   harness E2E assertion (fix #26 — proves the pixel path actually
///   carried frames, not just the lifecycle round-trip).
#[derive(Clone)]
pub struct MountHandles {
    pub active: Arc<AtomicBool>,
    pub frames_pushed: Arc<AtomicU64>,
}

impl MountHandles {
    pub fn new() -> Self {
        Self {
            active: Arc::new(AtomicBool::new(true)),
            frames_pushed: Arc::new(AtomicU64::new(0)),
        }
    }
}

impl Default for MountHandles {
    fn default() -> Self {
        Self::new()
    }
}

/// Phase 9 (fix #3 + #26). The product of a `FrameMountFactory` invocation:
/// a freshly-built FrameSink trait object plus the atomic handles the
/// bus task uses to control / observe it.
#[cfg(feature = "media")]
pub struct MountedSink {
    pub sink: Box<dyn FrameSink>,
    pub active: Arc<AtomicBool>,
    pub frames_pushed: Arc<AtomicU64>,
}

#[cfg(feature = "media")]
impl MountedSink {
    pub fn handles(&self) -> MountHandles {
        MountHandles {
            active: self.active.clone(),
            frames_pushed: self.frames_pushed.clone(),
        }
    }
}

#[cfg(feature = "media")]
pub struct SlintFrameSink {
    slot: FrameSlot,
    /// `false` drops every incoming frame on the GStreamer streaming
    /// thread. The bus flips this to coordinate handover between the
    /// source player and the preview pipeline (fix #3).
    active: Arc<AtomicBool>,
    /// Incremented after the active check passes so the count reflects
    /// "frames that landed in the slot", not "frames the GStreamer
    /// thread tried to push" (fix #26). Read by the bus on
    /// ClosePreview to populate the `clip_preview.closed` event.
    frames_pushed: Arc<AtomicU64>,
}

#[cfg(feature = "media")]
impl SlintFrameSink {
    /// Phase 7 ctor — kept for tests + headless paths that don't need
    /// the active/counter handles. Internally allocates fresh atomics.
    pub fn new(slot: FrameSlot) -> Self {
        Self {
            slot,
            active: Arc::new(AtomicBool::new(true)),
            frames_pushed: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Phase 9 ctor — caller (the FrameMountFactory) supplies the atomics
    /// so it can hand the same handles back to the bus via `MountedSink`.
    pub fn with_handles(
        slot: FrameSlot,
        active: Arc<AtomicBool>,
        frames_pushed: Arc<AtomicU64>,
    ) -> Self {
        Self {
            slot,
            active,
            frames_pushed,
        }
    }
}

#[cfg(feature = "media")]
impl FrameSink for SlintFrameSink {
    fn push_frame(&self, width: u32, height: u32, data: &[u8]) {
        // Fix #3: drop straggler frames from a torn-down pipeline. The
        // GStreamer streaming thread can deliver one or two queued
        // frames after the bus has flipped to the next mount; without
        // this guard those land in the slot and overwrite the new
        // pipeline's first frame.
        if !self.active.load(Ordering::Acquire) {
            return;
        }
        // clone_from_slice copies into a freshly-allocated buffer;
        // SharedPixelBuffer is internally Arc'd so subsequent clones
        // (in the timer below) are free.
        let buf =
            slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(data, width, height);
        // overwrite the slot, dropping any prior un-displayed frame.
        let mut guard = self.slot.lock().expect("frame slot poisoned");
        *guard = Some(buf);
        // Fix #26: increment after the active check + slot write so the
        // counter reflects landed frames, not attempted ones. Relaxed
        // is sufficient — the bus reads this on ClosePreview after
        // flipping `active=false` AND after Recording::stop returns,
        // both of which provide stronger ordering than the counter
        // itself.
        self.frames_pushed.fetch_add(1, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_summary_clone_smoke() {
        // Construct a ClipSummary, push it through the slot, clone the
        // slot's contents, mutate the original — verify the clone is
        // independent. Establishes the Task-3 hydration contract:
        // bus writes to the slot, UI reads + clones, no ABA games.
        let slot: ClipListSlot = new_clip_list();
        let id = uuid::Uuid::new_v4();
        let summary = ClipSummary {
            id,
            name: "1-00:00:00".into(),
            recording_duration: 1.5,
            source_index: 0,
        };
        slot.lock().unwrap().push(summary.clone());
        let cloned: Vec<ClipSummary> = slot.lock().unwrap().clone();
        assert_eq!(cloned.len(), 1);
        assert_eq!(cloned[0].id, id);
        assert_eq!(cloned[0].name, "1-00:00:00");
        assert!((cloned[0].recording_duration - 1.5).abs() < f64::EPSILON);
        assert_eq!(cloned[0].source_index, 0);
        // Mutate the slot; the cloned vector is unaffected.
        slot.lock().unwrap().clear();
        assert_eq!(cloned.len(), 1);
    }

    #[test]
    fn mount_handles_default_active_true_counter_zero() {
        let h = MountHandles::new();
        assert!(h.active.load(Ordering::Acquire));
        assert_eq!(h.frames_pushed.load(Ordering::Relaxed), 0);
    }
}
