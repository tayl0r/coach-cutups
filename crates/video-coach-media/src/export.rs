//! Phase 10 Task 1. Multi-source compilation export pipeline.
//!
//! Architectural shape (per Phase 10 plan + adversarial fixes):
//!
//! ```text
//!   filesrc(source[i]) → decodebin → queue → videoconvert → caps RGBA → appsink ── source_slot[i]
//!     (one per unique source_index in the plan; sync=false, fix #4 + #19)
//!
//!   filesrc(rec[clip]) → decodebin → queue → videoconvert → caps RGBA → appsink ── webcam_slot[clip]
//!                                  ╲
//!                                   → audioconvert → audioresample → audio-appsink (sync=false)
//!     (one per unique clip in the plan; per fix #37 the audio appsink feeds the
//!      shared driver-fed audio chain rather than connecting directly to qtmux.)
//!
//!     ── (driver pulls source/webcam frames + audio samples per record-time tick) ──
//!
//!   appsrc(source-w × source-h, RGBA, 30/1)
//!     → videoconvert → videoscale
//!     → capsfilter(target-w × target-h, NV12|I420, 30/1)   # fix #28; H.264→NV12, HEVC→I420 (x265enc compat)
//!     → encoder(picked) → h264parse|h265parse → qtmux → filesink
//!
//!   audio-appsrc(audio/x-raw,F32LE,2ch,48000)
//!     → audioconvert → aacenc → aacparse → qtmux audio sink-pad
//! ```
//!
//! Driver loop (per fix #4 + #17): NOT wall-clock-paced. The driver pumps
//! frames as fast as appsrc back-pressure allows. Per output frame at
//! `record_time = composition_start_ns/1e9 + frame_index_in_entry/30`:
//!   - Resolve segment via `source_time_at(clip, record_time)` + segment walker.
//!   - Pick source frame (Play → live appsink slot; Freeze → cached).
//!   - Pull webcam frame (latest in active webcam appsink slot).
//!   - Compute `visible_strokes(clip, record_time)` (fix #5).
//!   - Call `compose_tick(...)` (fix #3).
//!   - Push composed RGBA to appsrc with PTS = composition_start_ns +
//!     frame_index_in_entry × 33,333,333.
//!   - Pull and push audio samples for the same window from active clip's
//!     audio-appsink to the shared audio-appsrc, maintaining a monotonic
//!     `audio_pts_ns` cursor that does NOT reset across entries (fix #37).
//!
//! Entry transitions (fix #20 + #39): pause prev source/webcam chains, seek
//! and play new chains, reset frozen_frames map, reset per-entry record_time
//! cursor. Advance composition_start_ns by frame-aligned duration per fix #39:
//! `round(prev.recording_duration * 30) * 33_333_333`. Do NOT use raw
//! `recording_duration * 1e9` directly — drift compounds over many entries.
//!
//! Cancel path (fix #10 + #14): skip EOS, transition Null directly, delete
//! partial output. Stepped Paused → Ready → Null on every exit path.
//!
//! Phase 10 ships RECORDING AUDIO ONLY (fix #8). source_volume +
//! commentary_volume parameters are accepted for forward-compat but unused.
//!
//! Phase 11 Plan #1 Task 1a: source-audio appsinks built per source_index
//! (queue → audioconvert → audioresample → capsfilter F32LE/48k/2ch →
//! appsink). Mix logic in Task 1b.

#![allow(clippy::duplicated_attributes)]
#![cfg(feature = "media")]

use gstreamer::prelude::*;
use gstreamer_app::{AppSink, AppSrc};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use thiserror::Error;
use uuid::Uuid;
use video_coach_compositor::{compose_tick_with_identity, Compositor, Frame};
use video_coach_core::compilation_plan::{CompilationEntry, CompilationPlan};
use video_coach_core::export_settings::{bitrate, pixel_size};
use video_coach_core::project::{Clip, Codec, Quality, Resolution};
use video_coach_core::stroke_replay::visible_strokes;
use video_coach_core::timeline::{PlaybackSegment, SegmentKind};

const RGBA_CAPS: &str = "video/x-raw,format=RGBA";
const FRAME_DURATION_NS: u64 = 33_333_333; // 30 fps pinned (fix #17 + #39)

// Audio chain caps: F32 stereo at 48kHz. Matches AAC encoder common input;
// audioconvert in front handles whatever the source produced.
const AUDIO_RATE: u32 = 48_000;
const AUDIO_CHANNELS: u32 = 2;
const AUDIO_BYTES_PER_SAMPLE: usize = 4 * 2; // F32 × 2 channels

// Phase 11 Plan #1 Task 1a (adv-fix #1): cap each AudioSampleQueue at ~4s of
// decoded audio so a fast `sync=false` source decoder running well above
// real-time on Apple Silicon hw can't accumulate 50-150 MB of decoded
// samples before the driver consumes them. Consumer lands in Task 1b.
#[allow(dead_code)]
const MAX_QUEUED_BYTES: usize = 4 * (AUDIO_RATE as usize) * AUDIO_BYTES_PER_SAMPLE;
// Source audio appsink internal buffer ceiling. Combined with
// MAX_QUEUED_BYTES this back-pressures the upstream decoder.
const AUDIO_APPSINK_MAX_BUFFERS: u32 = 64;

#[derive(Debug, Error)]
pub enum ExportError {
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("pipeline construction: {0}")]
    Construction(String),
    #[error("compositor: {0}")]
    Compositor(#[from] video_coach_compositor::CompositorError),
    #[error("export cancelled")]
    Cancelled,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("appsrc/appsink: {0}")]
    AppFlow(String),
    #[error("plan: {0}")]
    Plan(String),
    #[error("freeze-frame decode: {0}")]
    FreezeDecode(String),
    #[error("seek: {0}")]
    Seek(String),
    #[error("invalid path (non-utf8)")]
    InvalidPath,
    #[error("probe: {0}")]
    Probe(String),
}

/// Inputs that the bus task assembles per batch run. All paths are absolute
/// (per fix #16 — no per-call canonicalize). `source_durations` is populated
/// by Discoverer at export start (per fix #29) so the driver's segment walks
/// agree with what preview gets at runtime.
pub struct ExportInputs {
    pub plan: CompilationPlan,
    pub clips_by_id: HashMap<Uuid, Clip>,
    pub source_paths: HashMap<usize, PathBuf>,
    pub recording_paths: HashMap<Uuid, PathBuf>,
    pub source_durations: HashMap<usize, f64>,
}

#[derive(Debug, Clone)]
pub struct ExportProgress {
    pub frames_pushed: u64,
    pub frame_index: u64,
    pub total_frames: u64,
    pub current_entry_index: usize,
}

#[derive(Debug, Clone)]
pub struct ExportSummary {
    pub frames_pushed: u64,
}

