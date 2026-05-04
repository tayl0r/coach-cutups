//! Phase 9 Task 2. Clip-preview pipeline.
//!
//! Architectural shape (per phase plan + adversarial fixes #6, #11, #14, #17,
//! #20, #23, #24):
//!
//! ```text
//!   filesrc(source)   → decodebin → videoconvert → caps RGBA → appsink ── source_slot
//!                                                ╲
//!                                                 → audioconvert → audioresample
//!                                                       → volume(preview_source_vol)
//!                                                       → capsfilter(F32LE,48k,2ch)
//!                                                       → audiomixer.sink_%u
//!
//!   filesrc(recording.mov) → decodebin → videoconvert → caps RGBA → appsink ── webcam_slot
//!                                       ╲
//!                                        → audioconvert → audioresample
//!                                              → volume(preview_commentary_vol)
//!                                              → capsfilter(F32LE,48k,2ch)
//!                                              → audiomixer.sink_%u
//!
//!   audiotestsrc(silence,is-live) → audioconvert → capsfilter(F32LE,48k,2ch)
//!                                              → audiomixer.sink_%u   (phantom; adv #7)
//!
//!   audiomixer(name=preview_audio_mixer)
//!       → audioconvert → audioresample
//!       → capsfilter(F32LE,48k,2ch)               (downstream anchor; adv #3)
//!       → platform_audio_sink_name()
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
/// Phase 11 Plan #1 Task 2: shared audio caps for the preview audiomixer.
/// Both source-audio and commentary-audio chains capsfilter to this BEFORE
/// linking to a mixer sinkpad; an identical capsfilter is wired DOWNSTREAM
/// of the mixer per adv-fix #3 (HARD REQUIRED). audiomixer negotiates output
/// caps from the FIRST sinkpad to get caps; without the downstream anchor
/// pad-added ordering between source/recording (decodebin async) can land
/// the mixer at the wrong format and the second sinkpad's renegotiation
/// fails.
const PREVIEW_AUDIO_CAPS: &str =
    "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved";

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
    // thread also holds a clone — these are belt-and-suspenders). Per
    // Fix #48, values are `Arc<Frame>` so the driver hands the SAME Arc
    // for every Freeze tick → freeze-cache pointer-identity hits.
    #[allow(dead_code)]
    frozen_frames: Arc<HashMap<usize, Arc<Frame>>>,

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
        // Per Fix #48: pre_decode_freeze_frames keeps its `HashMap<usize,
        // Frame>` return type (stable surface); we wrap each value in
        // `Arc::new` here at the consumer boundary so the driver hands a
        // stable Arc-pointer per Freeze segment for compose-cache hits.
        let segments = playback_segments(clip, source_duration_seconds);
        let frozen_frames_raw = pre_decode_freeze_frames(source_path, clip, &segments)?;
        let frozen_frames: HashMap<usize, Arc<Frame>> = frozen_frames_raw
            .into_iter()
            .map(|(k, v)| (k, Arc::new(v)))
            .collect();

        // 2. Build the live composition pipeline. Source + webcam decoders
        //    in one pipeline; both feed RGBA appsinks; both feed a single
        //    shared audiomixer + audiosink (Phase 11 Plan #1 Task 2).
        //
        //    Construction order matters: the audiomixer + downstream sink
        //    + phantom silence sinkpad MUST be wired BEFORE per-input
        //    decodebins start firing pad-added events. Two reasons:
        //    (a) the per-input pad-added handlers request_pad("sink_%u")
        //        on the named mixer; the mixer must already exist in the
        //        pipeline.
        //    (b) adv-fix #7: audiomixer needs ≥1 sinkpad to transition to
        //        PAUSED. If both decodebins are still probing and neither
        //        has fired pad-added when set_state(Paused) runs, a
        //        zero-pad mixer blocks PAUSED indefinitely and the
        //        downstream audiosink never prerolls. The phantom silence
        //        sinkpad guarantees ≥1 pad through PAUSED. Same trick
        //        playbin3's internal mixer uses.
        let pipeline = gstreamer::Pipeline::new();
        build_audio_mixer_and_sink(&pipeline)?;
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

    /// Phase 11 Plan #1 Task 2: live-tune the source-side volume into
    /// the preview audiomixer. Looks up the named volume element and
    /// updates its `volume` property atomically — no pipeline restart,
    /// no glitch (verified pattern in `source_player.rs::set_volume`).
    /// No-op if the source has no audio track (the named volume element
    /// is built lazily inside the source decoder's audio pad-added
    /// handler; if the source file has no audio, the element never
    /// exists and `by_name` returns None).
    pub fn set_source_volume(&self, value: f64) {
        let v = value.clamp(0.0, 1.0);
        if let Some(volume) = self.pipeline.by_name("preview_source_vol") {
            volume.set_property("volume", v);
        }
    }

    /// Phase 11 Plan #1 Task 2: live-tune the commentary-side volume
    /// into the preview audiomixer. Same shape as `set_source_volume`.
    pub fn set_commentary_volume(&self, value: f64) {
        let v = value.clamp(0.0, 1.0);
        if let Some(volume) = self.pipeline.by_name("preview_commentary_vol") {
            volume.set_property("volume", v);
        }
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

/// Phase 11 Plan #1 Task 2: build the shared audio output spine of the
/// preview pipeline. Layout:
///
/// ```text
///   audiotestsrc(silence,is-live)         (phantom silence sinkpad — adv #7)
///       → audioconvert
///       → capsfilter(F32LE,48k,2ch)
///       → audiomixer(name=preview_audio_mixer).sink_%u
///   <per-input volume chains>
///       → mixer.sink_%u   (added later by pad-added handlers)
///   audiomixer
///       → audioconvert
///       → audioresample
///       → capsfilter(F32LE,48k,2ch)        (adv #3 HARD REQUIRED)
///       → audiosink (osxaudiosink/wasapisink/pulsesink, or fakesink in CI)
/// ```
///
/// Wired BEFORE the per-input decodebins start firing pad-added events
/// so (a) the named mixer exists when the audio handlers request_pad
/// on it and (b) the mixer has ≥1 sinkpad through PAUSED (adv-fix #7).
fn build_audio_mixer_and_sink(pipeline: &gstreamer::Pipeline) -> Result<(), PreviewPipelineError> {
    let audiomixer = gstreamer::ElementFactory::make("audiomixer")
        .name("preview_audio_mixer")
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("audiomixer".into()))?;
    // Downstream chain — adv-fix #3: capsfilter pinning F32LE/48k/2ch
    // AFTER the mixer is non-negotiable. Without it, pad-added ordering
    // races can land the mixer at the wrong output caps and the second
    // real sinkpad's renegotiation fails.
    let post_convert = make_or("audioconvert")?;
    let post_resample = make_or("audioresample")?;
    let post_capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .name("preview_audio_post_caps")
        .property(
            "caps",
            gstreamer::Caps::from_str(PREVIEW_AUDIO_CAPS).unwrap(),
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;
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
        .add_many([
            &audiomixer,
            &post_convert,
            &post_resample,
            &post_capsfilter,
            &audiosink,
        ])
        .map_err(|e| PreviewPipelineError::Construction(format!("add audiomixer chain: {e}")))?;
    gstreamer::Element::link_many([
        &audiomixer,
        &post_convert,
        &post_resample,
        &post_capsfilter,
        &audiosink,
    ])
    .map_err(|e| PreviewPipelineError::Construction(format!("link audiomixer chain: {e}")))?;

    // Phantom silence sinkpad (adv-fix #7). Guarantees the mixer has ≥1
    // sinkpad when the pipeline transitions to PAUSED, even if both
    // decodebins delay pad-added. Same trick playbin3's internal mixer
    // uses. volume=0 is implicit via wave=silence; we don't add a `volume`
    // element here because a silence-source already emits zeros.
    let silence = gstreamer::ElementFactory::make("audiotestsrc")
        .name("preview_audio_phantom_silence")
        .property_from_str("wave", "silence")
        .property("is-live", true)
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("audiotestsrc".into()))?;
    let silence_convert = make_or("audioconvert")?;
    let silence_caps = gstreamer::ElementFactory::make("capsfilter")
        .property(
            "caps",
            gstreamer::Caps::from_str(PREVIEW_AUDIO_CAPS).unwrap(),
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;
    pipeline
        .add_many([&silence, &silence_convert, &silence_caps])
        .map_err(|e| PreviewPipelineError::Construction(format!("add phantom silence: {e}")))?;
    gstreamer::Element::link_many([&silence, &silence_convert, &silence_caps])
        .map_err(|e| PreviewPipelineError::Construction(format!("link phantom silence: {e}")))?;
    let mixer_pad = audiomixer.request_pad_simple("sink_%u").ok_or_else(|| {
        PreviewPipelineError::Construction("audiomixer phantom sink_%u request failed".into())
    })?;
    let silence_src = silence_caps.static_pad("src").ok_or_else(|| {
        PreviewPipelineError::Construction("phantom silence capsfilter has no src pad".into())
    })?;
    silence_src.link(&mixer_pad).map_err(|e| {
        PreviewPipelineError::Construction(format!("link phantom silence → mixer: {e:?}"))
    })?;

    Ok(())
}

/// Phase 11 Plan #1 Task 2: link a freshly-arrived audio pad (from one of
/// the source/webcam decodebins) into the shared `preview_audio_mixer` via
/// `queue → audioconvert → audioresample → volume(name=`volume_name`) →
/// capsfilter(F32LE,48k,2ch) → mixer.sink_%u`.
///
/// The named volume element is the live-tune handle: `set_source_volume`
/// / `set_commentary_volume` look it up by name. Placement matters
/// (per Plan task 2 note 10): AFTER audioconvert+audioresample, BEFORE
/// the capsfilter, so volume scales F32 (clean math) and every sinkpad
/// presents identical caps to the mixer.
fn link_audio_pad_to_mixer(
    pipeline: &gstreamer::Pipeline,
    src_pad: &gstreamer::Pad,
    volume_name: &str,
    initial_volume: f64,
) -> Result<(), PreviewPipelineError> {
    let mixer = pipeline.by_name("preview_audio_mixer").ok_or_else(|| {
        PreviewPipelineError::Construction("preview_audio_mixer not found".into())
    })?;

    let queue = make_or("queue")?;
    let convert = make_or("audioconvert")?;
    let resample = make_or("audioresample")?;
    let volume = gstreamer::ElementFactory::make("volume")
        .name(volume_name)
        .property("volume", initial_volume.clamp(0.0, 1.0))
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("volume".into()))?;
    let caps = gstreamer::ElementFactory::make("capsfilter")
        .property(
            "caps",
            gstreamer::Caps::from_str(PREVIEW_AUDIO_CAPS).unwrap(),
        )
        .build()
        .map_err(|_| PreviewPipelineError::MissingElement("capsfilter".into()))?;

    pipeline
        .add_many([&queue, &convert, &resample, &volume, &caps])
        .map_err(|e| PreviewPipelineError::Construction(format!("add audio chain: {e}")))?;
    gstreamer::Element::link_many([&queue, &convert, &resample, &volume, &caps])
        .map_err(|e| PreviewPipelineError::Construction(format!("link audio chain: {e}")))?;

    // Sync state with parent BEFORE pad linking so the new elements come
    // up to whatever state the pipeline is currently in (PAUSED during
    // preroll, PLAYING after play() flipped state).
    for e in [&queue, &convert, &resample, &volume, &caps] {
        e.sync_state_with_parent()
            .map_err(|e| PreviewPipelineError::Construction(format!("sync state: {e}")))?;
    }

    // Request a fresh sinkpad on the mixer and link the chain's tail to
    // it. The mixer's request-pad ordering doesn't matter — we look up
    // volume elements by name, not by mixer pad index.
    let mixer_pad = mixer.request_pad_simple("sink_%u").ok_or_else(|| {
        PreviewPipelineError::Construction("audiomixer sink_%u request failed".into())
    })?;
    let caps_src = caps
        .static_pad("src")
        .ok_or_else(|| PreviewPipelineError::Construction("audio capsfilter has no src".into()))?;
    caps_src
        .link(&mixer_pad)
        .map_err(|e| PreviewPipelineError::Construction(format!("link → mixer: {e:?}")))?;

    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| PreviewPipelineError::Construction("audio queue has no sink pad".into()))?;
    src_pad
        .link(&queue_sink)
        .map_err(|e| PreviewPipelineError::Construction(format!("link decode pad: {e:?}")))?;

    Ok(())
}

