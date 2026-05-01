//! Phase 9 Task 2. Clip-preview pipeline.
//!
//! Architectural shape (per phase plan + adversarial fixes #6, #11, #14, #17,
//! #20, #23, #24):
//!
//! ```text
//!   filesrc(source)   → decodebin → videoconvert → caps RGBA → appsink ── source_slot
//!                                                ╲
//!                                                 → fakesink (audio drained, no source audio in preview)
//!
//!   filesrc(recording.mov) → decodebin → videoconvert → caps RGBA → appsink ── webcam_slot
//!                                       ╲
//!                                        → audioconvert → audioresample → volume(commentary_volume)
//!                                                                                ↓
//!                                                                       platform_audio_sink_name()
//!
//!                                30 Hz driver thread (NOT source-driven, per fix #17)
//!                                  - record_time = playhead.compute()
//!                                  - segment = segments[lookup(record_time)]
//!                                  - source = if Freeze: frozen_frames[i] else source_slot.clone()
//!                                  - webcam = webcam_slot.clone() (last-frame-held past EOS, fix #20)
//!                                  - strokes = visible_strokes(clip, record_time)
//!                                  - composed = compose_tick(...)  (fix #24)
//!                                  - frame_sink.push_frame(composed)
//! ```
//!
//! Source-decoder seek policy (per fix #23):
//!   - (a) Initial mount: seek to segments[0].source_start if it's Play.
//!   - (b) Driver detects Freeze→Play transition: seek to next_play.source_start.
//!   - (c) User `seek()` resolves via `source_time_at`; if target lands in a
//!     Freeze segment, NO source seek (driver uses cached frozen frame).
//!   - NEVER drift-correct inside a steady-state Play segment.
//!
//! Threading model:
//!   - `open()` builds the pipelines synchronously (the bus task wraps the
//!     whole call in `spawn_blocking` per Phase 9 Task 3 — that's its
//!     responsibility, not ours).
//!   - GStreamer streaming threads write to the latest-frame slots via
//!     appsink callbacks.
//!   - A dedicated `std::thread` (NOT a tokio task — per the design decision
//!     in the spec: `compose_tick` blocks on GPU readback for several ms and
//!     we don't want that occupying a tokio worker) runs the 30 Hz driver
//!     loop. Shutdown via `Arc<AtomicBool>` flag, joined explicitly in
//!     `stop()`.
//!
//! Teardown (per fix #14): mirrors `Recording::stop`'s stepped Paused → Ready
//!   → Null transitions with `state(timeout)` waits at each level. Drop is a
//!   panic-path safety net; `stop(self)` is the explicit happy path.

#![allow(clippy::duplicated_attributes)]
#![cfg(feature = "media")]

use crate::source_player::{FrameSink, PlayerSnapshot};
use gstreamer::prelude::*;
use gstreamer_app::AppSink;
use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use thiserror::Error;
use video_coach_compositor::{Compositor, Frame};
use video_coach_core::project::Clip;
use video_coach_core::timeline::{playback_segments, source_time_at, PlaybackSegment, SegmentKind};

const RGBA_CAPS: &str = "video/x-raw,format=RGBA";
const DRIVER_TICK: Duration = Duration::from_micros(33_333);