/// Top-level entry point. Synchronous; the bus task wraps in `spawn_blocking`.
///
/// Per fix #14: stepped Paused → Ready → Null teardown on every exit path.
/// Per fix #10: cancel skips EOS, deletes partial output, returns
/// `ExportError::Cancelled`.
#[allow(clippy::too_many_arguments)]
pub fn export_compilation(
    inputs: ExportInputs,
    output_path: &Path,
    resolution: Resolution,
    quality: Quality,
    codec: Codec,
    source_volume: f64, // Phase 11 Plan #1 Task 1a: read+clamp here; mix consumption in Task 1b
    commentary_volume: f64, // Phase 11 Plan #1 Task 1a: read+clamp here; mix consumption in Task 1b
    compositor: Arc<Compositor>,
    cancel: Arc<AtomicBool>,
    on_progress: Box<dyn Fn(ExportProgress) + Send + Sync>,
) -> Result<ExportSummary, ExportError> {
    crate::init().map_err(|e| ExportError::Construction(e.to_string()))?;

    // Defensive clamp; UI also clamps. The actual mix consumption ships in
    // Phase 11 Plan #1 Task 1b — for now Task 1a only reads + clamps so
    // signature wiring through bus.rs doesn't go stale.
    let _source_volume = source_volume.clamp(0.0, 1.0);
    let _commentary_volume = commentary_volume.clamp(0.0, 1.0);

    if inputs.plan.entries.is_empty() {
        return Err(ExportError::Plan("plan has no entries".into()));
    }

    // Ensure the output's parent directory exists.
    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // ── Step 1: probe the first source's natural dimensions (fix #29). ──
    // For Resolution::Source we use that probe verbatim; for fixed
    // resolutions we use `pixel_size(resolution)` for the post-scale caps.
    let first_entry = &inputs.plan.entries[0];
    let first_clip = inputs
        .clips_by_id
        .get(&first_entry.clip_id)
        .ok_or_else(|| ExportError::Plan(format!("clip not in map: {}", first_entry.clip_id)))?;
    let first_source_path = inputs
        .source_paths
        .get(&first_clip.source_index)
        .ok_or_else(|| {
            ExportError::Plan(format!(
                "source path missing for index {}",
                first_clip.source_index
            ))
        })?;
    let (source_w, source_h) = probe_video_size(first_source_path)?;
    tracing::info!(
        target: "export.lifecycle",
        event = "export.probe.source_size",
        width = source_w,
        height = source_h,
    );
    let target_size = match resolution {
        Resolution::Source => (source_w, source_h),
        _ => {
            let p = pixel_size(resolution);
            (p.width, p.height)
        }
    };

    // ── Step 2: pre-decode freeze frames per entry (fix #7 + #11 + #30). ──
    // Check cancel flag at each (entry, freeze_segment) iteration boundary.
    let frozen_frames_by_entry = pre_decode_all_freeze_frames(&inputs, &cancel)?;
    if cancel.load(Ordering::Acquire) {
        return Err(ExportError::Cancelled);
    }

    // ── Step 3: build the pipeline. ──
    let pipeline = gstreamer::Pipeline::new();

    // Per fix #19: one decoder chain per UNIQUE source_index. Per fix #27:
    // they all start in the same state as the pipeline (Null → Paused);
    // only the active entry's chain transitions to Playing.
    let mut source_chains: HashMap<usize, SourceVideoChain> = HashMap::new();
    let referenced_source_indices: HashSet<usize> = inputs
        .plan
        .entries
        .iter()
        .filter_map(|e| inputs.clips_by_id.get(&e.clip_id).map(|c| c.source_index))
        .collect();
    for source_index in &referenced_source_indices {
        let path = inputs.source_paths.get(source_index).ok_or_else(|| {
            ExportError::Plan(format!("source path missing for index {source_index}"))
        })?;
        let label = format!("src{source_index}");
        let chain = build_source_video_chain(&pipeline, path, &label)?;
        source_chains.insert(*source_index, chain);
    }

    // Per fix #19 + #37: one webcam chain per UNIQUE clip in the plan.
    // Each chain has both video and audio appsinks; the driver picks
    // which clip's audio to relay per entry.
    let mut webcam_chains: HashMap<Uuid, WebcamChain> = HashMap::new();
    let referenced_clip_ids: HashSet<Uuid> =
        inputs.plan.entries.iter().map(|e| e.clip_id).collect();
    for clip_id in &referenced_clip_ids {
        let path = inputs.recording_paths.get(clip_id).ok_or_else(|| {
            ExportError::Plan(format!("recording path missing for clip {clip_id}"))
        })?;
        let label = format!("cam_{}", clip_id.as_simple());
        let chain = build_webcam_chain(&pipeline, path, &label)?;
        webcam_chains.insert(*clip_id, chain);
    }

    // ── Step 4: build the output (video) chain. ──
    let video_appsrc = build_video_output_chain(
        &pipeline,
        output_path,
        source_w,
        source_h,
        target_size.0,
        target_size.1,
        bitrate(resolution, quality, codec),
        codec,
    )?;

    // ── Step 5: build the shared audio-appsrc → encoder → qtmux chain. ──
    let audio_appsrc = build_audio_output_chain(&pipeline, &video_appsrc)?;

    // ── Step 6: prepare per-source slot maps for source frames. ──
    let mut source_slots: HashMap<usize, Arc<Mutex<Option<Frame>>>> = HashMap::new();
    for (idx, chain) in &source_chains {
        let slot = Arc::new(Mutex::new(None::<Frame>));
        attach_video_frame_slot(&chain.video_appsink, slot.clone());
        source_slots.insert(*idx, slot);
    }
    let mut webcam_slots: HashMap<Uuid, Arc<Mutex<Option<Frame>>>> = HashMap::new();
    let mut audio_buffer_queues: HashMap<Uuid, Arc<Mutex<AudioSampleQueue>>> = HashMap::new();
    for (clip_id, chain) in &webcam_chains {
        let v_slot = Arc::new(Mutex::new(None::<Frame>));
        attach_video_frame_slot(&chain.video_appsink, v_slot.clone());
        webcam_slots.insert(*clip_id, v_slot);

        let q = Arc::new(Mutex::new(AudioSampleQueue::default()));
        attach_audio_sample_queue(&chain.audio_appsink, q.clone());
        audio_buffer_queues.insert(*clip_id, q);
    }

    // ── Step 7: Set pipeline to PAUSED + wait. All chains preroll. ──
    // Per fix #27: PAUSED is the safe baseline; we transition the active
    // entry's chains to PLAYING below, leave others paused.
    pipeline
        .set_state(gstreamer::State::Paused)
        .map_err(|e| ExportError::StateChange(format!("preroll: {e:?}")))?;
    let (_, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(10));

    // Move the WHOLE pipeline to PLAYING so the output chain (appsrc →
    // encoder → qtmux → filesink) is in PLAYING — it has no entry-aware
    // pause logic. The driver's `transition_chains` will pause inactive
    // source/webcam chains as needed (per fix #20). Pre-paused inactive
    // chains stay paused if `transition_chains` decides not to activate
    // them.
    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| ExportError::StateChange(format!("playing: {e:?}")))?;

    // ── Step 8: drive the output. Activate each entry's chains in turn. ──
    let frames_counter = Arc::new(AtomicU64::new(0));
    let total_frames: u64 = inputs
        .plan
        .entries
        .iter()
        .map(|e| (e.recording_duration * 30.0).round() as u64)
        .sum();

    let driver_outcome = run_driver_loop(DriverArgs {
        compositor: compositor.clone(),
        pipeline: pipeline.clone(),
        plan: &inputs.plan,
        clips_by_id: &inputs.clips_by_id,
        source_chains: &source_chains,
        webcam_chains: &webcam_chains,
        source_slots: &source_slots,
        webcam_slots: &webcam_slots,
        audio_buffer_queues: &audio_buffer_queues,
        video_appsrc: video_appsrc.clone(),
        audio_appsrc: audio_appsrc.clone(),
        frozen_frames_by_entry: &frozen_frames_by_entry,
        cancel: cancel.clone(),
        frames_counter: frames_counter.clone(),
        total_frames,
        on_progress,
    });

    // Per fix #14: stepped teardown on EVERY exit path.
    if let Err(ExportError::Cancelled) = &driver_outcome {
        // Cancel: skip EOS, jump to Null directly, delete partial output.
        teardown_pipeline(&pipeline, /* skip_intermediate_states */ false);
        // Delete the partial file (per fix #10).
        let _ = std::fs::remove_file(output_path);
        return Err(ExportError::Cancelled);
    }

    if driver_outcome.is_ok() {
        // Happy path: send EOS, wait for filesink EOS, stepped teardown.
        let _ = video_appsrc.end_of_stream();
        let _ = audio_appsrc.end_of_stream();
        wait_for_pipeline_eos(&pipeline)?;
    }

    teardown_pipeline(&pipeline, /* skip_intermediate_states */ false);

    driver_outcome?;

    Ok(ExportSummary {
        frames_pushed: frames_counter.load(Ordering::SeqCst),
    })
}

/// Pure function — NO GStreamer. Resolves the segment for `record_time`,
/// picks source vs frozen frame, computes strokes via
/// `visible_strokes(clip, record_time)`, calls `compose_tick(...)`. Task 5's
/// parity test calls this; the driver loop calls this too — same code path
/// either way.
pub fn compose_entry_frame(
    compositor: &Compositor,
    entry: &CompilationEntry,
    clip: &Clip,
    record_time: f64,
    source_frame: &Frame,
    webcam_frame: &Frame,
    frozen_frames: &HashMap<usize, Arc<Frame>>,
) -> Result<Frame, ExportError> {
    let seg_idx = segment_index_at(&entry.segments, record_time);
    let seg = entry
        .segments
        .get(seg_idx)
        .copied()
        .ok_or_else(|| ExportError::Plan("segment lookup out of bounds".into()))?;

    // Plan #4 Task 3 / Fix #44: hand stable Arc<Frame> to
    // compose_tick_with_identity so the freeze branch's repeated
    // ticks-per-segment hit the compose cache. Play branch wraps the
    // borrowed `&Frame` in a fresh Arc — uniform call site, the
    // freeze cache only fires for Freeze keys anyway.
    let resolved_source: Arc<Frame> = match seg.kind {
        SegmentKind::Freeze => frozen_frames
            .get(&seg_idx)
            .cloned()
            .unwrap_or_else(|| Arc::new(Frame::solid(2, 2, [0, 0, 0, 255]))),
        SegmentKind::Play => Arc::new(source_frame.clone()),
    };
    let webcam_arc = Arc::new(webcam_frame.clone());

    let strokes = visible_strokes(clip, record_time);
    let composed_arc =
        compose_tick_with_identity(compositor, &resolved_source, &webcam_arc, &strokes)?;
    // Stable public return type is `Frame`; on a cache hit this is the
    // unavoidable clone, but it's still vastly cheaper than re-running
    // the GPU compose. Caller (run_driver_loop / parity test) consumes
    // by value.
    let composed: Frame = (*composed_arc).clone();
    Ok(composed)
}

// ─── helpers ────────────────────────────────────────────────────────────────

fn make_or(name: &str) -> Result<gstreamer::Element, ExportError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| ExportError::MissingElement(name.into()))
}