/// Build `filesrc → decodebin → videoconvert → caps RGBA → appsink` and
/// route the source's audio pad into the shared `preview_audio_mixer`
/// via the source-volume element (Phase 11 Plan #1 Task 2). Non-audio,
/// non-video pads (subtitles, data) drain to fakesink so decodebin's
/// multiqueue doesn't stall. Element names prefixed with `label` so two
/// chains in the same pipeline don't collide; the filesrc's name is
/// `{label}-filesrc` so `seek_source_named` can target it.
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
        let Some(pipeline) = pipeline_weak.upgrade() else {
            return;
        };
        if media.starts_with("audio/") {
            // Phase 11 Plan #1 Task 2: route the source's audio into the
            // shared audiomixer via the named source-volume element. If
            // wiring fails the audio side is silently dropped (fall back
            // to fakesink-equivalent behavior so decodebin doesn't
            // stall) — log loudly so missing source audio is debuggable.
            if let Err(e) = link_audio_pad_to_mixer(
                &pipeline,
                pad,
                "preview_source_vol",
                /* initial_volume */ 1.0,
            ) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    chain = %label_owned,
                    error = %e,
                    "failed to wire source audio into preview mixer (source audio will be silent)",
                );
                drain_pad_to_fakesink(&pipeline, pad, &label_owned);
            }
            return;
        }
        // Anything else (subtitles, data) — fakesink so decodebin doesn't stall.
        drain_pad_to_fakesink(&pipeline, pad, &label_owned);
    });

    Ok(appsink)
}

