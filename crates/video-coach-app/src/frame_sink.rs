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

use std::path::PathBuf;
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
///
/// Phase 10: gains `Exporting`. Per the plan's fix #9, `is_busy`
/// generalises to cover this mode too; the export sheet UI keys off it
/// to swap between the form view and the in-progress view. State
/// details (current tag, completed/total) ride on `ExportProgressSlot`,
/// not this mirror.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordingMode {
    Scanning,
    RecordingStarting,
    Recording,
    PreviewClip,
    Exporting,
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
///
/// Phase 10 (per the plan's Task 3 "pick (b)"): `tags` is included so
/// the UI's tag-aggregation step (export-sheet's tag list) can run
/// directly off the slot, without re-reading project.json or
/// round-tripping the bus. Mirrors the order of `Clip::tags`.
#[derive(Debug, Clone)]
pub struct ClipSummary {
    pub id: uuid::Uuid,
    pub name: String,
    pub recording_duration: f64,
    pub source_index: usize,
    pub tags: Vec<String>,
}

/// Shared list of clip summaries for the sidebar. Same shape as
/// `RecordingStateSlot` — bus writes, UI reads at display rate.
pub type ClipListSlot = Arc<Mutex<Vec<ClipSummary>>>;

pub fn new_clip_list() -> ClipListSlot {
    Arc::new(Mutex::new(Vec::new()))
}

/// Phase 10 Task 0 (fix #17 + #34). Outcome of a batch export run, as
/// observed by the UI. Four-state: nothing has happened (`None`), an
/// export is mid-flight (`InProgress`), the run finished one of three
/// ways (`SucceededAll`, `PartialFailure`, `Cancelled`).
///
/// The UI reads this slot in its 30 Hz timer to drive the export-sheet
/// view: `None` → form, `InProgress` → progress view, terminal states
/// → summary view (success/failure/cancelled banner). The bus is the
/// sole writer; transitions are linear and only flow forward through
/// the run before resetting to `None` on the user's "Done" click in
/// Task 3 (next state cycle).
///
/// The `folder` PathBuf on terminal states lets the UI's "Reveal in
/// Finder" button know where to point — we capture it here so a later
/// call to a different export can't overwrite it before the user
/// dismisses the summary.
#[derive(Debug, Clone, Default)]
pub enum ExportRunOutcome {
    /// No export has run this session, or the user dismissed a
    /// previous summary. The export-sheet shows the form.
    #[default]
    None,
    /// A batch export is mid-flight. UI shows the progress view; the
    /// `current_tag` / `completed_tags` / `total_tags` fields on the
    /// surrounding `ExportProgressSlotData` carry the spinner text.
    InProgress,
    /// Every selected tag's compilation rendered successfully. UI shows
    /// the success summary with `tag_count` rendered files.
    SucceededAll { folder: PathBuf, tag_count: usize },
    /// One tag's render failed; remaining tags were skipped. UI shows
    /// the partial-failure summary, naming the failing tag and showing
    /// the error string.
    PartialFailure {
        folder: PathBuf,
        completed: usize,
        failed_tag: String,
        error: String,
    },
    /// User clicked Cancel mid-export. The currently-rendering tag's
    /// partial output was deleted; tags rendered before that one stay
    /// on disk. UI shows the cancellation summary.
    Cancelled { folder: PathBuf, completed: usize },
}