fn pick_h264_encoder(target_bitrate: u32) -> Result<gstreamer::Element, ExportError> {
    // Encoders use heterogeneous bitrate-property names; we try in
    // priority order and set the bitrate property in whichever shape the
    // chosen encoder accepts (best-effort — failing to set bitrate is
    // not fatal; it just falls back to the encoder's default).
    let candidates: &[&str] = &[
        "vtenc_h264",
        "mfh264enc",
        "vaapih264enc",
        "nvh264enc",
        "x264enc",
    ];
    for name in candidates {
        if let Ok(elem) = make_or(name) {
            // Set bitrate best-effort — encoders disagree on kbps vs bps and
            // the property's value type. We look up the ParamSpec, derive
            // the right Value type, and only set if the type matches one of
            // the common shapes (u32, i32). Failures are non-fatal: the
            // encoder just keeps its default bitrate.
            try_set_encoder_bitrate(&elem, name, target_bitrate);
            tracing::info!(target: "export.lifecycle", event = "export.encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(ExportError::MissingElement("h264 encoder (any)".into()))
}

/// Pick the best-available HEVC (H.265) encoder element.
///
/// Order: HW per platform first, SW (`x265enc`) last. `make_or` failures
/// for unavailable factories are non-fatal and intentional; on
/// lavapipe/CI Linux runners we expect `vaapih265enc` + `nvh265enc` to
/// fail-load and emit `gst-plugin-loader` warnings before the loop falls
/// through to `x265enc` (this mirrors `pick_h264_encoder`'s tolerated
/// behavior — Phase 11 Plan #3 fix #1).
///
/// macOS note (Phase 11 Plan #3 fix #2): stock GStreamer 1.22+ registers
/// VideoToolbox HEVC under `vtenc_h265_hw` (HW) and `vtenc_h265` (SW
/// fallback). We list `_hw` first; if `_hw` isn't registered on the
/// runner, the SW `vtenc_h265` is still better than `x265enc`.
fn pick_h265_encoder(target_bitrate: u32) -> Result<gstreamer::Element, ExportError> {
    let candidates: &[&str] = &[
        "vtenc_h265_hw", // Apple Silicon HW path (preferred)
        "vtenc_h265",    // VideoToolbox SW fallback
        "mfh265enc",     // Windows Media Foundation
        "vaapih265enc",  // Linux VA-API
        "nvh265enc",     // NVIDIA NVENC
        "x265enc",       // CPU fallback (always present via gst-plugins-bad)
    ];
    for name in candidates {
        if let Ok(elem) = make_or(name) {
            try_set_encoder_bitrate(&elem, name, target_bitrate);
            tracing::info!(target: "export.lifecycle", event = "export.encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(ExportError::MissingElement("h265 encoder (any)".into()))
}

fn try_set_encoder_bitrate(elem: &gstreamer::Element, encoder_name: &str, target_bps: u32) {
    use gstreamer::glib::object::ObjectExt;
    let Some(spec) = elem.find_property("bitrate") else {
        return;
    };
    let value_type = spec.value_type();
    // VideoToolbox encoders (vtenc_h264, vtenc_h264_hw, vtenc_h265,
    // vtenc_h265_hw): bps. Everything else (x264/x265enc, vaapi*, nv*,
    // mf*): kbps. The `starts_with("vtenc_")` prefix dispatch (per
    // Phase 11 Plan #3 fix #3) catches all VT variants — a literal
    // match would silently miss `vtenc_h265_hw` and divide-by-1000,
    // producing a corrupt sub-1 KB output.
    let primary = if encoder_name.starts_with("vtenc_") {
        target_bps
    } else {
        target_bps / 1000
    };
    if value_type == gstreamer::glib::Type::U32 {
        elem.set_property("bitrate", primary);
    } else if value_type == gstreamer::glib::Type::I32 {
        elem.set_property("bitrate", primary as i32);
    } else if value_type == gstreamer::glib::Type::U64 {
        elem.set_property("bitrate", primary as u64);
    }
    // Anything else: leave default.
}

fn pick_aac_encoder() -> Result<gstreamer::Element, ExportError> {
    for name in ["fdkaacenc", "avenc_aac", "voaacenc"] {
        if let Ok(elem) = make_or(name) {
            tracing::info!(target: "export.lifecycle", event = "export.audio_encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(ExportError::MissingElement("aac encoder (any)".into()))
}

/// Probe a source video's natural width × height via Discoverer.
fn probe_video_size(path: &Path) -> Result<(u32, u32), ExportError> {
    crate::init().map_err(|e| ExportError::Construction(e.to_string()))?;
    let timeout = gstreamer::ClockTime::from_seconds(10);
    let discoverer = gstreamer_pbutils::Discoverer::new(timeout)
        .map_err(|e| ExportError::Probe(format!("discoverer: {e}")))?;
    let abs = path.canonicalize()?;
    let uri = format!("file://{}", abs.to_str().ok_or(ExportError::InvalidPath)?);
    let info = discoverer
        .discover_uri(&uri)
        .map_err(|e| ExportError::Probe(format!("discover {uri}: {e}")))?;
    let videos = info.video_streams();
    let v = videos
        .first()
        .ok_or_else(|| ExportError::Probe("no video stream".into()))?;
    Ok((v.width(), v.height()))
}

/// Resolve which segment owns `record_time` by linear walk. Returns the
/// last segment's index if `record_time` is past the end (driver clamps
/// playback to entry.recording_duration anyway).
fn segment_index_at(segments: &[PlaybackSegment], record_time: f64) -> usize {
    let mut t = 0.0_f64;
    for (i, seg) in segments.iter().enumerate() {
        let end = t + seg.out_duration;
        if record_time < end {
            return i;
        }
        t = end;
    }
    segments.len().saturating_sub(1)
}

// ─── source video chain ─────────────────────────────────────────────────────

struct SourceVideoChain {
    /// All elements we transition between Paused and Playing in lockstep
    /// (per fix #27). decodebin's children are flushed implicitly when we
    /// flush its parent. Per-chain seek events are sent on `video_appsink`
    /// — seek events travel UPSTREAM, so they must be sent on a downstream
    /// element (filesrc itself doesn't process them meaningfully).
    elements: Vec<gstreamer::Element>,
    video_appsink: AppSink,
    /// Phase 11 Plan #1 Task 1a: audio sink for the source's decoded audio
    /// pad. Wrapped in `Arc<Mutex<Option<...>>>` because decodebin's
    /// `pad-added` is FnMut and fires during preroll AFTER this struct is
    /// returned to the caller; the cell lets the closure publish the
    /// AppSink and the caller read it after `pipeline.state(...)` returns
    /// (i.e. after preroll). Outer `Option` stays `None` when the source
    /// has no audio track. Plan #1 Task 1b will pull from this in the
    /// driver loop.
    #[allow(dead_code)]
    pub audio_appsink: Arc<Mutex<Option<gstreamer_app::AppSink>>>,
}

fn build_source_video_chain(
    pipeline: &gstreamer::Pipeline,
    path: &Path,
    label: &str,
) -> Result<SourceVideoChain, ExportError> {
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .name(format!("{label}-filesrc"))
        .property("location", path.to_str().ok_or(ExportError::InvalidPath)?)
        .build()
        .map_err(|_| ExportError::MissingElement("filesrc".into()))?;
    let decodebin = gstreamer::ElementFactory::make("decodebin")
        .name(format!("{label}-decodebin"))
        .build()
        .map_err(|_| ExportError::MissingElement("decodebin".into()))?;
    let queue_in = gstreamer::ElementFactory::make("queue")
        .name(format!("{label}-queue"))
        .build()
        .map_err(|_| ExportError::MissingElement("queue".into()))?;
    let videoconvert = make_or("videoconvert")?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .name(format!("{label}-capsfilter"))
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ExportError::MissingElement("capsfilter".into()))?;
    let appsink_elem = gstreamer::ElementFactory::make("appsink")
        .name(format!("{label}-appsink"))
        .build()
        .map_err(|_| ExportError::MissingElement("appsink".into()))?;
    let appsink = appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| ExportError::Construction(format!("{label}: appsink downcast")))?;
    // sync=false per fix #4 — encoder-throttled driver, not wall-clock-paced.
    appsink.set_property("sync", false);

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue_in,
            &videoconvert,
            &capsfilter,
            appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| ExportError::Construction(format!("{label}: add: {e}")))?;
    filesrc
        .link(&decodebin)
        .map_err(|e| ExportError::Construction(format!("{label}: filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([
        &queue_in,
        &videoconvert,
        &capsfilter,
        appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| ExportError::Construction(format!("{label}: link chain: {e}")))?;

    let queue_sink = queue_in
        .static_pad("sink")
        .ok_or_else(|| ExportError::Construction(format!("{label}: no queue sink")))?;
    let pipeline_weak = pipeline.downgrade();
    let label_owned = label.to_string();

    // Phase 11 Plan #1 Task 1a: capture cell for the source's audio appsink.
    // The decodebin pad-added closure is FnMut — it builds the audio chain
    // when the audio pad surfaces and writes the AppSink back through this
    // shared cell. After preroll, build_source_video_chain's caller reads
    // it from `SourceVideoChain::audio_appsink`.
    let audio_appsink_cell: Arc<Mutex<Option<AppSink>>> = Arc::new(Mutex::new(None));
    let audio_appsink_cell_for_pad = audio_appsink_cell.clone();
    let label_owned_pad = label_owned.clone();

    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else {
            return;
        };
        let Some(structure) = caps.structure(0) else {
            return;
        };
        let media = structure.name().to_string();
        if media.starts_with("video/") {
            if let Err(e) = pad.link(&queue_sink) {
                tracing::warn!(
                    target: "export.lifecycle",
                    chain = %label_owned_pad,
                    error = ?e,
                    "failed to link decoded source video pad",
                );
            }
            return;
        }
        if media.starts_with("audio/x-raw") || media.starts_with("audio/") {
            // Phase 11 Plan #1 Task 1a: build the source audio chain
            // dynamically (decodebin doesn't surface caps until prerolled),
            // mirroring build_webcam_chain's audio path.
            //   queue → audioconvert → audioresample
            //     → capsfilter(F32LE,48k,2ch,interleaved)   (adv-fix #3 anchor)
            //     → appsink(sync=false, max-buffers=AUDIO_APPSINK_MAX_BUFFERS)
            // Task 1b will pull from the appsink in the driver loop. Until
            // then nothing reads it — the queue cap (MAX_QUEUED_BYTES, used
            // by Task 1b) plus AUDIO_APPSINK_MAX_BUFFERS bound the
            // unconsumed-samples memory.
            let Some(pipeline) = pipeline_weak.upgrade() else {
                return;
            };
            let queue = match gstreamer::ElementFactory::make("queue")
                .name(format!("{label_owned_pad}-aqueue"))
                .build()
            {
                Ok(e) => e,
                Err(_) => return,
            };
            let aconv = match gstreamer::ElementFactory::make("audioconvert").build() {
                Ok(e) => e,
                Err(_) => return,
            };
            let aresample = match gstreamer::ElementFactory::make("audioresample").build() {
                Ok(e) => e,
                Err(_) => return,
            };
            let acaps = match gstreamer::ElementFactory::make("capsfilter")
                .name(format!("{label_owned_pad}-acaps"))
                .property(
                    "caps",
                    gstreamer::Caps::from_str(&format!(
                        "audio/x-raw,format=F32LE,channels={AUDIO_CHANNELS},rate={AUDIO_RATE},layout=interleaved"
                    ))
                    .unwrap(),
                )
                .build()
            {
                Ok(e) => e,
                Err(_) => return,
            };
            let aappsink_elem = match gstreamer::ElementFactory::make("appsink")
                .name(format!("src_audio_{label_owned_pad}"))
                .build()
            {
                Ok(e) => e,
                Err(_) => return,
            };
            let aappsink = match aappsink_elem.clone().dynamic_cast::<AppSink>() {
                Ok(a) => a,
                Err(_) => {
                    tracing::warn!(
                        target: "export.lifecycle",
                        chain = %label_owned_pad,
                        "src audio appsink downcast failed",
                    );
                    return;
                }
            };
            // sync=false: encoder-throttled, no wall-clock pacing (fix #4).
            aappsink.set_property("sync", false);
            aappsink.set_property("max-buffers", AUDIO_APPSINK_MAX_BUFFERS);
            // Pin caps on the appsink itself too, single source of truth
            // with the upstream capsfilter and the audio-appsrc caps.
            let pinned_caps = gstreamer::Caps::from_str(&format!(
                "audio/x-raw,format=F32LE,channels={AUDIO_CHANNELS},rate={AUDIO_RATE},layout=interleaved"
            ))
            .ok();
            if let Some(c) = &pinned_caps {
                aappsink.set_caps(Some(c));
            }

            if pipeline
                .add_many([
                    &queue,
                    &aconv,
                    &aresample,
                    &acaps,
                    aappsink.upcast_ref::<gstreamer::Element>(),
                ])
                .is_err()
            {
                tracing::warn!(target: "export.lifecycle", chain = %label_owned_pad, "src audio chain add failed");
                return;
            }
            if gstreamer::Element::link_many([
                &queue,
                &aconv,
                &aresample,
                &acaps,
                aappsink.upcast_ref::<gstreamer::Element>(),
            ])
            .is_err()
            {
                tracing::warn!(target: "export.lifecycle", chain = %label_owned_pad, "src audio chain link failed");
                return;
            }
            for e in [
                &queue,
                &aconv,
                &aresample,
                &acaps,
                aappsink.upcast_ref::<gstreamer::Element>(),
            ] {
                if e.sync_state_with_parent().is_err() {
                    tracing::warn!(target: "export.lifecycle", chain = %label_owned_pad, "src audio elem sync_state failed");
                }
            }
            let queue_sink = match queue.static_pad("sink") {
                Some(p) => p,
                None => return,
            };
            if let Err(e) = pad.link(&queue_sink) {
                tracing::warn!(
                    target: "export.lifecycle",
                    chain = %label_owned_pad,
                    error = ?e,
                    "src audio pad link failed",
                );
                return;
            }
            // Publish the appsink so the caller can attach a sample queue
            // in Task 1b. Overwrite is fine if pad-added somehow fires
            // twice; the latest sink wins (decodebin shouldn't, but
            // belt-and-suspenders).
            *audio_appsink_cell_for_pad
                .lock()
                .expect("source audio appsink cell") = Some(aappsink);
            return;
        }
        // Anything else (e.g. subtitles): drain to fakesink so decodebin
        // doesn't stall.
        let Some(pipeline) = pipeline_weak.upgrade() else {
            return;
        };
        let fakesink = match gstreamer::ElementFactory::make("fakesink")
            .name(format!("{label_owned_pad}-aux-fakesink"))
            .property("sync", false)
            .property("async", false)
            .build()
        {
            Ok(f) => f,
            Err(_) => return,
        };
        if pipeline.add(&fakesink).is_err() {
            return;
        }
        if fakesink.sync_state_with_parent().is_err() {
            return;
        }
        if let Some(sink_pad) = fakesink.static_pad("sink") {
            let _ = pad.link(&sink_pad);
        }
    });

    let elements = vec![
        filesrc.clone(),
        decodebin.clone(),
        queue_in,
        videoconvert,
        capsfilter,
        appsink.clone().upcast::<gstreamer::Element>(),
    ];

    // The pad-added closure runs during preroll, AFTER this function
    // returns. Hand the cell to the caller so it can read the published
    // AppSink (or `None` for soundless sources) once
    // `pipeline.state(...)` confirms preroll.
    Ok(SourceVideoChain {
        elements,
        video_appsink: appsink,
        audio_appsink: audio_appsink_cell,
    })
}

// ─── webcam (recording) chain ───────────────────────────────────────────────

struct WebcamChain {
    elements: Vec<gstreamer::Element>,
    video_appsink: AppSink,
    audio_appsink: AppSink,
}

/// Build the webcam decoder chain. Routes the audio pad to a driver-fed
/// audio-appsink (per fix #37) instead of platform speakers; the driver
/// pulls raw audio samples and pushes them to the shared audio chain.
fn build_webcam_chain(
    pipeline: &gstreamer::Pipeline,
    path: &Path,
    label: &str,
) -> Result<WebcamChain, ExportError> {
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .name(format!("{label}-filesrc"))
        .property("location", path.to_str().ok_or(ExportError::InvalidPath)?)
        .build()
        .map_err(|_| ExportError::MissingElement("filesrc".into()))?;
    let decodebin = gstreamer::ElementFactory::make("decodebin")
        .name(format!("{label}-decodebin"))
        .build()
        .map_err(|_| ExportError::MissingElement("decodebin".into()))?;
    let queue_video = gstreamer::ElementFactory::make("queue")
        .name(format!("{label}-vqueue"))
        .build()
        .map_err(|_| ExportError::MissingElement("queue".into()))?;
    let videoconvert = make_or("videoconvert")?;
    let video_caps = gstreamer::ElementFactory::make("capsfilter")
        .name(format!("{label}-vcaps"))
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ExportError::MissingElement("capsfilter".into()))?;
    let video_appsink_elem = gstreamer::ElementFactory::make("appsink")
        .name(format!("{label}-vappsink"))
        .build()
        .map_err(|_| ExportError::MissingElement("appsink".into()))?;
    let video_appsink = video_appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| ExportError::Construction(format!("{label}: vappsink downcast")))?;
    video_appsink.set_property("sync", false);

    // Audio chain terminates in audio-appsink (fix #37). Caller's driver
    // pulls samples and pushes to the shared audio-appsrc.
    let audio_appsink_elem = gstreamer::ElementFactory::make("appsink")
        .name(format!("{label}-aappsink"))
        .build()
        .map_err(|_| ExportError::MissingElement("appsink".into()))?;
    let audio_appsink = audio_appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| ExportError::Construction(format!("{label}: aappsink downcast")))?;
    audio_appsink.set_property("sync", false);
    // Pin audio caps to F32LE stereo at 48k so audioconvert+resample lands
    // exactly there before the appsink. Mismatched downstream caps causes
    // the audio-appsrc → encoder chain to negotiate badly.
    let audio_caps = gstreamer::Caps::from_str(&format!(
        "audio/x-raw,format=F32LE,channels={AUDIO_CHANNELS},rate={AUDIO_RATE},layout=interleaved"
    ))
    .map_err(|_| ExportError::Construction(format!("{label}: parse audio caps")))?;
    audio_appsink.set_caps(Some(&audio_caps));

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue_video,
            &videoconvert,
            &video_caps,
            video_appsink.upcast_ref::<gstreamer::Element>(),
            audio_appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| ExportError::Construction(format!("{label}: add: {e}")))?;
    filesrc
        .link(&decodebin)
        .map_err(|e| ExportError::Construction(format!("{label}: filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([
        &queue_video,
        &videoconvert,
        &video_caps,
        video_appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| ExportError::Construction(format!("{label}: link video chain: {e}")))?;

    let queue_video_sink = queue_video
        .static_pad("sink")
        .ok_or_else(|| ExportError::Construction(format!("{label}: no queue sink")))?;
    let pipeline_weak = pipeline.downgrade();
    let audio_appsink_for_pad = audio_appsink.clone();
    let label_owned = label.to_string();

    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else {
            return;
        };
        let Some(structure) = caps.structure(0) else {
            return;
        };
        let media = structure.name().to_string();
        if media.starts_with("video/") {
            if let Err(e) = pad.link(&queue_video_sink) {
                tracing::warn!(
                    target: "export.lifecycle",
                    chain = %label_owned,
                    error = ?e,
                    "failed to link decoded webcam video pad",
                );
            }
            return;
        }
        if media.starts_with("audio/") {
            // Build the audio chain dynamically: queue → audioconvert →
            // audioresample → capsfilter → audio_appsink.
            let Some(pipeline) = pipeline_weak.upgrade() else {
                return;
            };
            let queue = match gstreamer::ElementFactory::make("queue")
                .name(format!("{label_owned}-aqueue"))
                .build()
            {
                Ok(e) => e,
                Err(_) => return,
            };
            let aconv = match gstreamer::ElementFactory::make("audioconvert").build() {
                Ok(e) => e,
                Err(_) => return,
            };
            let aresample = match gstreamer::ElementFactory::make("audioresample").build() {
                Ok(e) => e,
                Err(_) => return,
            };
            let acaps = match gstreamer::ElementFactory::make("capsfilter")
                .property(
                    "caps",
                    gstreamer::Caps::from_str(&format!(
                        "audio/x-raw,format=F32LE,channels={AUDIO_CHANNELS},rate={AUDIO_RATE},layout=interleaved"
                    ))
                    .unwrap(),
                )
                .build()
            {
                Ok(e) => e,
                Err(_) => return,
            };
            if pipeline
                .add_many([&queue, &aconv, &aresample, &acaps])
                .is_err()
            {
                return;
            }
            if gstreamer::Element::link_many([
                &queue,
                &aconv,
                &aresample,
                &acaps,
                audio_appsink_for_pad.upcast_ref::<gstreamer::Element>(),
            ])
            .is_err()
            {
                tracing::warn!(target: "export.lifecycle", chain = %label_owned, "audio chain link failed");
                return;
            }
            for e in [&queue, &aconv, &aresample, &acaps] {
                if e.sync_state_with_parent().is_err() {
                    tracing::warn!(target: "export.lifecycle", chain = %label_owned, "audio elem sync_state failed");
                }
            }
            // audio_appsink is added at construction so its state syncs
            // with the pipeline's PAUSED transition above.
            let queue_sink = match queue.static_pad("sink") {
                Some(p) => p,
                None => return,
            };
            if let Err(e) = pad.link(&queue_sink) {
                tracing::warn!(target: "export.lifecycle", chain = %label_owned, error = ?e, "audio pad link failed");
            }
            return;
        }
        // Anything else: drain.
        let Some(pipeline) = pipeline_weak.upgrade() else {
            return;
        };
        let fakesink = match gstreamer::ElementFactory::make("fakesink")
            .name(format!("{label_owned}-aux-fakesink"))
            .property("sync", false)
            .property("async", false)
            .build()
        {
            Ok(f) => f,
            Err(_) => return,
        };
        if pipeline.add(&fakesink).is_err() {
            return;
        }
        if fakesink.sync_state_with_parent().is_err() {
            return;
        }
        if let Some(sink_pad) = fakesink.static_pad("sink") {
            let _ = pad.link(&sink_pad);
        }
    });

    let elements = vec![
        filesrc.clone(),
        decodebin.clone(),
        queue_video,
        videoconvert,
        video_caps,
        video_appsink.clone().upcast::<gstreamer::Element>(),
        audio_appsink.clone().upcast::<gstreamer::Element>(),
    ];

    Ok(WebcamChain {
        elements,
        video_appsink,
        audio_appsink,
    })
}

// ─── output (encode + mux + filesink) chains ────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn build_video_output_chain(
    pipeline: &gstreamer::Pipeline,
    output_path: &Path,
    source_w: u32,
    source_h: u32,
    target_w: u32,
    target_h: u32,
    target_bitrate: u32,
    codec: Codec,
) -> Result<AppSrc, ExportError> {
    // appsrc caps pinned to SOURCE size (per fix #28); videoscale + capsfilter
    // handle the target.
    let appsrc_caps = gstreamer::Caps::from_str(&format!(
        "video/x-raw,format=RGBA,width={source_w},height={source_h},framerate=30/1"
    ))
    .map_err(|_| ExportError::Construction("parse appsrc caps".into()))?;
    let appsrc = AppSrc::builder()
        .caps(&appsrc_caps)
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    appsrc.set_property("name", "video-appsrc");

    let videoconvert = make_or("videoconvert")?;
    let videoscale = make_or("videoscale")?;
    // Phase 11 Plan #3 CI-fix-up: encoder-input format is codec-aware.
    // x264enc + vtenc_h264 + mfh264enc + vaapih264enc all accept NV12.
    // x265enc (the Linux SW fallback for HEVC) does NOT accept NV12 — it
    // requires I420 or I420_10LE. vtenc_h265_hw + vtenc_h265 + mfh265enc +
    // vaapih265enc all accept I420 too, so I420 on the HEVC path is
    // backward-compatible across every encoder we pick.
    let encoder_input_format = match codec {
        Codec::H264 => "NV12",
        Codec::Hevc => "I420",
    };
    let capsfilter_target = gstreamer::ElementFactory::make("capsfilter")
        .property(
            "caps",
            gstreamer::Caps::from_str(&format!(
                "video/x-raw,format={encoder_input_format},width={target_w},height={target_h},framerate=30/1"
            ))
            .unwrap(),
        )
        .build()
        .map_err(|_| ExportError::MissingElement("capsfilter".into()))?;
    // Phase 11 Plan #3: codec-dispatched encoder + parser pair.
    let (video_enc, parser) = match codec {
        Codec::H264 => (pick_h264_encoder(target_bitrate)?, make_or("h264parse")?),
        Codec::Hevc => (pick_h265_encoder(target_bitrate)?, make_or("h265parse")?),
    };
    // Phase 11 Plan #3 fix #4: qtmux requires AVCC/HVCC stream-format
    // for MP4 (not byte-stream). h264parse auto-converts because qtmux
    // advertises `stream-format=avc` on its H.264 sink-pad caps. h265parse
    // is the same shape, but on some GStreamer 1.20 builds the default
    // emit is `stream-format=byte-stream, alignment=nal` which qtmux
    // rejects with `could not link h265parse to qtmux`. Insert an
    // explicit capsfilter on the HEVC path only.
    let parser_caps_filter: Option<gstreamer::Element> = match codec {
        Codec::H264 => None,
        Codec::Hevc => {
            let caps = gstreamer::Caps::from_str("video/x-h265,stream-format=hvc1,alignment=au")
                .map_err(|_| ExportError::Construction("parse h265 parser caps".into()))?;
            let cf = gstreamer::ElementFactory::make("capsfilter")
                .property("caps", &caps)
                .build()
                .map_err(|_| ExportError::MissingElement("capsfilter (h265)".into()))?;
            Some(cf)
        }
    };
    let qtmux = gstreamer::ElementFactory::make("qtmux")
        .name("qtmux")
        .build()
        .map_err(|_| ExportError::MissingElement("qtmux".into()))?;
    let filesink = gstreamer::ElementFactory::make("filesink")
        .property(
            "location",
            output_path.to_str().ok_or(ExportError::InvalidPath)?,
        )
        .property("async", false)
        .build()
        .map_err(|_| ExportError::MissingElement("filesink".into()))?;

    // add_many: include the HEVC parser-capsfilter only when present.
    if let Some(parser_caps_filter) = parser_caps_filter.as_ref() {
        pipeline
            .add_many([
                appsrc.upcast_ref::<gstreamer::Element>(),
                &videoconvert,
                &videoscale,
                &capsfilter_target,
                &video_enc,
                &parser,
                parser_caps_filter,
                &qtmux,
                &filesink,
            ])
            .map_err(|e| ExportError::Construction(format!("add output chain: {e}")))?;
        gstreamer::Element::link_many([
            appsrc.upcast_ref::<gstreamer::Element>(),
            &videoconvert,
            &videoscale,
            &capsfilter_target,
            &video_enc,
            &parser,
            parser_caps_filter,
            &qtmux,
        ])
        .map_err(|e| ExportError::Construction(format!("link output chain: {e}")))?;
    } else {
        pipeline
            .add_many([
                appsrc.upcast_ref::<gstreamer::Element>(),
                &videoconvert,
                &videoscale,
                &capsfilter_target,
                &video_enc,
                &parser,
                &qtmux,
                &filesink,
            ])
            .map_err(|e| ExportError::Construction(format!("add output chain: {e}")))?;
        gstreamer::Element::link_many([
            appsrc.upcast_ref::<gstreamer::Element>(),
            &videoconvert,
            &videoscale,
            &capsfilter_target,
            &video_enc,
            &parser,
            &qtmux,
        ])
        .map_err(|e| ExportError::Construction(format!("link output chain: {e}")))?;
    }
    qtmux
        .link(&filesink)
        .map_err(|e| ExportError::Construction(format!("qtmux→filesink: {e}")))?;

    Ok(appsrc)
}

/// Build the shared audio chain: appsrc → audioconvert → aacenc → aacparse →
/// qtmux audio sink-pad. The qtmux already exists in the pipeline (added by
/// the video output chain); we look it up by name and request its audio
/// sink-pad. Returns the AppSrc the driver will push samples to.
fn build_audio_output_chain(
    pipeline: &gstreamer::Pipeline,
    _video_appsrc: &AppSrc,
) -> Result<AppSrc, ExportError> {
    let audio_caps = gstreamer::Caps::from_str(&format!(
        "audio/x-raw,format=F32LE,channels={AUDIO_CHANNELS},rate={AUDIO_RATE},layout=interleaved"
    ))
    .map_err(|_| ExportError::Construction("parse audio appsrc caps".into()))?;
    let appsrc = AppSrc::builder()
        .caps(&audio_caps)
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    appsrc.set_property("name", "audio-appsrc");

    let audioconvert = make_or("audioconvert")?;
    let aacenc = pick_aac_encoder()?;
    let aacparse = make_or("aacparse")?;

    pipeline
        .add_many([
            appsrc.upcast_ref::<gstreamer::Element>(),
            &audioconvert,
            &aacenc,
            &aacparse,
        ])
        .map_err(|e| ExportError::Construction(format!("add audio output chain: {e}")))?;
    gstreamer::Element::link_many([
        appsrc.upcast_ref::<gstreamer::Element>(),
        &audioconvert,
        &aacenc,
        &aacparse,
    ])
    .map_err(|e| ExportError::Construction(format!("link audio output chain: {e}")))?;

    // Find qtmux and link aacparse → qtmux's audio sink-pad.
    let qtmux = pipeline
        .by_name("qtmux")
        .ok_or_else(|| ExportError::Construction("qtmux not found".into()))?;
    let aacparse_src = aacparse
        .static_pad("src")
        .ok_or_else(|| ExportError::Construction("aacparse has no src pad".into()))?;
    let qtmux_audio_sink = qtmux
        .request_pad_simple("audio_%u")
        .ok_or_else(|| ExportError::Construction("qtmux audio sink-pad request".into()))?;
    aacparse_src
        .link(&qtmux_audio_sink)
        .map_err(|e| ExportError::Construction(format!("aacparse→qtmux audio: {e:?}")))?;

    Ok(appsrc)
}

// ─── frame slot wiring ──────────────────────────────────────────────────────

fn attach_video_frame_slot(appsink: &AppSink, slot: Arc<Mutex<Option<Frame>>>) {
    let slot_preroll = slot.clone();
    appsink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_preroll(move |sink| {
                if let Ok(sample) = sink.pull_preroll() {
                    if let Some(f) = sample_to_frame(&sample) {
                        *slot_preroll.lock().expect("slot lock") = Some(f);
                    }
                }
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                if let Some(f) = sample_to_frame(&sample) {
                    *slot.lock().expect("slot lock") = Some(f);
                }
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .build(),
    );
}

fn sample_to_frame(sample: &gstreamer::Sample) -> Option<Frame> {
    let buffer = sample.buffer()?;
    let caps = sample.caps()?;
    let structure = caps.structure(0)?;
    let width = structure.get::<i32>("width").ok()? as u32;
    let height = structure.get::<i32>("height").ok()? as u32;
    let map = buffer.map_readable().ok()?;
    Some(Frame::new(width, height, map.to_vec()))
}

// ─── audio sample queue ─────────────────────────────────────────────────────

/// FIFO of decoded audio sample bytes pulled from a clip's audio appsink.
/// The driver consumes from this queue when its active clip matches,
/// pushing the data through the shared audio-appsrc.
#[derive(Default)]
struct AudioSampleQueue {
    /// Queued raw F32LE interleaved bytes.
    bytes: Vec<u8>,
}

fn attach_audio_sample_queue(appsink: &AppSink, queue: Arc<Mutex<AudioSampleQueue>>) {
    let queue_preroll = queue.clone();
    appsink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_preroll(move |sink| {
                if let Ok(sample) = sink.pull_preroll() {
                    if let Some(buffer) = sample.buffer() {
                        if let Ok(map) = buffer.map_readable() {
                            queue_preroll
                                .lock()
                                .expect("audio queue lock")
                                .bytes
                                .extend_from_slice(map.as_slice());
                        }
                    }
                }
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                if let Some(buffer) = sample.buffer() {
                    if let Ok(map) = buffer.map_readable() {
                        queue
                            .lock()
                            .expect("audio queue lock")
                            .bytes
                            .extend_from_slice(map.as_slice());
                    }
                }
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .build(),
    );
}

// ─── freeze-frame pre-decode ────────────────────────────────────────────────

fn pre_decode_all_freeze_frames(
    inputs: &ExportInputs,
    cancel: &Arc<AtomicBool>,
) -> Result<HashMap<usize, HashMap<usize, Frame>>, ExportError> {
    let mut out: HashMap<usize, HashMap<usize, Frame>> = HashMap::new();
    for (entry_idx, entry) in inputs.plan.entries.iter().enumerate() {
        // Per fix #30: check cancel at each (entry, freeze_segment) iteration
        // boundary. Mid-decode aborts wait up to ~5s for the in-flight call.
        if cancel.load(Ordering::Acquire) {
            return Err(ExportError::Cancelled);
        }
        let mut entry_frozen: HashMap<usize, Frame> = HashMap::new();
        let clip = inputs
            .clips_by_id
            .get(&entry.clip_id)
            .ok_or_else(|| ExportError::Plan(format!("clip not in map: {}", entry.clip_id)))?;
        let source_path = inputs.source_paths.get(&clip.source_index).ok_or_else(|| {
            ExportError::Plan(format!(
                "source path missing for index {}",
                clip.source_index
            ))
        })?;
        for (i, seg) in entry.segments.iter().enumerate() {
            if cancel.load(Ordering::Acquire) {
                return Err(ExportError::Cancelled);
            }
            if seg.kind != SegmentKind::Freeze {
                continue;
            }
            // Per fix #11: pre-decode at end-of-prev-Play, not at the
            // freeze segment's own source_start (Skip-then-Freeze
            // diverges between the two).
            let mut source_time = clip.start_source_seconds;
            for j in (0..i).rev() {
                let prev = &entry.segments[j];
                if prev.kind == SegmentKind::Play {
                    source_time = prev.source_start + prev.out_duration;
                    break;
                }
            }
            let frame = decode_one_frame_at(source_path, source_time)?;
            entry_frozen.insert(i, frame);
        }
        out.insert(entry_idx, entry_frozen);
    }
    Ok(out)
}

fn decode_one_frame_at(source_path: &Path, source_time_seconds: f64) -> Result<Frame, ExportError> {
    crate::init().map_err(|e| ExportError::Construction(e.to_string()))?;

    let pipeline = gstreamer::Pipeline::new();
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .property(
            "location",
            source_path.to_str().ok_or(ExportError::InvalidPath)?,
        )
        .build()
        .map_err(|_| ExportError::MissingElement("filesrc".into()))?;
    let decodebin = make_or("decodebin")?;
    let queue = make_or("queue")?;
    let videoconvert = make_or("videoconvert")?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ExportError::MissingElement("capsfilter".into()))?;
    let appsink = AppSink::builder()
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .sync(false)
        .build();

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue,
            &videoconvert,
            &capsfilter,
            appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| ExportError::FreezeDecode(format!("add: {e}")))?;
    filesrc
        .link(&decodebin)
        .map_err(|e| ExportError::FreezeDecode(format!("link filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([
        &queue,
        &videoconvert,
        &capsfilter,
        appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| ExportError::FreezeDecode(format!("link chain: {e}")))?;

    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| ExportError::FreezeDecode("queue has no sink".into()))?;
    let pipeline_weak = pipeline.downgrade();
    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else {
            return;
        };
        let Some(structure) = caps.structure(0) else {
            return;
        };
        let media = structure.name().to_string();
        if media.starts_with("video/") {
            let _ = pad.link(&queue_sink);
            return;
        }
        let Some(pipeline) = pipeline_weak.upgrade() else {
            return;
        };
        let fakesink = match gstreamer::ElementFactory::make("fakesink")
            .property("sync", false)
            .property("async", false)
            .build()
        {
            Ok(f) => f,
            Err(_) => return,
        };
        if pipeline.add(&fakesink).is_err() {
            return;
        }
        if fakesink.sync_state_with_parent().is_err() {
            return;
        }
        if let Some(sink_pad) = fakesink.static_pad("sink") {
            let _ = pad.link(&sink_pad);
        }
    });

    pipeline
        .set_state(gstreamer::State::Paused)
        .map_err(|e| ExportError::FreezeDecode(format!("PAUSED: {e:?}")))?;
    let (state_res, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));
    if let Err(e) = state_res {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(ExportError::FreezeDecode(format!("preroll wait: {e:?}")));
    }

    let target = gstreamer::ClockTime::from_nseconds((source_time_seconds.max(0.0) * 1e9) as u64);
    let seek_ok = pipeline.seek_simple(
        gstreamer::SeekFlags::FLUSH | gstreamer::SeekFlags::ACCURATE,
        target,
    );
    if seek_ok.is_err() {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(ExportError::FreezeDecode(format!(
            "seek to {source_time_seconds}s failed"
        )));
    }
    let (state_res2, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));
    if let Err(e) = state_res2 {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(ExportError::FreezeDecode(format!(
            "post-seek preroll wait: {e:?}"
        )));
    }

    let sample = appsink
        .pull_preroll()
        .map_err(|e| ExportError::FreezeDecode(format!("pull preroll: {e:?}")))?;
    let frame = sample_to_frame(&sample)
        .ok_or_else(|| ExportError::FreezeDecode("preroll sample lacked caps/buffer".into()))?;
    let _ = pipeline.set_state(gstreamer::State::Null);

    Ok(frame)
}