/// Helper: drain an unhandled decodebin pad to a fresh fakesink. Used for
/// non-audio, non-video pads (subtitles, data) and as a fallback when
/// audio mixer wiring fails.
fn drain_pad_to_fakesink(pipeline: &gstreamer::Pipeline, pad: &gstreamer::Pad, label: &str) {
    let fakesink = match gstreamer::ElementFactory::make("fakesink")
        .name(format!("{label}-aux-fakesink"))
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
        let Some(pipeline) = pipeline_weak.upgrade() else {
            return;
        };
        if media.starts_with("audio/") {
            // Phase 11 Plan #1 Task 2: route commentary audio into the
            // shared audiomixer via the named commentary-volume element.
            if let Err(e) = link_audio_pad_to_mixer(
                &pipeline,
                pad,
                "preview_commentary_vol",
                /* initial_volume */ 1.0,
            ) {
                tracing::warn!(
                    target: "clip_preview.lifecycle",
                    chain = %label_owned,
                    error = %e,
                    "failed to wire commentary audio into preview mixer (audio will be silent)",
                );
                drain_pad_to_fakesink(&pipeline, pad, &label_owned);
            }
            return;
        }
        // Anything else: drain to fakesink.
        drain_pad_to_fakesink(&pipeline, pad, &label_owned);
    });

    Ok(appsink)
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
    frozen_frames: Arc<HashMap<usize, Arc<Frame>>>,
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

        // Plan #4 Task 3 / Fix #43: clear the freeze compose cache on
        // any segment-index change. The content-prefix-defended key
        // already prevents stale-Arc hits across boundaries, but this
        // proactive clear bounds the LRU's working set to the current
        // segment so a long timeline doesn't grow unrelated entries.
        // Placed BEFORE the Freeze→Play seek so the cache is dropped
        // for every transition direction (Play→Freeze, Freeze→Freeze
        // included).
        if last_segment_idx != Some(seg_idx) {
            compositor.clear_freeze_cache();
        }

        // Freeze→Play boundary: one-shot source seek (per fix #23 case (b)).
        if let Some(prev) = last_segment_idx {
            let prev_kind = segments[prev].kind;
            if prev_kind == SegmentKind::Freeze && seg.kind == SegmentKind::Play {
                let _ = seek_source_named(&pipeline, "src-filesrc", seg.source_start, true);
            }
        }
        last_segment_idx = Some(seg_idx);

        // Resolve source frame as Arc<Frame>. For Freeze the cached
        // `Arc<Frame>` is cloned (cheap refcount bump) and yields a
        // STABLE pointer across ticks → compose cache hits. For Play
        // we wrap the live appsink slot's Frame in a fresh Arc each
        // tick (the slot mutates from GStreamer's streaming thread; a
        // fresh Arc per tick is correct + the freeze cache only kicks
        // in for Freeze segments anyway).
        let source_frame: Arc<Frame> = match seg.kind {
            SegmentKind::Freeze => frozen_frames.get(&seg_idx).cloned().unwrap_or_else(|| {
                // Defensive fallback: shouldn't happen because pre-decode
                // covers every Freeze, but if something went wrong (file
                // disappeared mid-preview?) use a 2x2 black so the driver
                // doesn't crash.
                Arc::new(Frame::solid(2, 2, [0, 0, 0, 255]))
            }),
            SegmentKind::Play => Arc::new(
                latest_source_frame
                    .lock()
                    .expect("source slot lock")
                    .clone()
                    .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255])),
            ),
        };

        // Webcam frame — last-frame-held past EOS per fix #20.
        let webcam_frame = Arc::new(
            latest_webcam_frame
                .lock()
                .expect("webcam slot lock")
                .clone()
                .unwrap_or_else(|| Frame::solid(2, 2, [0, 0, 0, 255])),
        );

        // Strokes for this record_time.
        let strokes = video_coach_core::stroke_replay::visible_strokes(&clip, record_time);

        // Compose + push via the identity-cached entry point (Plan #4
        // Task 3). The Freeze branch's stable Arc-pointer + identical
        // strokes hit the freeze cache for every tick after the first
        // inside the same segment.
        match video_coach_compositor::compose_tick_with_identity(
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

    /// Phase 11 Plan #1 Task 2: build-only smoke test for the preview
    /// audiomixer spine. Confirms `build_audio_mixer_and_sink` constructs
    /// without panic and the named mixer + downstream capsfilter land
    /// in the pipeline. End-to-end audio is exercised by manual play in
    /// dev (preview audio is hard to assert programmatically).
    #[test]
    fn preview_pipeline_audiomixer_constructs_without_panic() {
        // Force fakesink — no audio daemon required for this test.
        std::env::set_var("VIDEO_COACH_NO_AUDIO", "1");
        crate::init().expect("gstreamer init");

        let pipeline = gstreamer::Pipeline::new();
        build_audio_mixer_and_sink(&pipeline).expect("audiomixer spine builds");

        // Mixer present and named.
        let mixer = pipeline
            .by_name("preview_audio_mixer")
            .expect("preview_audio_mixer in pipeline");
        // Downstream capsfilter present (adv-fix #3 anchor).
        let post_caps = pipeline
            .by_name("preview_audio_post_caps")
            .expect("preview_audio_post_caps in pipeline");
        // Phantom silence src present (adv-fix #7 phantom sinkpad).
        let phantom = pipeline
            .by_name("preview_audio_phantom_silence")
            .expect("preview_audio_phantom_silence in pipeline");

        // Mixer has at least the phantom sinkpad already requested.
        let phantom_count = mixer.sink_pads().len();
        assert!(
            phantom_count >= 1,
            "audiomixer should have ≥1 sinkpad (phantom silence) immediately after construction; got {phantom_count}",
        );

        // Bind variables to silence unused warnings without dropping
        // their pipeline membership.
        let _ = (post_caps, phantom);

        // Tear down cleanly (no PAUSED transition — this is a build-only
        // smoke; real pipelines exercise PAUSED via the PreviewPipeline
        // `open()` path which is covered by the integration smokes).
        let _ = pipeline.set_state(gstreamer::State::Null);
    }
}