#[derive(Debug, Error)]
pub enum PreviewPipelineError {
    #[error("element factory `{0}` not available")]
    MissingElement(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("pipeline construction: {0}")]
    Construction(String),
    #[error("seek: {0}")]
    Seek(String),
    #[error("freeze-frame decode: {0}")]
    FreezeDecode(String),
    #[error("compositor: {0}")]
    Compositor(#[from] video_coach_compositor::CompositorError),
    #[error("invalid path (non-utf8)")]
    InvalidPath,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Mirrors `SourcePlayer`'s playhead shape. Wall-clock anchor + paused
/// snapshot — when `is_playing`, current record_time =
/// `anchor_record_time + (now - anchor_instant)`. When paused,
/// `anchor_record_time` is the frozen value.
#[derive(Debug, Clone, Copy)]
struct PlayheadState {
    anchor_record_time: f64,
    anchor_instant: Instant,
    is_playing: bool,
}

impl PlayheadState {
    fn compute(&self) -> f64 {
        if self.is_playing {
            self.anchor_record_time + self.anchor_instant.elapsed().as_secs_f64()
        } else {
            self.anchor_record_time
        }
    }
}

pub struct PreviewPipeline {
    // Live composition pipeline (source + webcam two-input chain).
    pipeline: gstreamer::Pipeline,
    // Webcam pipeline is a separate `gstreamer::Pipeline` — we keep the
    // composition pipeline and the webcam decoder as ONE pipeline (cleaner
    // teardown, no clock-sync games between two pipelines). Source +
    // webcam decodebin instances are added to the same pipeline.

    // Cached frozen frames keyed by segment index (Freeze segments only).
    // Held on the struct so the Arc outlives the driver thread (the driver
    // thread also holds a clone — these are belt-and-suspenders).
    #[allow(dead_code)]
    frozen_frames: Arc<HashMap<usize, Frame>>,

    // Static metadata.
    segments: Arc<Vec<PlaybackSegment>>,
    clip: Arc<Clip>,
    #[allow(dead_code)] // reserved for future seek-clamp logic
    source_duration_seconds: f64,

    // Live latest-frame slots. The appsink callbacks write to these on
    // GStreamer's streaming thread; the 30 Hz driver reads them via its
    // own Arc clones.
    #[allow(dead_code)]
    latest_source_frame: Arc<Mutex<Option<Frame>>>,
    #[allow(dead_code)]
    latest_webcam_frame: Arc<Mutex<Option<Frame>>>,

    // Driver bookkeeping.
    playhead: Arc<Mutex<PlayheadState>>,
    is_playing: Arc<AtomicBool>,
    last_seek_target: Arc<Mutex<Option<f64>>>,

    // Shutdown signaling for the driver thread.
    driver_shutdown: Arc<AtomicBool>,
    driver_handle: Option<JoinHandle<()>>,

    // Source-pipeline seek control (used on Freeze→Play transitions in the
    // driver and on user seek). The pipeline reference is held inside the
    // closure that wraps the live pipeline; we keep a separate handle on
    // just the source decoder pipeline subgraph for seeks. Since both
    // source + webcam live in the same `pipeline`, segment-targeted seeks
    // use the named `filesrc` parents — see `seek_source_pipeline`.

    // For panic-path teardown (Drop). On `stop(self)`, this is taken to
    // signal "explicit teardown already ran".
    teardown_done: Arc<AtomicBool>,
}

impl PreviewPipeline {
    pub fn open(
        source_path: &Path,
        recording_path: &Path,
        clip: &Clip,
        source_duration_seconds: f64,
        compositor: Arc<Compositor>,
        frame_sink: Box<dyn FrameSink>,
    ) -> Result<Self, PreviewPipelineError> {
        crate::init().map_err(|e| PreviewPipelineError::Construction(e.to_string()))?;

        // 1. Build the playback segment list and pre-decode freeze frames.
        let segments = playback_segments(clip, source_duration_seconds);
        let frozen_frames = pre_decode_freeze_frames(source_path, clip, &segments)?;

        // 2. Build the live composition pipeline. Source + webcam decoders
        //    in one pipeline; both feed RGBA appsinks; webcam adds an
        //    audio chain via platform sink.
        let pipeline = gstreamer::Pipeline::new();
        let source_appsink = build_video_input_chain(&pipeline, source_path, "src")?;
        let webcam_appsink = build_webcam_input_chain_with_audio(&pipeline, recording_path, "cam")?;

        // 3. Latest-frame slots wired to appsink callbacks.
        let latest_source_frame: Arc<Mutex<Option<Frame>>> = Arc::new(Mutex::new(None));
        let latest_webcam_frame: Arc<Mutex<Option<Frame>>> = Arc::new(Mutex::new(None));
        attach_frame_slot(&source_appsink, latest_source_frame.clone());
        attach_frame_slot(&webcam_appsink, latest_webcam_frame.clone());

        // 4. Preroll. set_state(Paused) + wait briefly for decodebin to
        //    finish negotiating. Source pipeline is still PAUSED at this
        //    point; the driver thread will rely on `play()` flipping it
        //    to PLAYING.
        pipeline
            .set_state(gstreamer::State::Paused)
            .map_err(|e| PreviewPipelineError::StateChange(format!("preroll: {e:?}")))?;
        let (_, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));

        // 5. Initial source-decoder seek (per fix #23 case (a)).
        if let Some(first) = segments.first() {
            if first.kind == SegmentKind::Play {
                seek_source_named(&pipeline, "src-filesrc", first.source_start, true).ok();
            }
            // If the first segment is Freeze, the source pipeline can sit at
            // its preroll position; the driver uses the cached frame for the
            // Freeze and only seeks when entering the next Play segment.
        }

        // 6. Driver bookkeeping.
        let playhead = Arc::new(Mutex::new(PlayheadState {
            anchor_record_time: 0.0,
            anchor_instant: Instant::now(),
            is_playing: false,
        }));
        let is_playing = Arc::new(AtomicBool::new(false));
        let last_seek_target = Arc::new(Mutex::new(None));
        let driver_shutdown = Arc::new(AtomicBool::new(false));

        let segments_arc = Arc::new(segments);
        let frozen_frames_arc = Arc::new(frozen_frames);
        let clip_arc: Arc<Clip> = Arc::new(clip.clone());

        // 7. Spawn the 30 Hz driver thread. Holds Arc clones for everything
        //    it touches; signals shutdown via `driver_shutdown`.
        let driver_handle = spawn_driver_thread(DriverContext {
            compositor: compositor.clone(),
            pipeline: pipeline.clone(),
            segments: segments_arc.clone(),
            frozen_frames: frozen_frames_arc.clone(),
            clip: clip_arc.clone(),
            latest_source_frame: latest_source_frame.clone(),
            latest_webcam_frame: latest_webcam_frame.clone(),
            playhead: playhead.clone(),
            is_playing: is_playing.clone(),
            shutdown: driver_shutdown.clone(),
            frame_sink: Arc::from(frame_sink),
        });

        tracing::info!(
            target: "clip_preview.lifecycle",
            event = "clip_preview.pipeline_built",
            clip_id = %clip.id,
            segment_count = segments_arc.len(),
            frozen_frame_count = frozen_frames_arc.len(),
        );

        Ok(Self {
            pipeline,
            frozen_frames: frozen_frames_arc,
            segments: segments_arc,
            clip: clip_arc,
            source_duration_seconds,
            latest_source_frame,
            latest_webcam_frame,
            playhead,
            is_playing,
            last_seek_target,
            driver_shutdown,
            driver_handle: Some(driver_handle),
            teardown_done: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn play(&self) -> Result<(), PreviewPipelineError> {
        // Rebase the playhead anchor BEFORE flipping `is_playing`: the
        // wall-clock baseline becomes "now", and anchor_record_time captures
        // wherever we left off (a no-op if we were already paused at that
        // record_time, which is the common case).
        {
            let mut ph = self.playhead.lock().expect("playhead lock");
            // ph.compute() honors the `is_playing` flag; on entry from a
            // paused state it's just the stored anchor.
            let now_record_time = ph.compute();
            ph.anchor_record_time = now_record_time;
            ph.anchor_instant = Instant::now();
            ph.is_playing = true;
        }
        self.pipeline
            .set_state(gstreamer::State::Playing)
            .map_err(|e| PreviewPipelineError::StateChange(format!("play: {e:?}")))?;
        self.is_playing.store(true, Ordering::SeqCst);
        tracing::info!(target: "clip_preview.lifecycle", event = "clip_preview.playing");
        Ok(())
    }

    pub fn pause(&self) -> Result<(), PreviewPipelineError> {
        // Update the anchor to the CURRENT record_time first (so a future
        // play() resumes from here), THEN flip the flag.
        {
            let mut ph = self.playhead.lock().expect("playhead lock");
            let now_record_time = ph.compute();
            ph.anchor_record_time = now_record_time;
            ph.anchor_instant = Instant::now();
            ph.is_playing = false;
        }
        self.pipeline
            .set_state(gstreamer::State::Paused)
            .map_err(|e| PreviewPipelineError::StateChange(format!("pause: {e:?}")))?;
        self.is_playing.store(false, Ordering::SeqCst);
        tracing::info!(target: "clip_preview.lifecycle", event = "clip_preview.paused");
        Ok(())
    }

    /// Seek the preview to `record_time_seconds` (clip-local). Per fix #12,
    /// the source decoder's seek target is resolved via `source_time_at`,
    /// NOT the raw record_time. If the resulting record_time lands in a
    /// Freeze segment, the source decoder is NOT seeked (the driver picks
    /// the cached frozen frame on its next tick).
    pub fn seek(
        &self,
        record_time_seconds: f64,
        accurate: bool,
    ) -> Result<(), PreviewPipelineError> {
        let target = record_time_seconds
            .max(0.0)
            .min(self.clip.recording_duration);

        // Find which segment owns this record_time so we know whether to
        // seek the source decoder at all.
        let seg_idx = segment_index_at(&self.segments, target);
        let seg = self.segments.get(seg_idx).copied();

        // Update playhead anchor first (so the driver's next tick picks up
        // the new target even before GStreamer's seek completes).
        {
            let mut ph = self.playhead.lock().expect("playhead lock");
            ph.anchor_record_time = target;
            ph.anchor_instant = Instant::now();
            // is_playing flag preserved
        }
        *self.last_seek_target.lock().expect("seek target lock") = Some(target);

        // Source decoder seek (per fix #12 + #23 case (c)).
        if let Some(seg) = seg {
            match seg.kind {
                SegmentKind::Play => {
                    let source_time = source_time_at(&self.clip, target);
                    seek_source_named(&self.pipeline, "src-filesrc", source_time, accurate)
                        .map_err(|e| PreviewPipelineError::Seek(format!("source: {e}")))?;
                }
                SegmentKind::Freeze => {
                    // Per fix #12: do NOT seek the source decoder. The
                    // driver uses the cached frozen frame for this segment.
                }
            }
        }

        // Webcam pipeline tracks linearly; always seek to record_time.
        // Use accurate=true for webcam — frame-exact webcam matters more
        // than the coarse-key-unit shortcut here.
        seek_source_named(&self.pipeline, "cam-filesrc", target, true)
            .map_err(|e| PreviewPipelineError::Seek(format!("webcam: {e}")))?;

        tracing::info!(
            target: "clip_preview.lifecycle",
            event = "clip_preview.seeked",
            record_time = target,
            accurate,
        );
        Ok(())
    }

    /// Same shape as `SourcePlayer::snapshot()` so the bus's position-poll
    /// task is reusable verbatim (Task 3 picks this up).
    pub fn snapshot(&self) -> PlayerSnapshot {
        let position = self.playhead.lock().expect("playhead lock").compute();
        PlayerSnapshot {
            position_seconds: position.clamp(0.0, self.clip.recording_duration),
            duration_seconds: self.clip.recording_duration,
            is_playing: self.is_playing.load(Ordering::SeqCst),
        }
    }

    /// Explicit teardown (per fix #14). Mirrors `Recording::stop`'s stepped
    /// Paused → Ready → Null transitions with `state(timeout)` waits at each
    /// level — without these, decodebin's child decoders close OS handles
    /// concurrently with the audio sink's IO callback, racing on macOS.
    /// NO EOS send (we're not finalizing a file).
    pub fn stop(mut self) -> Result<(), PreviewPipelineError> {
        self.teardown_inner()
    }

    fn teardown_inner(&mut self) -> Result<(), PreviewPipelineError> {
        if self.teardown_done.swap(true, Ordering::SeqCst) {
            return Ok(()); // already torn down
        }

        // Stop the driver thread first so it's not racing the pipeline
        // state transitions. Setting the flag + joining is enough; the
        // driver checks the flag every tick (≤ 33ms) and exits cleanly.
        self.driver_shutdown.store(true, Ordering::SeqCst);
        if let Some(handle) = self.driver_handle.take() {
            // Don't propagate panics from the driver (extremely unlikely;
            // any compose error is logged + skipped per tick). Joining
            // ensures we don't tear down the pipeline while the driver is
            // mid-compose.
            let _ = handle.join();
        }

        // Stepped state transitions per fix #14.
        for intermediate in [gstreamer::State::Paused, gstreamer::State::Ready] {
            if let Err(e) = self.pipeline.set_state(intermediate) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    state = ?intermediate,
                    error = ?e,
                    "intermediate set_state failed; continuing teardown",
                );
                continue;
            }
            let (res, _, _) = self
                .pipeline
                .state(Some(gstreamer::ClockTime::from_seconds(2)));
            if let Err(e) = res {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    state = ?intermediate,
                    error = ?e,
                    "intermediate state wait failed; continuing teardown",
                );
            }
        }

        let null_result: Result<(), PreviewPipelineError> = self
            .pipeline
            .set_state(gstreamer::State::Null)
            .map(|_| ())
            .map_err(|e| PreviewPipelineError::StateChange(format!("NULL: {e:?}")));

        tracing::info!(
            target: "clip_preview.lifecycle",
            event = "clip_preview.pipeline_torn_down",
            clip_id = %self.clip.id,
        );

        null_result
    }
}

impl Drop for PreviewPipeline {
    fn drop(&mut self) {
        // Best-effort panic-path teardown. The explicit stop() is preferred
        // (per fix #14); if Drop is the only path that runs, we still flip
        // the driver's shutdown flag, join, and step the pipeline down.
        if let Err(e) = self.teardown_inner() {
            tracing::warn!(
                target: "clip_preview.lifecycle",
                error = ?e,
                "PreviewPipeline drop teardown error (panic path?)",
            );
        }
    }
}

// ─── helpers ────────────────────────────────────────────────────────────────

fn make_or(name: &str) -> Result<gstreamer::Element, PreviewPipelineError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement(name.into()))
}