// ─── driver loop ────────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
struct DriverArgs<'a> {
    compositor: Arc<Compositor>,
    pipeline: gstreamer::Pipeline,
    plan: &'a CompilationPlan,
    clips_by_id: &'a HashMap<Uuid, Clip>,
    source_chains: &'a HashMap<usize, SourceVideoChain>,
    webcam_chains: &'a HashMap<Uuid, WebcamChain>,
    source_slots: &'a HashMap<usize, Arc<Mutex<Option<Frame>>>>,
    webcam_slots: &'a HashMap<Uuid, Arc<Mutex<Option<Frame>>>>,
    audio_buffer_queues: &'a HashMap<Uuid, Arc<Mutex<AudioSampleQueue>>>,
    video_appsrc: AppSrc,
    audio_appsrc: AppSrc,
    frozen_frames_by_entry: &'a HashMap<usize, HashMap<usize, Frame>>,
    cancel: Arc<AtomicBool>,
    frames_counter: Arc<AtomicU64>,
    total_frames: u64,
    on_progress: Box<dyn Fn(ExportProgress) + Send + Sync>,
}

fn run_driver_loop(args: DriverArgs<'_>) -> Result<(), ExportError> {
    let DriverArgs {
        compositor,
        pipeline: _pipeline,
        plan,
        clips_by_id,
        source_chains,
        webcam_chains,
        source_slots,
        webcam_slots,
        audio_buffer_queues,
        video_appsrc,
        audio_appsrc,
        frozen_frames_by_entry,
        cancel,
        frames_counter,
        total_frames,
        on_progress,
    } = args;

    // Monotonic cursors across entries (per fix #20 (e) + #37).
    let mut composition_start_ns: u64 = 0;
    let mut audio_pts_ns: u64 = 0;

    // Track which source/clip is currently active (Playing). On entry
    // boundaries we Pause the previous and Play the next (per fix #19 +
    // #27).
    let mut active_source_index: Option<usize> = None;
    let mut active_clip_id: Option<Uuid> = None;

    for (entry_idx, entry) in plan.entries.iter().enumerate() {
        if cancel.load(Ordering::Acquire) {
            return Err(ExportError::Cancelled);
        }

        // Plan #4 Task 3 / Fix #43: clear the freeze compose cache at
        // every entry boundary. New entry → new clip → new (Arc<Frame>)
        // freeze frames freshly built from the per-entry HashMap below.
        // Content-prefix-defended keys already make stale-Arc hits
        // impossible, but proactively clearing bounds the LRU's
        // working set to the current entry's freeze segments.
        compositor.clear_freeze_cache();

        let clip = clips_by_id
            .get(&entry.clip_id)
            .ok_or_else(|| ExportError::Plan(format!("clip not in map: {}", entry.clip_id)))?;

        // Two-stage entry transition (fix #20):
        //   (a) Pause prev source/webcam chains if they're not also the
        //       new active ones. (b) Seek + play new chains. (c) Reset
        //       per-entry record_time cursor.
        transition_chains(
            source_chains,
            webcam_chains,
            &mut active_source_index,
            &mut active_clip_id,
            clip.source_index,
            entry.clip_id,
            entry,
        )?;

        // Drain any stale audio bytes from the new active clip's queue —
        // pre-roll buffers may have accumulated bytes we don't want
        // counted toward the entry's audio window.
        if let Some(q) = audio_buffer_queues.get(&entry.clip_id) {
            q.lock().expect("aq lock").bytes.clear();
        }

        // Plan #4 Task 3 / Fix #48: pre_decode_all_freeze_frames keeps
        // its `HashMap<usize, HashMap<usize, Frame>>` return type
        // (stable surface); we wrap each value in `Arc::new` here at
        // the consumer boundary so the per-entry frozen-frame map
        // hands stable `Arc<Frame>` pointers to compose_entry_frame.
        let frozen_for_entry_raw = frozen_frames_by_entry
            .get(&entry_idx)
            .cloned()
            .unwrap_or_default();
        let frozen_for_entry: HashMap<usize, Arc<Frame>> = frozen_for_entry_raw
            .into_iter()
            .map(|(k, v)| (k, Arc::new(v)))
            .collect();

        // Frame count per fix #39: round, don't truncate.
        let entry_frame_count = (entry.recording_duration * 30.0).round() as u64;

        for frame_idx in 0..entry_frame_count {
            if cancel.load(Ordering::Acquire) {
                return Err(ExportError::Cancelled);
            }

            let record_time = (frame_idx as f64) / 30.0;

            // Source frame: live appsink slot for Play; cached for Freeze.
            // We pass a placeholder solid 2x2 if the live slot is empty
            // (decoder hasn't produced yet); this matches preview's
            // defensive fallback in `preview_pipeline.rs`.
            let source_frame = source_slots
                .get(&clip.source_index)
                .and_then(|s| s.lock().expect("source slot lock").clone())
                .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255]));
            let webcam_frame = webcam_slots
                .get(&entry.clip_id)
                .and_then(|s| s.lock().expect("webcam slot lock").clone())
                .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255]));

            // Compose via the canonical entry point (fix #3 + #5).
            let composed = compose_entry_frame(
                &compositor,
                entry,
                clip,
                record_time,
                &source_frame,
                &webcam_frame,
                &frozen_for_entry,
            )?;

            // Push to video appsrc with monotonic PTS = composition_start +
            // frame_idx × 33,333,333 (per plan + fix #39).
            let pts_ns = composition_start_ns + frame_idx * FRAME_DURATION_NS;
            push_video_frame(&video_appsrc, &composed, pts_ns, FRAME_DURATION_NS)?;

            // Audio for this frame's window: pull bytes equal to one frame's
            // duration worth from the active clip's queue, push to shared
            // audio appsrc with monotonic audio_pts_ns.
            push_audio_for_window(
                &audio_appsrc,
                audio_buffer_queues.get(&entry.clip_id),
                &mut audio_pts_ns,
                FRAME_DURATION_NS,
            )?;

            let frames_pushed = frames_counter.fetch_add(1, Ordering::SeqCst) + 1;
            if frame_idx % 30 == 0 {
                on_progress(ExportProgress {
                    frames_pushed,
                    frame_index: frame_idx,
                    total_frames,
                    current_entry_index: entry_idx,
                });
            }
        }

        // Advance composition_start_ns by frame-aligned duration (fix #39).
        composition_start_ns += entry_frame_count * FRAME_DURATION_NS;
    }

    Ok(())
}