/// Shared state for the export-sheet UI. Bus writer (mode + outcome
/// transitions), UI reader (30 Hz timer, drives the export-sheet view).
///
/// Mirrors the Phase 9 `RecordingStateSlot` pattern: the bus owns
/// transitions, the UI observes. Lock duration is short — read +
/// `clone()` of the small enum + a few `usize`/`Option<String>` fields,
/// no I/O or window calls under the lock.
///
/// Phase 11 Plan #2 (real-progress-pct): the slot gains
/// `current_tag_progress` and `batch_progress` `f32`s, fed by the bus's
/// throttled `on_progress` writer (lineage: Phase 10 fix #23 wired
/// `frames_pushed` through `ExportProgress`; this plan turns it into a
/// 0..1 bar). `Default` derivation keeps both fields at 0.0 for the
/// initial / `None` outcome — see the per-arm defaults in `ui.rs`'s
/// timer block.
#[derive(Debug, Clone, Default)]
pub struct ExportProgressSlotData {
    /// Where the run is in its life cycle. See `ExportRunOutcome`.
    pub outcome: ExportRunOutcome,
    /// `Some(tag)` while `outcome == InProgress`; `None` otherwise.
    /// Carries the current tag's display label (`"all-clips"` for the
    /// synthetic row, otherwise the tag name).
    pub current_tag: Option<String>,
    /// Running count of completed tags. Also valid during `InProgress`
    /// (set to N when the (N+1)-th tag begins rendering).
    pub completed_tags: usize,
    /// Total tags in the batch. Set when the run starts; held through
    /// terminal states so the summary view can show "5 of 5
    /// rendered".
    pub total_tags: usize,
    /// Phase 11 Plan #2. 0..1 progress of the currently-rendering tag.
    /// Set whenever `outcome == InProgress`; clamped to [0.0, 1.0].
    /// Reset to 0.0 at the top of each tag iteration before the
    /// per-frame push loop starts. Held at its last value through
    /// terminal-state transitions so a snapshot at completion isn't
    /// visually weird, but the UI ignores this field outside
    /// `InProgress`. Default is 0.0.
    pub current_tag_progress: f32,
    /// Phase 11 Plan #2. 0..1 progress of the entire batch. Computed
    /// in the throttled writer as
    /// `(i as f32 + current_tag_progress) / total_tags as f32`,
    /// clamped to [0.0, 1.0]. Same lifecycle notes as
    /// `current_tag_progress`. Default is 0.0.
    pub batch_progress: f32,
}

pub type ExportProgressSlot = Arc<Mutex<ExportProgressSlotData>>;

pub fn new_export_progress() -> ExportProgressSlot {
    Arc::new(Mutex::new(ExportProgressSlotData::default()))
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
            tags: vec!["basketball".into(), "drills".into()],
        };
        slot.lock().unwrap().push(summary.clone());
        let cloned: Vec<ClipSummary> = slot.lock().unwrap().clone();
        assert_eq!(cloned.len(), 1);
        assert_eq!(cloned[0].id, id);
        assert_eq!(cloned[0].name, "1-00:00:00");
        assert!((cloned[0].recording_duration - 1.5).abs() < f64::EPSILON);
        assert_eq!(cloned[0].source_index, 0);
        assert_eq!(cloned[0].tags, vec!["basketball", "drills"]);
        // Mutate the slot; the cloned vector is unaffected.
        slot.lock().unwrap().clear();
        assert_eq!(cloned.len(), 1);
    }

    #[test]
    fn export_progress_slot_defaults_to_none_outcome() {
        // Phase 10 Task 0 (fix #17). Fresh slot is the form-view state:
        // outcome=None, no current tag, zero counts.
        // Phase 11 Plan #2: also verify the new f32 progress fields
        // default to 0.0 cleanly (Default-derive).
        let slot = new_export_progress();
        let g = slot.lock().unwrap();
        assert!(matches!(g.outcome, ExportRunOutcome::None));
        assert!(g.current_tag.is_none());
        assert_eq!(g.completed_tags, 0);
        assert_eq!(g.total_tags, 0);
        assert_eq!(g.current_tag_progress, 0.0);
        assert_eq!(g.batch_progress, 0.0);
    }

    #[test]
    fn mount_handles_default_active_true_counter_zero() {
        let h = MountHandles::new();
        assert!(h.active.load(Ordering::Acquire));
        assert_eq!(h.frames_pushed.load(Ordering::Relaxed), 0);
    }
}