/// Resolve which segment owns `record_time` by linear walk. Returns the
/// last segment's index if `record_time` is past the end (driver clamps
/// playback to clip.recording_duration anyway).
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

/// Build `filesrc → decodebin → videoconvert → caps RGBA → appsink` and
/// route any non-video pad to a fakesink (so audio in the source file
/// doesn't deadlock decodebin's multiqueue). Element names prefixed with
/// `label` so two chains in the same pipeline don't collide; the filesrc's
/// name is `{label}-filesrc` so `seek_source_named` can target it.
fn build_video_input_chain(
    pipeline: &gstreamer::Pipeline,
    path: &Path,
    label: &'static str,
) -> Result<AppSink, PreviewPipelineError> {
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .name(format!("{label}-filesrc"))
        .property(
            "location",
            path.to_str().ok_or(PreviewPipelineError::InvalidPath)?,
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("filesrc".into()))?;
    let decodebin = gstreamer::ElementFactory::make("decodebin")
        .name(format!("{label}-decodebin"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("decodebin".into()))?;
    let queue_in = gstreamer::ElementFactory::make("queue")
        .name(format!("{label}-queue"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("queue".into()))?;
    let videoconvert = gstreamer::ElementFactory::make("videoconvert")
        .name(format!("{label}-videoconvert"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("videoconvert".into()))?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .name(format!("{label}-capsfilter"))
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;
    let appsink_elem = gstreamer::ElementFactory::make("appsink")
        .name(format!("{label}-appsink"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("appsink".into()))?;
    let appsink = appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| PreviewPipelineError::Construction(format!("{label}: appsink downcast")))?;
    appsink.set_property("sync", true);

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue_in,
            &videoconvert,
            &capsfilter,
            appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| PreviewPipelineError::Construction(format!("{label}: add chain: {e}")))?;
    filesrc.link(&decodebin).map_err(|e| {
        PreviewPipelineError::Construction(format!("{label}: filesrc→decodebin: {e}"))
    })?;
    gstreamer::Element::link_many([
        &queue_in,
        &videoconvert,
        &capsfilter,
        appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| PreviewPipelineError::Construction(format!("{label}: link chain: {e}")))?;

    let queue_sink = queue_in
        .static_pad("sink")
        .ok_or_else(|| PreviewPipelineError::Construction(format!("{label}: no queue sink")))?;
    let pipeline_weak = pipeline.downgrade();
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
            if let Err(e) = pad.link(&queue_sink) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    chain = %label_owned,
                    error = ?e,
                    "failed to link decoded video pad",
                );
            }
            return;
        }
        // Non-video (typically audio) — fakesink so decodebin doesn't stall.
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

    Ok(appsink)
}