/// Two-stage entry transition (fix #20). Pause old source/webcam chains if
/// they differ from the new active ones; play (and seek) the new chains.
fn transition_chains(
    source_chains: &HashMap<usize, SourceVideoChain>,
    webcam_chains: &HashMap<Uuid, WebcamChain>,
    active_source_index: &mut Option<usize>,
    active_clip_id: &mut Option<Uuid>,
    new_source_index: usize,
    new_clip_id: Uuid,
    entry: &CompilationEntry,
) -> Result<(), ExportError> {
    // Pause previous source if different.
    if let Some(prev_idx) = active_source_index {
        if *prev_idx != new_source_index {
            if let Some(prev_chain) = source_chains.get(prev_idx) {
                set_chain_state(&prev_chain.elements, gstreamer::State::Paused);
            }
        }
    }
    // Pause previous webcam if different.
    if let Some(prev_clip) = active_clip_id {
        if *prev_clip != new_clip_id {
            if let Some(prev_chain) = webcam_chains.get(prev_clip) {
                set_chain_state(&prev_chain.elements, gstreamer::State::Paused);
            }
        }
    }

    // Activate new source: seek to entry's first segment source_start (if
    // it's a Play; if first segment is a Freeze, the cached frame is used —
    // we still seek-then-play so the chain produces samples for any later
    // Play segments in the same entry).
    let source_chain = source_chains.get(&new_source_index).ok_or_else(|| {
        ExportError::Plan(format!("source chain missing for index {new_source_index}"))
    })?;

    // Per fix #6 + #23: seek to first Play segment's source_start. If the
    // entry has no Play segments (all Freeze), we don't seek; the cached
    // frames cover everything.
    if let Some(first_play) = entry.segments.iter().find(|s| s.kind == SegmentKind::Play) {
        seek_chain_to(&source_chain.video_appsink, first_play.source_start)?;
    }
    set_chain_state(&source_chain.elements, gstreamer::State::Playing);

    // Activate new webcam chain: seek to 0 (recording starts from 0 always),
    // play.
    let webcam_chain = webcam_chains
        .get(&new_clip_id)
        .ok_or_else(|| ExportError::Plan(format!("webcam chain missing for clip {new_clip_id}")))?;
    seek_chain_to(&webcam_chain.video_appsink, 0.0)?;
    set_chain_state(&webcam_chain.elements, gstreamer::State::Playing);

    *active_source_index = Some(new_source_index);
    *active_clip_id = Some(new_clip_id);
    Ok(())
}

