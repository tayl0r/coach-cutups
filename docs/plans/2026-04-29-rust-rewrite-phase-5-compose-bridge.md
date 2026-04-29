# Phase 5: GStreamer ↔ wgpu Bridge — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prove the `appsink → wgpu → appsrc` plumbing works end-to-end. A single function `compose_two_files(source_path, webcam_path, output_path)` reads two video files, decodes them to RGBA, runs the compositor frame-by-frame, encodes the result to H.264, and writes a single `.mov`. Tested headlessly against the existing fixtures.

**Architecture:**

```
filesrc(source) → decodebin → videoconvert ! caps=RGBA → appsink ─┐
                                                                   ├→ wgpu Compositor (PiP) ─→ appsrc(RGBA)
filesrc(webcam) → decodebin → videoconvert ! caps=RGBA → appsink ─┘                            ↓
                                                                                videoconvert → vtenc_h264 → h264parse → qtmux → filesink
```

A frame-pairing task pulls frames from both appsinks, composites via the existing `Compositor::compose`, and pushes RGBA frames into appsrc. The output pipeline encodes to H.264 (no audio in Phase 5 — defer audio mixing to a later phase).

**Tech Stack:** existing `gstreamer-rs` 0.23 (`video-coach-media`) + existing `wgpu` 0.22 (`video-coach-compositor`). Adds `gstreamer-app` features already present. No new system deps.

**Scope refinements (defer to Phase 6+):**
- Audio mixing (`audiomixer` element) — Phase 5 outputs silent video.
- Stroke overlay rendering through the compositor.
- Real export with `CompilationPlan` (multi-clip concatenation, per-tag deliverables) — Phase 5 only handles ONE source + ONE webcam pair.
- Bus commands for triggering compose from the harness — Phase 5 exercises the function directly via Rust integration tests.
- Live preview — Phase 6 wires the compositor output to a Slint surface.
- Frame-rate negotiation, drop policies, A/V sync — Phase 5 uses the simpler "pull from both, drop trailing" pattern.

Phase 5's bar: **compose_two_files(source-1080p.mp4, webcam.mov, out.mov) produces a playable .mov where the webcam is visible in the bottom-right corner of the source-video frames.**

---

## Task 1: Add `video-coach-compositor` as a dependency of `video-coach-media`