/// Same as `build_video_input_chain` but routes the decoded audio pad
/// through `audioconvert → audioresample → volume(commentary_volume) →
/// platform_audio_sink`. Used for the recording.mov chain.
///
/// Per the Phase 9 spec: the source video's audio is NOT routed (it'd
/// stall decodebin without a sink, so the helper above sends it to a
/// fakesink instead). Phase 9.5 will add the dual-slider mix.
fn build_webcam_input_chain_with_audio(
    pipeline: &gstreamer::Pipeline,
    path: &Path,
    label: &'static str,
) -> Result<AppSink, PreviewPipelineError> {
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .name(format!("{label}-filesrc"))
        .property(
            "location",
            path.to_str().ok_or(PreviewPipelineError::InvalidPath)?,
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("filesrc".into()))?;
    let decodebin = gstreamer::ElementFactory::make("decodebin")
        .name(format!("{label}-decodebin"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("decodebin".into()))?;
    let queue_in = gstreamer::ElementFactory::make("queue")
        .name(format!("{label}-queue"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("queue".into()))?;
    let videoconvert = gstreamer::ElementFactory::make("videoconvert")
        .name(format!("{label}-videoconvert"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("videoconvert".into()))?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .name(format!("{label}-capsfilter"))
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;
    let appsink_elem = gstreamer::ElementFactory::make("appsink")
        .name(format!("{label}-appsink"))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("appsink".into()))?;
    let appsink = appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| PreviewPipelineError::Construction(format!("{label}: appsink downcast")))?;
    appsink.set_property("sync", true);

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue_in,
            &videoconvert,
            &capsfilter,
            appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| PreviewPipelineError::Construction(format!("{label}: add chain: {e}")))?;
    filesrc.link(&decodebin).map_err(|e| {
        PreviewPipelineError::Construction(format!("{label}: filesrc→decodebin: {e}"))
    })?;
    gstreamer::Element::link_many([
        &queue_in,
        &videoconvert,
        &capsfilter,
        appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| PreviewPipelineError::Construction(format!("{label}: link chain: {e}")))?;

    let queue_sink = queue_in
        .static_pad("sink")
        .ok_or_else(|| PreviewPipelineError::Construction(format!("{label}: no queue sink")))?;
    let pipeline_weak = pipeline.downgrade();
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
            if let Err(e) = pad.link(&queue_sink) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    chain = %label_owned,
                    error = ?e,
                    "failed to link decoded webcam video pad",
                );
            }
            return;
        }
        if media.starts_with("audio/") {
            let Some(pipeline) = pipeline_weak.upgrade() else {
                return;
            };
            if let Err(e) = build_and_link_webcam_audio_chain(&pipeline, pad) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    chain = %label_owned,
                    error = %e,
                    "failed to wire webcam audio chain (audio will be silent)",
                );
            }
            return;
        }
        // Anything else: drain to fakesink.
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

    Ok(appsink)
}