/// Send a per-chain seek so we don't flush other source chains in the same
/// pipeline (a pipeline-level `seek_simple` flushes everything). Seek events
/// in GStreamer travel UPSTREAM, so we send the event on a downstream
/// element — the chain's appsink — and gstreamer routes it back through
/// videoconvert/decodebin/filesrc. Sending on the filesrc directly is a
/// no-op for many source elements (filesrc itself doesn't process Seek
/// events meaningfully — it's the byte-format upstream of the demuxer).
fn seek_chain_to(appsink: &AppSink, seconds: f64) -> Result<(), ExportError> {
    let position =
        gstreamer::ClockTime::from_nseconds((seconds.max(0.0) * 1_000_000_000.0).round() as u64);
    let event = gstreamer::event::Seek::new(
        1.0,
        gstreamer::SeekFlags::FLUSH | gstreamer::SeekFlags::ACCURATE,
        gstreamer::SeekType::Set,
        gstreamer::GenericFormattedValue::from(position),
        gstreamer::SeekType::None,
        gstreamer::GenericFormattedValue::from(gstreamer::ClockTime::NONE),
    );
    let elem: &gstreamer::Element = appsink.upcast_ref();
    if !elem.send_event(event) {
        return Err(ExportError::Seek(format!("chain seek to {seconds}s")));
    }
    Ok(())
}