The compose function lives in `video-coach-media` (it's a GStreamer pipeline). It calls into `video-coach-compositor` to do the per-frame compositing.

**Files:**
- Modify: `crates/video-coach-media/Cargo.toml`

**Step 1: Add the dep.**

```toml
[dependencies]
# ...existing entries...
video-coach-compositor = { path = "../video-coach-compositor" }
```

**Step 2: Verify `cargo build -p video-coach-media`** — clean. wgpu's transitive deps now compile as part of `video-coach-media`'s build but the existing `Cargo.lock` already has them from Phase 4.

**Step 3: Verify `cargo build -p video-coach-app --release --no-default-features`** — STILL clean. `video-coach-media` is itself an optional feature-gated dep on `video-coach-app`, so adding the compositor inside doesn't leak GPU code into release builds without `--features media`.

**Step 4: Commit.**

```bash
git add crates/video-coach-media/Cargo.toml Cargo.lock
git commit -m "build(media): depend on video-coach-compositor for the bridge"
```

---

## Task 2: `compose_two_files` skeleton + integration test scaffolding

**Files:**
- Create: `crates/video-coach-media/src/compose.rs`
- Modify: `crates/video-coach-media/src/lib.rs`

**Step 1: Skeleton.**

```rust
// crates/video-coach-media/src/compose.rs
use std::path::PathBuf;
use thiserror::Error;
use crate::recording::RecordingError;

#[derive(Debug, Error)]
pub enum ComposeError {
    #[error("compositor: {0}")]
    Compositor(#[from] video_coach_compositor::CompositorError),
    #[error("recording layer: {0}")]
    Recording(#[from] RecordingError),
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("appsink/appsrc: {0}")]
    AppFlow(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("source factory: {0}")]
    Source(#[from] gstreamer::glib::BoolError),
}

/// Compose two input video files (source + webcam) into a single output .mov.
/// Phase 5 ignores audio and produces silent video. Output codec: H.264.
pub fn compose_two_files(
    _source: PathBuf,
    _webcam: PathBuf,
    _output: PathBuf,
) -> Result<(), ComposeError> {
    // Real implementation lands in Tasks 3 and 4.
    Err(ComposeError::AppFlow("not implemented yet".into()))
}
```

**Step 2: Wire into `lib.rs`.**

```rust
pub mod compose;
```

**Step 3: Empty integration test scaffolding.**

Create `crates/video-coach-media/tests/compose_two_files.rs`:

```rust
#![cfg(feature = "media")]

use std::path::PathBuf;

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

#[test]
#[ignore = "not implemented yet — Task 4 enables"]
fn compose_source_plus_webcam_produces_playable_mov() {
    let tmp_dir = tempfile::tempdir().unwrap();
    let out = tmp_dir.path().join("composed.mov");
    video_coach_media::compose::compose_two_files(
        fixture("source-1080p.mp4"),
        fixture("webcam.mov"),
        out.clone(),
    ).unwrap();
    let metadata = std::fs::metadata(&out).unwrap();
    assert!(metadata.len() > 100_000, "got {} bytes", metadata.len());
}
```

**Step 4: Verify build clean.**

```bash
cargo build -p video-coach-media --features media
cargo test --workspace
cargo fmt --check
cargo clippy --workspace --all-targets --features media -- -D warnings
```

Test count unchanged (the new test is `#[ignore]`d). 60 tests on macOS with `--features media`.

**Step 5: Commit.**

```bash
git add crates/video-coach-media/src/compose.rs crates/video-coach-media/src/lib.rs crates/video-coach-media/tests/compose_two_files.rs
git commit -m "feat(media): compose_two_files skeleton + integration test scaffolding"
```

---

## Task 3: Build the GStreamer pipeline (no compositing yet — passthrough source to encoder)

Before tackling the dual-input + compositor part, get a single-input passthrough working. Read source video, encode to .mov via H.264, with appsink + appsrc in the loop. This proves the GStreamer ↔ Rust frame plumbing works.

**Files:**
- Modify: `crates/video-coach-media/src/compose.rs`

**Step 1: Build the single-input passthrough pipeline.**

```rust
use gstreamer::prelude::*;
use gstreamer_app::{AppSink, AppSrc};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const RGBA_CAPS: &str = "video/x-raw,format=RGBA";

fn make_or(name: &str) -> Result<gstreamer::Element, ComposeError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| ComposeError::MissingElement(name.into()))
}

/// Single-input passthrough: source video → RGBA appsink → RGBA appsrc → encode → file.
/// Used as a stepping stone before the dual-input compose.
pub(crate) fn passthrough_one_file(
    source: &Path,
    output: &Path,
) -> Result<(), ComposeError> {
    crate::init().map_err(|e| ComposeError::Recording(e.into()))?;

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let pipeline = gstreamer::Pipeline::new();

    // INPUT: filesrc → decodebin → videoconvert → caps RGBA → appsink
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .property("location", source.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| ComposeError::MissingElement("filesrc".into()))?;
    let decodebin = make_or("decodebin")?;
    let videoconvert_in = make_or("videoconvert")?;
    let capsfilter_in = gstreamer::ElementFactory::make("capsfilter")
        .property("caps", &gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ComposeError::MissingElement("capsfilter".into()))?;
    let appsink = AppSink::builder()
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .sync(false)
        .build();

    // OUTPUT: appsrc → videoconvert → encoder → h264parse → qtmux → filesink
    let appsrc = AppSrc::builder()
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    let videoconvert_out = make_or("videoconvert")?;
    let video_enc = pick_h264_encoder()?;
    let h264parse = make_or("h264parse")?;
    let qtmux = make_or("qtmux")?;
    let filesink = gstreamer::ElementFactory::make("filesink")
        .property("location", output.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| ComposeError::MissingElement("filesink".into()))?;

    pipeline.add_many([
        &filesrc, &decodebin, &videoconvert_in, &capsfilter_in,
        appsink.upcast_ref(),
        appsrc.upcast_ref(),
        &videoconvert_out, &video_enc, &h264parse, &qtmux, &filesink,
    ]).map_err(|e| ComposeError::AppFlow(format!("add: {e}")))?;

    // Static links upstream of decodebin's dynamic pads.
    filesrc.link(&decodebin).map_err(|e| ComposeError::AppFlow(format!("filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([&videoconvert_in, &capsfilter_in])
        .map_err(|e| ComposeError::AppFlow(format!("link videoconvert_in: {e}")))?;
    capsfilter_in.link(appsink.upcast_ref())
        .map_err(|e| ComposeError::AppFlow(format!("link capsfilter→appsink: {e}")))?;

    // Static links downstream of appsrc.
    gstreamer::Element::link_many([
        appsrc.upcast_ref(),
        &videoconvert_out, &video_enc, &h264parse, &qtmux, &filesink,
    ]).map_err(|e| ComposeError::AppFlow(format!("link out chain: {e}")))?;

    // Dynamic decodebin → videoconvert_in (only when video pad appears).
    let videoconvert_in_sink = videoconvert_in.static_pad("sink")
        .ok_or_else(|| ComposeError::AppFlow("videoconvert_in has no sink pad".into()))?;
    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else { return };
        let Some(structure) = caps.structure(0) else { return };
        if !structure.name().to_string().starts_with("video/") {
            return;
        }
        if pad.link(&videoconvert_in_sink).is_err() {
            tracing::warn!(target: "compose", "failed to link decoded video pad");
        }
    });

    // Frame loop: pull RGBA frame from appsink, push to appsrc, repeat until EOS.
    let appsrc_for_loop = appsrc.clone();
    let pts_state = Arc::new(Mutex::new(0_u64));
    let frame_duration_ns = (1_000_000_000.0_f64 / 30.0) as u64; // assume 30fps; overridden below if caps say otherwise

    appsink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                let buffer = sample.buffer().ok_or(gstreamer::FlowError::Error)?;
                let map = buffer.map_readable().map_err(|_| gstreamer::FlowError::Error)?;

                // Build a new buffer with the same RGBA bytes + an explicit PTS so
                // the encoder sees a monotonic timeline. We assume 30fps for the
                // output regardless of source rate (Phase 6 will negotiate).
                let mut out_buf = gstreamer::Buffer::with_size(map.size())
                    .map_err(|_| gstreamer::FlowError::Error)?;
                {
                    let buf_mut = out_buf.get_mut().ok_or(gstreamer::FlowError::Error)?;
                    let mut out_map = buf_mut.map_writable().map_err(|_| gstreamer::FlowError::Error)?;
                    out_map.copy_from_slice(&map);
                    drop(out_map);
                    let mut pts = pts_state.lock().expect("pts state lock");
                    buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(*pts));
                    buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(frame_duration_ns));
                    *pts += frame_duration_ns;
                }

                appsrc_for_loop
                    .push_buffer(out_buf)
                    .map_err(|_| gstreamer::FlowError::Error)?;
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .eos(move |_sink| {
                let _ = appsrc_for_loop.end_of_stream();
            })
            .build(),
    );

    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| ComposeError::StateChange(format!("PLAYING: {e:?}")))?;

    // Wait for EOS or error on the bus.
    let bus = pipeline.bus().expect("pipeline bus");
    let deadline = std::time::Instant::now() + Duration::from_secs(120);
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(ComposeError::AppFlow("timeout waiting for EOS".into()));
        }
        if let Some(msg) = bus.timed_pop_filtered(
            gstreamer::ClockTime::from_nseconds(remaining.as_nanos() as u64),
            &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
        ) {
            match msg.view() {
                gstreamer::MessageView::Eos(_) => break,
                gstreamer::MessageView::Error(err) => {
                    pipeline.set_state(gstreamer::State::Null).ok();
                    return Err(ComposeError::AppFlow(format!("pipeline error: {err}")));
                }
                _ => continue,
            }
        }
    }

    pipeline
        .set_state(gstreamer::State::Null)
        .map_err(|e| ComposeError::StateChange(format!("NULL: {e:?}")))?;
    Ok(())
}

fn pick_h264_encoder() -> Result<gstreamer::Element, ComposeError> {
    for name in ["vtenc_h264", "mfh264enc", "vaapih264enc", "nvh264enc", "x264enc"] {
        if let Ok(elem) = make_or(name) {
            return Ok(elem);
        }
    }
    Err(ComposeError::MissingElement("h264 encoder (any)".into()))
}
```

**Step 2: Test the passthrough as a stepping stone.**

Append to `tests/compose_two_files.rs`:

```rust
#[test]
fn passthrough_source_to_mov() {
    let tmp_dir = tempfile::tempdir().unwrap();
    let out = tmp_dir.path().join("passthrough.mov");
    video_coach_media::compose::passthrough_one_file(
        &fixture("source-1080p.mp4"),
        &out,
    ).unwrap();
    let metadata = std::fs::metadata(&out).unwrap();
    assert!(metadata.len() > 100_000, "passthrough output too small: {} bytes", metadata.len());
}
```

Note: `passthrough_one_file` is `pub(crate)`; this test lives inside an integration test that lives outside the crate. Either make it `pub` for the test, OR add the test inside `compose.rs` as a `#[cfg(test)] mod tests`. Choose the latter to keep the API surface tight — only `compose_two_files` is the public Phase 5 API.

**Step 3: Run.** Locally on macOS this should produce a real .mov in ~3-5 seconds (60s of 1080p video at 30fps).

**Step 4: Commit.**

```bash
git add crates/video-coach-media/src/compose.rs crates/video-coach-media/tests/compose_two_files.rs
git commit -m "feat(media): single-input passthrough through appsink → appsrc"
```

---

## Task 4: Add the wgpu compositor in the middle (TWO inputs → composite → encode)

Replace passthrough with the dual-input flow. The frame-pairing logic: maintain a `Mutex<Option<Frame>>` for each source's most-recent frame. The "driver" appsink (source video) pushes one composed output for each frame it emits, using the latest webcam frame available (or a black placeholder if none yet).

**Files:**
- Modify: `crates/video-coach-media/src/compose.rs`

**Step 1: Build the dual-input pipeline.** Implement `compose_two_files` proper:

- Two filesrc → decodebin → videoconvert → caps=RGBA → appsink chains (separate pipelines or shared? **Use a single pipeline with two source bins** — keeps the bus + state changes coordinated).
- Two `Arc<Mutex<Option<video_coach_compositor::Frame>>>` slots, one per source.
- Webcam appsink callback: lock its slot and replace.
- Source appsink callback ("driver"): lock both slots, run `compositor.compose(&source, &webcam_or_placeholder)`, push the composited Frame into appsrc with monotonic PTS.
- The compositor instance is held in an `Arc` shared between the two callbacks.

Sketch:

```rust
pub fn compose_two_files(
    source: PathBuf,
    webcam: PathBuf,
    output: PathBuf,
) -> Result<(), ComposeError> {
    crate::init().map_err(|e| ComposeError::Recording(e.into()))?;
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // ONE compositor for the whole compose.
    let compositor = video_coach_compositor::Compositor::new_headless()?;
    let compositor = Arc::new(compositor);

    let pipeline = gstreamer::Pipeline::new();

    // Helper to build a "decode-to-RGBA" subgraph and add it to the pipeline.
    fn build_input_chain(
        pipeline: &gstreamer::Pipeline,
        path: &Path,
        label: &'static str,
    ) -> Result<AppSink, ComposeError> {
        // ...filesrc + decodebin + videoconvert + capsfilter + appsink
        // ...add and link, plus the dynamic decodebin pad-added handler
        // returns the AppSink so the caller can attach callbacks.
    }

    let source_sink = build_input_chain(&pipeline, &source, "source")?;
    let webcam_sink = build_input_chain(&pipeline, &webcam, "webcam")?;

    // OUTPUT chain (same as Task 3 passthrough).
    let appsrc = AppSrc::builder()
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    // ...videoconvert + h264 encoder + h264parse + qtmux + filesink, add+link.

    // Frame slots. The webcam slot starts as None; the source-driver
    // synthesizes a black frame of the source's dimensions if no webcam frame
    // has arrived yet (rare in practice — webcams decode fast).
    let latest_webcam: Arc<Mutex<Option<video_coach_compositor::Frame>>> = Arc::new(Mutex::new(None));
    let pts_state = Arc::new(Mutex::new(0_u64));
    let frame_duration_ns = 33_333_333_u64; // 30fps

    let lw = latest_webcam.clone();
    webcam_sink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                let frame = sample_to_rgba_frame(&sample)
                    .ok_or(gstreamer::FlowError::Error)?;
                *lw.lock().expect("webcam slot lock") = Some(frame);
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .build(),
    );

    let lw2 = latest_webcam.clone();
    let comp = compositor.clone();
    let appsrc_drive = appsrc.clone();
    let pts_drive = pts_state.clone();
    source_sink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                let src_frame = sample_to_rgba_frame(&sample)
                    .ok_or(gstreamer::FlowError::Error)?;
                let webcam_frame = lw2.lock().expect("webcam slot")
                    .clone()
                    .unwrap_or_else(|| video_coach_compositor::Frame::solid(2, 2, [0,0,0,255]));
                let composed = comp
                    .compose(&src_frame, &webcam_frame)
                    .map_err(|_| gstreamer::FlowError::Error)?;

                let mut out_buf = gstreamer::Buffer::with_size(composed.pixels.len())
                    .map_err(|_| gstreamer::FlowError::Error)?;
                {
                    let buf_mut = out_buf.get_mut().ok_or(gstreamer::FlowError::Error)?;
                    let mut out_map = buf_mut.map_writable().map_err(|_| gstreamer::FlowError::Error)?;
                    out_map.copy_from_slice(&composed.pixels);
                    drop(out_map);
                    let mut pts = pts_drive.lock().expect("pts");
                    buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(*pts));
                    buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(frame_duration_ns));
                    *pts += frame_duration_ns;
                }
                appsrc_drive.push_buffer(out_buf)
                    .map_err(|_| gstreamer::FlowError::Error)?;
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .eos(move |_sink| {
                let _ = appsrc_drive.end_of_stream();
            })
            .build(),
    );

    // PLAY + bus wait + NULL — same as Task 3.
    // ...
    Ok(())
}

fn sample_to_rgba_frame(sample: &gstreamer::Sample) -> Option<video_coach_compositor::Frame> {
    let buffer = sample.buffer()?;
    let caps = sample.caps()?;
    let structure = caps.structure(0)?;
    let width = structure.get::<i32>("width").ok()? as u32;
    let height = structure.get::<i32>("height").ok()? as u32;
    let map = buffer.map_readable().ok()?;
    Some(video_coach_compositor::Frame::new(width, height, map.to_vec()))
}
```

**Step 2: Source-rate determination.** The hardcoded 30fps assumption may not match the source video. Read the framerate from the source caps and use it for `frame_duration_ns`. If unset, fall back to 30. Add an inline `tracing::info!(target: "compose", event = "compose.framerate", fps = ...)` for visibility.

**Step 3: De-`#[ignore]` the integration test from Task 2.** Remove the `#[ignore]` attribute. Run:

```bash
cargo test -p video-coach-media --features media --test compose_two_files
```

Expected: PASS in ~10-30s (depends on CPU and which encoder gets picked). Output `.mov` should be ≥100 KB and play back in any player with the webcam visible in the bottom-right corner of the source video.

**Step 4: Verify other quality gates.**

```bash
cargo fmt --check
cargo clippy --workspace --all-targets --features media -- -D warnings
cargo test --workspace
cargo test --workspace --features media
cargo build -p video-coach-app --release --no-default-features
```

All clean. Test count: the `compose_source_plus_webcam_produces_playable_mov` test is no longer ignored, so total media-feature test count is 60 + 1 + 1 (passthrough from Task 3) = 62.

**Step 5: Commit.**

```bash
git add crates/video-coach-media/src/compose.rs
git commit -m "feat(media): compose_two_files — appsink + wgpu PiP + appsrc → encoder"
```

---

## Task 5: Smoke-test the output visually

Manual verification step (no code). Open the output `.mov` produced by the integration test and confirm:

- The video plays in QuickTime / VLC.
- Source video plays normally.
- The webcam appears as a small overlay in the bottom-right corner with the v1's 2.2% margin.
- No A/V desync (Phase 5 has no audio, so this just means video plays smoothly).
- Duration approximates the SOURCE video's duration (60s for `source-1080p.mp4`), capped by whichever stream EOSes first.

If anything looks wrong, capture a screenshot and pause for guidance.

The test in Task 4 already asserts file-size > 100 KB but a real human eye is the only check that the PiP is visible. Phase 5 explicitly accepts manual verification at this step; Phase 6 will introduce automated visual diffs against a known-good still.

---

## Phase 5 exit criteria

- All tasks committed.
- `cargo test -p video-coach-media --features media` green locally; `compose_source_plus_webcam_produces_playable_mov` produces a real `.mov` ≥100 KB.
- Manual eyeball check (Task 5) confirms PiP overlay is visible in the output.
- `cargo build -p video-coach-app --release --no-default-features` still clean (compositor crate is reachable through the optional `media` feature only).
- CI matrix green on all 3 OSes; `media-tests` green on Linux (the new test runs there too because it's gated `#[cfg(feature = "media")]`).

When this is green, Phase 6 starts: stroke overlay rendering through the compositor, plus audio mixing in the compose pipeline.