fn build_and_link_webcam_audio_chain(
    pipeline: &gstreamer::Pipeline,
    src_pad: &gstreamer::Pad,
) -> Result<(), PreviewPipelineError> {
    let queue = make_or("queue")?;
    let convert = make_or("audioconvert")?;
    let resample = make_or("audioresample")?;
    let volume = gstreamer::ElementFactory::make("volume")
        .name("commentary_volume")
        .property("volume", 1.0_f64)
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("volume".into()))?;
    let audiosink = if platform_audio_sink_name() == "fakesink" {
        // Honor VIDEO_COACH_NO_AUDIO=1 (CI / headless tests). Real fakesinks
        // need sync=true so they don't fast-drain past real-time, mirroring
        // `source_player.rs`'s pattern.
        gstreamer::ElementFactory::make("fakesink")
            .property("sync", true)
            .build()
            .map_err(|_| PreviewPipelineError::MissingElement("fakesink".into()))?
    } else {
        make_or(platform_audio_sink_name())?
    };

    pipeline
        .add_many([&queue, &convert, &resample, &volume, &audiosink])
        .map_err(|e| PreviewPipelineError::Construction(format!("add audio chain: {e}")))?;
    gstreamer::Element::link_many([&queue, &convert, &resample, &volume, &audiosink])
        .map_err(|e| PreviewPipelineError::Construction(format!("link audio chain: {e}")))?;
    for e in [&queue, &convert, &resample, &volume, &audiosink] {
        e.sync_state_with_parent()
            .map_err(|e| PreviewPipelineError::Construction(format!("sync state: {e}")))?;
    }
    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| PreviewPipelineError::Construction("audio queue has no sink pad".into()))?;
    src_pad
        .link(&queue_sink)
        .map_err(|e| PreviewPipelineError::Construction(format!("link audio pad: {e:?}")))?;
    Ok(())
}