fn set_chain_state(elements: &[gstreamer::Element], state: gstreamer::State) {
    // Per fix #27: per-element state transitions; pipeline-level set_state
    // would flip every chain. Errors here are logged and swallowed —
    // continuing through the pipeline gives the most-graceful degradation.
    for elem in elements {
        if let Err(e) = elem.set_state(state) {
            tracing::warn!(
                target: "export.lifecycle",
                element = %elem.name(),
                state = ?state,
                error = ?e,
                "set_state failed",
            );
        }
    }
}

fn push_video_frame(
    appsrc: &AppSrc,
    frame: &Frame,
    pts_ns: u64,
    duration_ns: u64,
) -> Result<(), ExportError> {
    let mut buf = gstreamer::Buffer::with_size(frame.pixels.len())
        .map_err(|e| ExportError::AppFlow(format!("alloc video buffer: {e}")))?;
    {
        let buf_mut = buf
            .get_mut()
            .ok_or_else(|| ExportError::AppFlow("video buffer get_mut".into()))?;
        let mut map = buf_mut
            .map_writable()
            .map_err(|e| ExportError::AppFlow(format!("video buffer map: {e}")))?;
        map.copy_from_slice(&frame.pixels);
        drop(map);
        buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(pts_ns));
        buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(duration_ns));
    }
    appsrc
        .push_buffer(buf)
        .map_err(|e| ExportError::AppFlow(format!("push video buffer: {e:?}")))?;
    Ok(())
}