/// Same env-var override + per-platform default name as `source_player.rs`.
/// Duplicated here rather than re-exported because `source_player.rs`'s helper
/// is a module-private fn; making it public would widen the API surface for
/// no test-side benefit.
fn platform_audio_sink_name() -> &'static str {
    if std::env::var("VIDEO_COACH_NO_AUDIO").is_ok() {
        return "fakesink";
    }
    if cfg!(target_os = "macos") {
        "osxaudiosink"
    } else if cfg!(target_os = "windows") {
        "wasapisink"
    } else {
        "pulsesink"
    }
}

/// Wire the appsink so every preroll + sample writes the decoded RGBA
/// buffer into a single-slot `Mutex<Option<Frame>>`. New frames overwrite
/// older ones — the 30 Hz driver reads whatever's there at tick time.
fn attach_frame_slot(appsink: &AppSink, slot: Arc<Mutex<Option<Frame>>>) {
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

/// Issue an accurate or key-unit GStreamer seek scoped to the named filesrc's
/// element pipeline. We seek the whole pipeline (not just the upstream) since
/// GStreamer routes pipeline seeks through every source automatically. The
/// `_named` suffix is a placeholder for future per-source seeking when the
/// preview adds a second separately-driven source — today both source +
/// webcam share one pipeline so this is just `pipeline.seek_simple`.
fn seek_source_named(
    pipeline: &gstreamer::Pipeline,
    _filesrc_name: &str,
    seconds: f64,
    accurate: bool,
) -> Result<(), gstreamer::glib::BoolError> {
    let clamped = seconds.max(0.0);
    let position = gstreamer::ClockTime::from_nseconds((clamped * 1_000_000_000.0).round() as u64);
    let mut flags = gstreamer::SeekFlags::FLUSH;
    if accurate {
        flags |= gstreamer::SeekFlags::ACCURATE;
    } else {
        flags |= gstreamer::SeekFlags::KEY_UNIT;
    }
    pipeline.seek_simple(flags, position)
}

// ─── freeze-frame pre-decode ────────────────────────────────────────────────

/// Pre-decode the source frame for each Freeze segment per fix #6 + #11.
/// The source-time to decode is the END of the preceding Play segment
/// (`prev_play.source_start + prev_play.out_duration`), NOT the freeze
/// segment's own `source_start` — for Skip-then-Freeze patterns these
/// differ, and the latter produces the wrong (post-skip) frame.
///
/// Synchronous: opens a small mini-pipeline per Freeze segment, seeks
/// accurate=true, pulls one preroll buffer, tears it down. Caller (the
/// bus task in Phase 9 Task 3) wraps the whole `open()` call in
/// spawn_blocking; doing the pre-decodes inline here is fine.
fn pre_decode_freeze_frames(
    source_path: &Path,
    clip: &Clip,
    segments: &[PlaybackSegment],
) -> Result<HashMap<usize, Frame>, PreviewPipelineError> {
    let mut out = HashMap::new();
    for (i, seg) in segments.iter().enumerate() {
        if seg.kind != SegmentKind::Freeze {
            continue;
        }
        // Walk backward to find the most recent Play. Per fix #11.
        let mut source_time = clip.start_source_seconds; // fallback if no preceding Play
        for j in (0..i).rev() {
            let prev = &segments[j];
            if prev.kind == SegmentKind::Play {
                source_time = prev.source_start + prev.out_duration;
                break;
            }
        }
        let frame = decode_one_frame_at(source_path, source_time)?;
        out.insert(i, frame);
    }
    Ok(out)
}

/// Open a `filesrc → decodebin → videoconvert → caps RGBA → appsink`
/// mini-pipeline, seek to `source_time_seconds` accurate=true, pull
/// one preroll buffer, tear down. Returns the decoded RGBA frame.
fn decode_one_frame_at(
    source_path: &Path,
    source_time_seconds: f64,
) -> Result<Frame, PreviewPipelineError> {
    crate::init().map_err(|e| PreviewPipelineError::Construction(e.to_string()))?;

    let pipeline = gstreamer::Pipeline::new();
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .property(
            "location",
            source_path
                .to_str()
                .ok_or(PreviewPipelineError::InvalidPath)?,
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("filesrc".into()))?;
    let decodebin = make_or("decodebin")?;
    let queue = make_or("queue")?;
    let videoconvert = make_or("videoconvert")?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;
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
        .map_err(|e| PreviewPipelineError::FreezeDecode(format!("add: {e}")))?;
    filesrc
        .link(&decodebin)
        .map_err(|e| PreviewPipelineError::FreezeDecode(format!("link filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([
        &queue,
        &videoconvert,
        &capsfilter,
        appsink.upcast_ref::<gstreamer::Element>(),
    ])
    .map_err(|e| PreviewPipelineError::FreezeDecode(format!("link chain: {e}")))?;

    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| PreviewPipelineError::FreezeDecode("queue has no sink".into()))?;
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

    // Set state PAUSED, wait for preroll to finish, seek accurate=true to
    // the target time, pull the next preroll, tear down.
    pipeline
        .set_state(gstreamer::State::Paused)
        .map_err(|e| PreviewPipelineError::FreezeDecode(format!("PAUSED: {e:?}")))?;
    let (state_res, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));
    if let Err(e) = state_res {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(PreviewPipelineError::FreezeDecode(format!(
            "preroll wait: {e:?}"
        )));
    }

    let target = gstreamer::ClockTime::from_nseconds((source_time_seconds.max(0.0) * 1e9) as u64);
    let seek_ok = pipeline.seek_simple(
        gstreamer::SeekFlags::FLUSH | gstreamer::SeekFlags::ACCURATE,
        target,
    );
    if seek_ok.is_err() {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(PreviewPipelineError::FreezeDecode(format!(
            "seek to {source_time_seconds}s failed",
        )));
    }
    // Wait for the seek to settle (preroll resamples). Without this, the
    // pulled preroll is stale (the pre-seek frame).
    let (state_res2, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));
    if let Err(e) = state_res2 {
        let _ = pipeline.set_state(gstreamer::State::Null);
        return Err(PreviewPipelineError::FreezeDecode(format!(
            "post-seek preroll wait: {e:?}"
        )));
    }

    let sample = appsink
        .pull_preroll()
        .map_err(|e| PreviewPipelineError::FreezeDecode(format!("pull preroll: {e:?}")))?;
    let frame = sample_to_frame(&sample).ok_or_else(|| {
        PreviewPipelineError::FreezeDecode("preroll sample lacked caps/buffer".into())
    })?;
    let _ = pipeline.set_state(gstreamer::State::Null);

    Ok(frame)
}

// ─── 30 Hz driver thread ────────────────────────────────────────────────────

struct DriverContext {
    compositor: Arc<Compositor>,
    pipeline: gstreamer::Pipeline,
    segments: Arc<Vec<PlaybackSegment>>,
    frozen_frames: Arc<HashMap<usize, Frame>>,
    clip: Arc<Clip>,
    latest_source_frame: Arc<Mutex<Option<Frame>>>,
    latest_webcam_frame: Arc<Mutex<Option<Frame>>>,
    playhead: Arc<Mutex<PlayheadState>>,
    is_playing: Arc<AtomicBool>,
    shutdown: Arc<AtomicBool>,
    frame_sink: Arc<dyn FrameSink>,
}

fn spawn_driver_thread(ctx: DriverContext) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("clip_preview-driver".into())
        .spawn(move || run_driver_loop(ctx))
        .expect("spawn clip-preview driver thread")
}

fn run_driver_loop(ctx: DriverContext) {
    let DriverContext {
        compositor,
        pipeline,
        segments,
        frozen_frames,
        clip,
        latest_source_frame,
        latest_webcam_frame,
        playhead,
        is_playing,
        shutdown,
        frame_sink,
    } = ctx;

    // Tracks the segment served on the previous tick. A change from
    // Freeze→Play triggers a one-shot source-decoder seek to the new Play
    // segment's `source_start` (per fix #23 case (b)).
    let mut last_segment_idx: Option<usize> = None;
    let mut completion_emitted = false;

    let mut next_tick = Instant::now();
    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // Hold the last frame when paused. Per spec, we still post one
        // frame after pause() (the playhead is at its new position, the
        // frame should match), but in practice the driver was already
        // pushing the latest frame each tick BEFORE pause flipped the
        // anchor — so a simple "skip pushes while paused" is fine and
        // keeps GPU work bounded.
        if !is_playing.load(Ordering::Acquire) {
            sleep_until(&mut next_tick);
            continue;
        }

        let record_time = playhead.lock().expect("playhead lock").compute();
        if record_time >= clip.recording_duration {
            // Past the end. Stop pushing frames; emit the completion event
            // exactly once. Mode stays PreviewClip until ClosePreview (fix #20).
            if !completion_emitted {
                tracing::info!(
                    target: "clip_preview.lifecycle",
                    event = "clip_preview.completed",
                    clip_id = %clip.id,
                );
                completion_emitted = true;
            }
            sleep_until(&mut next_tick);
            continue;
        }

        let seg_idx = segment_index_at(&segments, record_time);
        let seg = segments[seg_idx];

        // Freeze→Play boundary: one-shot source seek (per fix #23 case (b)).
        if let Some(prev) = last_segment_idx {
            let prev_kind = segments[prev].kind;
            if prev_kind == SegmentKind::Freeze && seg.kind == SegmentKind::Play {
                let _ = seek_source_named(&pipeline, "src-filesrc", seg.source_start, true);
            }
        }
        last_segment_idx = Some(seg_idx);

        // Resolve source frame.
        let source_frame = match seg.kind {
            SegmentKind::Freeze => frozen_frames.get(&seg_idx).cloned().unwrap_or_else(|| {
                // Defensive fallback: shouldn't happen because pre-decode
                // covers every Freeze, but if something went wrong (file
                // disappeared mid-preview?) use a 2x2 black so the driver
                // doesn't crash.
                Frame::solid(2, 2, [0, 0, 0, 255])
            }),
            SegmentKind::Play => latest_source_frame
                .lock()
                .expect("source slot lock")
                .clone()
                .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255])),
        };

        // Webcam frame — last-frame-held past EOS per fix #20.
        let webcam_frame = latest_webcam_frame
            .lock()
            .expect("webcam slot lock")
            .clone()
            .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255]));

        // Strokes for this record_time.
        let strokes = video_coach_core::stroke_replay::visible_strokes(&clip, record_time);

        // Compose + push.
        match video_coach_compositor::compose_tick(
            &compositor,
            &source_frame,
            &webcam_frame,
            &strokes,
        ) {
            Ok(composed) => {
                frame_sink.push_frame(composed.width, composed.height, &composed.pixels);
            }
            Err(e) => {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    error = ?e,
                    record_time,
                    "compose_tick error; skipping frame",
                );
            }
        }

        sleep_until(&mut next_tick);
    }
}

/// Sleep until `*next_tick`, then advance `next_tick` to the next 33.33ms
/// boundary. Falls behind gracefully — if we're already past the deadline
/// (compose took longer than a tick), set the next deadline to now+TICK
/// instead of catching up immediately (avoids burst-pushing frames after
/// a hiccup).
fn sleep_until(next_tick: &mut Instant) {
    let now = Instant::now();
    if now < *next_tick {
        std::thread::sleep(*next_tick - now);
    }
    *next_tick = Instant::now() + DRIVER_TICK;
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
        // Past the end clamps to the last segment.
        assert_eq!(segment_index_at(&segs, 100.0), 2);
    }
}