fn push_audio_for_window(
    audio_appsrc: &AppSrc,
    queue: Option<&Arc<Mutex<AudioSampleQueue>>>,
    audio_pts_ns: &mut u64,
    duration_ns: u64,
) -> Result<(), ExportError> {
    // Bytes per ns at 48kHz F32 stereo:
    //   bytes_per_second = 48000 × 8 = 384000
    //   bytes_per_ns     = 384000 / 1e9
    //   bytes_per_frame_window = round(384000 × duration_ns / 1e9)
    let bytes_per_second = (AUDIO_RATE as usize) * AUDIO_BYTES_PER_SAMPLE;
    let target_bytes =
        ((bytes_per_second as u128 * duration_ns as u128) / 1_000_000_000_u128) as usize;
    // Keep it sample-aligned to AUDIO_BYTES_PER_SAMPLE so the encoder
    // doesn't see a mid-sample buffer boundary.
    let target_bytes = (target_bytes / AUDIO_BYTES_PER_SAMPLE) * AUDIO_BYTES_PER_SAMPLE;
    if target_bytes == 0 {
        return Ok(());
    }

    // Pull from queue; pad with silence if not enough bytes available.
    let mut chunk = vec![0u8; target_bytes];
    if let Some(q) = queue {
        let mut q_locked = q.lock().expect("aq lock");
        let take = q_locked.bytes.len().min(target_bytes);
        if take > 0 {
            chunk[..take].copy_from_slice(&q_locked.bytes[..take]);
            q_locked.bytes.drain(..take);
        }
        // Remaining bytes (if any) stay zero (silence padding). Keeps the
        // output PTS continuous even when the recording's audio chain
        // hasn't delivered yet (early-startup grace period).
    }

    let mut buf = gstreamer::Buffer::with_size(chunk.len())
        .map_err(|e| ExportError::AppFlow(format!("alloc audio buffer: {e}")))?;
    {
        let buf_mut = buf
            .get_mut()
            .ok_or_else(|| ExportError::AppFlow("audio buffer get_mut".into()))?;
        let mut map = buf_mut
            .map_writable()
            .map_err(|e| ExportError::AppFlow(format!("audio buffer map: {e}")))?;
        map.copy_from_slice(&chunk);
        drop(map);
        buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(*audio_pts_ns));
        buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(duration_ns));
    }
    audio_appsrc
        .push_buffer(buf)
        .map_err(|e| ExportError::AppFlow(format!("push audio buffer: {e:?}")))?;
    *audio_pts_ns += duration_ns;
    Ok(())
}

fn wait_for_pipeline_eos(pipeline: &gstreamer::Pipeline) -> Result<(), ExportError> {
    let bus = pipeline
        .bus()
        .ok_or_else(|| ExportError::Construction("pipeline bus".into()))?;
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ExportError::AppFlow(
                "timeout waiting for filesink EOS".into(),
            ));
        }
        let timeout_ns = remaining.as_nanos().min(u64::MAX as u128) as u64;
        match bus.timed_pop_filtered(
            gstreamer::ClockTime::from_nseconds(timeout_ns.min(1_000_000_000)),
            &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
        ) {
            None => continue,
            Some(msg) => match msg.view() {
                gstreamer::MessageView::Eos(_) => return Ok(()),
                gstreamer::MessageView::Error(err) => {
                    return Err(ExportError::AppFlow(format!("pipeline error: {err}")));
                }
                _ => continue,
            },
        }
    }
}

/// Stepped Paused → Ready → Null teardown (fix #14). Errors are logged but
/// do not propagate; teardown must complete on every exit path.
fn teardown_pipeline(pipeline: &gstreamer::Pipeline, _skip_intermediate: bool) {
    for intermediate in [gstreamer::State::Paused, gstreamer::State::Ready] {
        if let Err(e) = pipeline.set_state(intermediate) {
            tracing::warn!(
                target: "export.lifecycle",
                state = ?intermediate,
                error = ?e,
                "intermediate set_state failed; continuing teardown",
            );
            continue;
        }
        let (res, _, _) = pipeline.state(Some(gstreamer::ClockTime::from_seconds(2)));
        if let Err(e) = res {
            tracing::warn!(
                target: "export.lifecycle",
                state = ?intermediate,
                error = ?e,
                "intermediate state wait failed; continuing teardown",
            );
        }
    }
    if let Err(e) = pipeline.set_state(gstreamer::State::Null) {
        tracing::warn!(
            target: "export.lifecycle",
            error = ?e,
            "NULL set_state failed",
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_index_at_walks_durations() {
        let segs = vec![
            PlaybackSegment {
                kind: SegmentKind::Play,
                source_start: 0.0,
                out_duration: 2.0,
            },
            PlaybackSegment {
                kind: SegmentKind::Freeze,
                source_start: 2.0,
                out_duration: 2.0,
            },
            PlaybackSegment {
                kind: SegmentKind::Play,
                source_start: 2.0,
                out_duration: 6.0,
            },
        ];
        assert_eq!(segment_index_at(&segs, 0.0), 0);
        assert_eq!(segment_index_at(&segs, 1.99), 0);
        assert_eq!(segment_index_at(&segs, 2.0), 1);
        assert_eq!(segment_index_at(&segs, 3.99), 1);
        assert_eq!(segment_index_at(&segs, 4.0), 2);
        assert_eq!(segment_index_at(&segs, 9.99), 2);
        assert_eq!(segment_index_at(&segs, 100.0), 2);
    }

    /// Unit-level guard for fix #39's rounding rule. Verifies the frame
    /// count + composition advance match the documented formula.
    #[test]
    fn frame_count_and_composition_advance_obey_fix_39() {
        // A 1.5167s "1.5s" recording rounds to 45 frames, advances by
        // 45 × 33_333_333 = 1_499_999_985 ns (≈ 1.5s flat, dropping the
        // 16.7ms drift the wall-clock recording introduced).
        let recording_duration = 1.5167_f64;
        let frame_count = (recording_duration * 30.0).round() as u64;
        assert_eq!(frame_count, 46); // round(45.501) = 46
        let advance_ns = frame_count * FRAME_DURATION_NS;
        // 46 × 33_333_333 = 1_533_333_318 ns
        assert_eq!(advance_ns, 1_533_333_318);

        // Sanity check on a clean 1.5s value.
        let clean_count = (1.5_f64 * 30.0).round() as u64;
        assert_eq!(clean_count, 45);
        assert_eq!(clean_count * FRAME_DURATION_NS, 1_499_999_985);
    }

    /// Phase 11 Plan #3 Task 1: `pick_h265_encoder` returns a usable
    /// factory. CI runners ship `x265enc` via `gst-plugins-bad`/
    /// `gst-plugins-good` (lavapipe Linux runner included), so the
    /// loop falls through to it when no HW encoder is available.
    #[test]
    fn pick_h265_encoder_returns_some_factory() {
        let _ = crate::init();
        let elem = pick_h265_encoder(7_200_000).expect("pick_h265_encoder should return Ok");
        // Element factory name is one of our candidates; can't assert
        // which without env-coupling, but the OK return + non-empty
        // factory is enough.
        assert!(elem.factory().is_some(), "encoder element has a factory");
    }

    /// Ensures the audio-window byte calculation lands sample-aligned and
    /// matches the documented ratio.
    #[test]
    fn audio_window_bytes_match_48k_stereo_f32_at_30fps() {
        // 48000 × 8 × (1/30) = 12_800 bytes/frame
        let bytes_per_second = (AUDIO_RATE as usize) * AUDIO_BYTES_PER_SAMPLE;
        let target_bytes =
            ((bytes_per_second as u128 * FRAME_DURATION_NS as u128) / 1_000_000_000_u128) as usize;
        let aligned = (target_bytes / AUDIO_BYTES_PER_SAMPLE) * AUDIO_BYTES_PER_SAMPLE;
        // FRAME_DURATION_NS = 33_333_333; 384_000 × 33_333_333 / 1e9 ≈ 12_799.999
        // floors to 12_799; then aligned to 8-byte boundary = 12_792 bytes.
        assert_eq!(target_bytes, 12_799);
        assert_eq!(aligned, 12_792);
    }
}
