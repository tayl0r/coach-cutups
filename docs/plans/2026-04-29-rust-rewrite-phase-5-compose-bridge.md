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

## Task 1: Add `video-coach-compositor` as an OPTIONAL feature-gated dep of `video-coach-media`

The compose function lives in `video-coach-media` (it's a GStreamer pipeline). It calls into `video-coach-compositor` to do the per-frame compositing. The dep MUST be optional and gated by the `media` feature, otherwise every workspace build pulls wgpu unconditionally and the no-default-features baseline regresses.

**Files:**
- Modify: `crates/video-coach-media/Cargo.toml`

**Step 1: Add the optional dep AND gate it on `media`.**

```toml
[features]
# Phase 4 added a stub `media = []`. Phase 5 expands it: enabling `media`
# also pulls in video-coach-compositor (and transitively wgpu).
media = ["dep:video-coach-compositor"]

[dependencies]
# ...existing entries (gstreamer-rs, thiserror, tracing, etc.)...
video-coach-compositor = { path = "../video-coach-compositor", optional = true }
```

**Step 2: Verify the feature gating actually works.**

```bash
cargo build -p video-coach-media          # NO media feature; should NOT compile compositor or wgpu
cargo build -p video-coach-media --features media   # media feature; SHOULD pull in compositor + wgpu
```

The first build's compile output should NOT show `video-coach-compositor` or `wgpu` lines. The second build SHOULD compile them.

**Step 3: Verify the no-default-features baseline holds.**

```bash
cargo build -p video-coach-app --release --no-default-features
nm target/release/video-coach-app | grep -iE "wgpu|gstreamer" | head -3
```

Expected: build clean, `nm` output empty. If anything matches, the gating is broken — pause and diagnose.

**Step 4: Commit.**

```bash
git add crates/video-coach-media/Cargo.toml Cargo.lock
git commit -m "build(media): depend on video-coach-compositor (optional, media-feature-gated)"
```

---

## Task 2: `compose_two_files` skeleton + integration test scaffolding

**Files:**
- Create: `crates/video-coach-media/src/compose.rs`
- Modify: `crates/video-coach-media/src/lib.rs`

**Step 1: Skeleton.**

```rust
// crates/video-coach-media/src/compose.rs
//
// The compose pipeline pulls in video-coach-compositor + wgpu, both of which
// are feature-gated via `media`. Gate the entire module so non-media builds
// don't try to import a crate that isn't a dep.
#![cfg(feature = "media")]

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

**Step 2: Wire into `lib.rs` (also feature-gated).**

```rust
#[cfg(feature = "media")]
pub mod compose;
```

**Step 3: No integration test file in this task.**

The integration test file would force `compose_two_files` and `passthrough_one_file` to be `pub` (integration tests run as a separate crate and can't see `pub(crate)` items). We want the public API surface tight — only `compose_two_files` should be `pub`. Place all tests inline as `#[cfg(test)] mod tests` blocks within `compose.rs` so they can call `pub(crate)` helpers.

Tasks 3 and 4 add the inline tests; this task just lays the skeleton.

**Step 4: Verify build clean.**

```bash
cargo build -p video-coach-media --features media
cargo test --workspace
cargo fmt --check
cargo clippy --workspace --all-targets --features media -- -D warnings
```

Test count unchanged. 60 tests on macOS with `--features media` (no new tests yet).

**Step 5: Commit.**

```bash
git add crates/video-coach-media/src/compose.rs crates/video-coach-media/src/lib.rs
git commit -m "feat(media): compose_two_files skeleton (skeleton only — Tasks 3+4 enable)"
```

---

## Task 3: Build the GStreamer pipeline (no compositing yet — passthrough source to encoder)

Before tackling the dual-input + compositor part, get a single-input passthrough working. Read source video, encode to .mov via H.264, with appsink + appsrc in the loop. This proves the GStreamer ↔ Rust frame plumbing works.

**Files:**
- Modify: `crates/video-coach-media/src/compose.rs`

**Critical correctness rules** (caught by Phase 5 review — every one of these is a real bug if violated):

1. **Audio pads MUST be linked to a fakesink, not just `return`-ed past.** Decoded audio with no downstream sink causes GStreamer to fail with "Internal data flow error" — silently fatal.
2. **`AppSrc::push_buffer` and `AppSrc::end_of_stream` are called from DIFFERENT closures (`new_sample` and `eos`).** Both closures `move` their captures. Clone `appsrc` BEFORE each closure — a single `let appsrc_drive = appsrc.clone()` used in both is a compile error (already moved).
3. **Bus loop must NOT break on the first EOS message.** With multiple appsinks (Task 4), each EOSes independently. Track EOS via an `Arc<AtomicBool>` flag set in the appsrc-driving eos handler, and break only when the FILESINK reaches EOS (or when the AtomicBool is set + a follow-up bus quiet period). Single-input Task 3 has only one EOS so this is dormant, but write the code right the first time.
4. **Framerate must be read from the source's negotiated caps, not hardcoded.** A 60fps source under-timed at 30fps produces a 2x-slow output.

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

    // Dynamic decodebin → videoconvert_in (video) or fakesink (audio).
    // Audio pads with no downstream sink are FATAL — GStreamer aborts the
    // pipeline with "Internal data flow error". Always attach a fakesink.
    let videoconvert_in_sink = videoconvert_in.static_pad("sink")
        .ok_or_else(|| ComposeError::AppFlow("videoconvert_in has no sink pad".into()))?;
    let pipeline_weak = pipeline.downgrade();
    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else { return };
        let Some(structure) = caps.structure(0) else { return };
        let media = structure.name().to_string();
        if media.starts_with("video/") {
            if pad.link(&videoconvert_in_sink).is_err() {
                tracing::warn!(target: "compose", "failed to link decoded video pad");
            }
        } else {
            // Audio (or anything else) — drain into a fakesink so the
            // pipeline doesn't stall.
            let Some(pipeline) = pipeline_weak.upgrade() else { return };
            let fakesink = match gstreamer::ElementFactory::make("fakesink")
                .property("sync", false)
                .property("async", false)
                .build()
            {
                Ok(f) => f,
                Err(e) => {
                    tracing::warn!(target: "compose", error = %e, "failed to create fakesink");
                    return;
                }
            };
            if pipeline.add(&fakesink).is_err() { return; }
            if fakesink.sync_state_with_parent().is_err() { return; }
            let Some(sink_pad) = fakesink.static_pad("sink") else { return };
            if pad.link(&sink_pad).is_err() {
                tracing::warn!(target: "compose", media = %media, "failed to drain non-video pad");
            }
        }
    });

    // Frame loop: pull RGBA frame from appsink, push to appsrc, repeat until EOS.
    // CLONE appsrc separately for each closure — single shared variable would
    // be moved by `new_sample` and `eos` couldn't capture it.
    let appsrc_drive = appsrc.clone();
    let appsrc_eos = appsrc.clone();
    let pts_state = Arc::new(Mutex::new(0_u64));
    let frame_duration_state = Arc::new(Mutex::new(33_333_333_u64)); // default 30fps; replaced on first frame
    let frame_duration_set = frame_duration_state.clone();
    let frame_duration_read = frame_duration_state.clone();

    // Used by Task 4's multi-EOS handling and exposed via the bus loop.
    let drive_eos_seen = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let drive_eos_clone = drive_eos_seen.clone();

    appsink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;

                // Read framerate from the negotiated sample caps on the FIRST
                // frame. The capsfilter forces RGBA but width/height/framerate
                // come from upstream caps negotiation.
                if let Some(caps) = sample.caps() {
                    if let Some(structure) = caps.structure(0) {
                        if let Ok(fr) = structure.get::<gstreamer::Fraction>("framerate") {
                            let num = fr.numer() as u64;
                            let den = fr.denom() as u64;
                            if num > 0 {
                                let dur = 1_000_000_000_u64 * den / num;
                                *frame_duration_set.lock().expect("fd lock") = dur;
                            }
                        }
                    }
                }

                let buffer = sample.buffer().ok_or(gstreamer::FlowError::Error)?;
                let in_map = buffer.map_readable().map_err(|_| gstreamer::FlowError::Error)?;

                let mut out_buf = gstreamer::Buffer::with_size(in_map.size())
                    .map_err(|_| gstreamer::FlowError::Error)?;
                {
                    let buf_mut = out_buf.get_mut().ok_or(gstreamer::FlowError::Error)?;
                    let mut out_map = buf_mut.map_writable().map_err(|_| gstreamer::FlowError::Error)?;
                    out_map.copy_from_slice(&in_map);
                    drop(out_map);
                    let frame_duration_ns = *frame_duration_read.lock().expect("fd read lock");
                    let mut pts = pts_state.lock().expect("pts state lock");
                    buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(*pts));
                    buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(frame_duration_ns));
                    *pts += frame_duration_ns;
                }

                appsrc_drive
                    .push_buffer(out_buf)
                    .map_err(|_| gstreamer::FlowError::Error)?;
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .eos(move |_sink| {
                let _ = appsrc_eos.end_of_stream();
                drive_eos_clone.store(true, std::sync::atomic::Ordering::SeqCst);
            })
            .build(),
    );

    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| ComposeError::StateChange(format!("PLAYING: {e:?}")))?;

    // Wait for the FILESINK to receive EOS (i.e. the muxed file is fully
    // written). EOS messages on the bus come from EVERY appsink and the
    // filesink — break only on the filesink's, not the first one. With
    // multiple input chains (Task 4) the first EOS would be the SHORTER
    // input, truncating the output.
    let bus = pipeline.bus().expect("pipeline bus");
    let filesink_name = filesink.name();
    let deadline = std::time::Instant::now() + Duration::from_secs(180);
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            pipeline.set_state(gstreamer::State::Null).ok();
            return Err(ComposeError::AppFlow("timeout waiting for filesink EOS".into()));
        }
        if let Some(msg) = bus.timed_pop_filtered(
            gstreamer::ClockTime::from_nseconds(remaining.as_nanos() as u64),
            &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
        ) {
            match msg.view() {
                gstreamer::MessageView::Eos(eos) => {
                    if let Some(src) = eos.src() {
                        if src.name() == filesink_name {
                            break;
                        }
                    }
                    // EOS from an appsink or other element — keep waiting.
                }
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

/// Build a `filesrc → decodebin → videoconvert → caps=RGBA → appsink` subgraph,
/// add it to `pipeline`, and return the AppSink so the caller can attach
/// `set_callbacks`. Audio (or any non-video) pads from decodebin are routed to
/// fakesinks so the pipeline doesn't stall on unlinked decoder outputs.
fn build_input_chain(
    pipeline: &gstreamer::Pipeline,
    path: &Path,
    label: &'static str,
) -> Result<AppSink, ComposeError> {
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .name(format!("{label}-filesrc"))
        .property("location", path.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| ComposeError::MissingElement("filesrc".into()))?;
    let decodebin = gstreamer::ElementFactory::make("decodebin")
        .name(format!("{label}-decodebin"))
        .build()
        .map_err(|_| ComposeError::MissingElement("decodebin".into()))?;
    let videoconvert = gstreamer::ElementFactory::make("videoconvert")
        .name(format!("{label}-videoconvert"))
        .build()
        .map_err(|_| ComposeError::MissingElement("videoconvert".into()))?;
    let capsfilter = gstreamer::ElementFactory::make("capsfilter")
        .name(format!("{label}-capsfilter"))
        .property("caps", &gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ComposeError::MissingElement("capsfilter".into()))?;
    let appsink = AppSink::builder()
        .name(format!("{label}-appsink"))
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .sync(false)
        .build();

    pipeline
        .add_many([&filesrc, &decodebin, &videoconvert, &capsfilter, appsink.upcast_ref()])
        .map_err(|e| ComposeError::AppFlow(format!("{label}: add chain: {e}")))?;
    filesrc
        .link(&decodebin)
        .map_err(|e| ComposeError::AppFlow(format!("{label}: filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([&videoconvert, &capsfilter])
        .map_err(|e| ComposeError::AppFlow(format!("{label}: videoconvert→capsfilter: {e}")))?;
    capsfilter
        .link(appsink.upcast_ref())
        .map_err(|e| ComposeError::AppFlow(format!("{label}: capsfilter→appsink: {e}")))?;

    // Dynamic decodebin → videoconvert (video) or fakesink (audio).
    // Capture each chain's OWN videoconvert sink pad — closing over the
    // wrong one would cross-link the chains.
    let videoconvert_sink = videoconvert
        .static_pad("sink")
        .ok_or_else(|| ComposeError::AppFlow(format!("{label}: videoconvert has no sink pad")))?;
    let pipeline_weak = pipeline.downgrade();
    decodebin.connect_pad_added(move |_dbin, pad| {
        let Some(caps) = pad.current_caps() else { return };
        let Some(structure) = caps.structure(0) else { return };
        let media = structure.name().to_string();
        if media.starts_with("video/") {
            if pad.link(&videoconvert_sink).is_err() {
                tracing::warn!(target: "compose", chain = label, "failed to link decoded video pad");
            }
        } else {
            // Audio (etc.) — drain into a fakesink so the pipeline doesn't
            // fail with "Internal data flow error".
            let Some(pipeline) = pipeline_weak.upgrade() else { return };
            let fakesink = match gstreamer::ElementFactory::make("fakesink")
                .name(format!("{label}-audio-fakesink"))
                .property("sync", false)
                .property("async", false)
                .build()
            {
                Ok(f) => f,
                Err(e) => {
                    tracing::warn!(target: "compose", chain = label, error = %e, "failed to create fakesink");
                    return;
                }
            };
            if pipeline.add(&fakesink).is_err() { return; }
            if fakesink.sync_state_with_parent().is_err() { return; }
            let Some(sink_pad) = fakesink.static_pad("sink") else { return };
            if pad.link(&sink_pad).is_err() {
                tracing::warn!(target: "compose", chain = label, media = %media, "failed to drain non-video pad");
            }
        }
    });

    Ok(appsink)
}
```

**Step 2: Test the passthrough as a stepping stone (inline in `compose.rs`).**

Append to `compose.rs` an inline `#[cfg(test)] mod tests` block — do NOT use a file under `tests/`. Inline tests can call `pub(crate)` helpers; integration tests (separate crate) can't.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../fixtures");
        p.push(name);
        p
    }

    #[test]
    fn passthrough_source_to_mov() {
        let tmp_dir = tempfile::tempdir().unwrap();
        let out = tmp_dir.path().join("passthrough.mov");
        passthrough_one_file(
            &fixture("source-1080p.mp4"),
            &out,
        ).unwrap();
        let metadata = std::fs::metadata(&out).unwrap();
        assert!(metadata.len() > 100_000, "passthrough output too small: {} bytes", metadata.len());
    }
}
```

Add `tempfile = "3"` to `[dev-dependencies]` in `crates/video-coach-media/Cargo.toml` if not already present (Phase 3 added it for the recording test, so probably already there — verify).

**Step 3: Run.** Locally on macOS this should produce a real .mov in ~3-5 seconds (60s of 1080p video at 30fps via VideoToolbox).

**Step 4: Commit.**

```bash
git add crates/video-coach-media/src/compose.rs crates/video-coach-media/tests/compose_two_files.rs
git commit -m "feat(media): single-input passthrough through appsink → appsrc"
```

---

## Task 4: Add the wgpu compositor in the middle (TWO inputs → composite → encode)

Replace passthrough with the dual-input flow. The frame-pairing logic: maintain a `Mutex<Option<Frame>>` for each source's most-recent frame. The "driver" appsink (source video) pushes one composed output for each frame it emits, using the latest webcam frame available (or a small black placeholder if none yet).

**Files:**
- Modify: `crates/video-coach-media/src/compose.rs`

**Critical correctness rules** carried over from Task 3 — review the same numbered list before coding:

1. Audio pads → fakesink (BOTH input chains have decodebin; both need it).
2. `appsrc` cloned separately for each closure that captures it (`new_sample` and `eos`).
3. Bus loop breaks ONLY on filesink EOS, never on the first appsink EOS — the shorter input would truncate the output.
4. Framerate read from negotiated caps on the FIRST sample of the source-driver appsink.

**Additional Task 4-specific rules:**

5. `Compositor::new_headless()` returns a `Compositor` that uses an internal wgpu device. It does `pollster::block_on` internally — do NOT call `compose_two_files` from inside an async runtime (panic). Phase 5's tests are sync; Phase 6 wraps it in `spawn_blocking` if needed.
6. `Compositor::compose` blocks the calling thread for ~1-5ms on Metal/Vulkan, ~10-50ms on lavapipe. Called from GStreamer's streaming thread, this throttles the source's pull rate. CI on lavapipe will be slow — accept it; don't try to async-ify the compositor in Phase 5.
7. The webcam input may EOS before the source (fixtures: 17s vs 60s). After webcam EOS, the source-driver continues using the LAST received webcam frame. The webcam appsink's `new_sample` callback simply stops being called — no special handling needed.

**Step 1: Build the dual-input pipeline.** Implement `compose_two_files` proper.

The structure mirrors Task 3's passthrough but with TWO input chains and a compositor in the middle. Use a single `Pipeline` with two source bins so bus messages + state changes stay coordinated.

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

    // ONE compositor for the whole compose. Held in an Arc so both
    // appsink closures can share it.
    let compositor = Arc::new(video_coach_compositor::Compositor::new_headless()?);
    let pipeline = gstreamer::Pipeline::new();

    // Build both input chains. Each returns the AppSink so the caller
    // attaches the right callbacks below.
    let source_sink = build_input_chain(&pipeline, &source, "src")?;
    let webcam_sink = build_input_chain(&pipeline, &webcam, "cam")?;

    // OUTPUT chain (same as Task 3 passthrough — appsrc + videoconvert + encoder + parse + qtmux + filesink, add and link).
    let appsrc = AppSrc::builder()
        .caps(&gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    // ...build videoconvert_out, video_enc (pick_h264_encoder()), h264parse, qtmux, filesink with the output path
    // ...pipeline.add_many([appsrc.upcast_ref(), &videoconvert_out, &video_enc, &h264parse, &qtmux, &filesink]).map_err(...)?;
    // ...gstreamer::Element::link_many([appsrc.upcast_ref(), &videoconvert_out, &video_enc, &h264parse, &qtmux, &filesink]).map_err(...)?;
    let filesink_name_for_bus = filesink.name();

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

    // CLONE appsrc separately for each closure — single shared variable
    // would be moved by `new_sample` and `eos` couldn't capture it.
    let lw2 = latest_webcam.clone();
    let comp = compositor.clone();
    let appsrc_drive = appsrc.clone();
    let appsrc_eos = appsrc.clone();
    let pts_drive = pts_state.clone();
    let frame_duration_state = Arc::new(Mutex::new(33_333_333_u64)); // 30fps default
    let frame_duration_set = frame_duration_state.clone();
    let frame_duration_read = frame_duration_state.clone();
    source_sink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;

                // Read framerate from negotiated caps on the FIRST frame.
                if let Some(caps) = sample.caps() {
                    if let Some(structure) = caps.structure(0) {
                        if let Ok(fr) = structure.get::<gstreamer::Fraction>("framerate") {
                            let num = fr.numer() as u64;
                            let den = fr.denom() as u64;
                            if num > 0 {
                                let dur = 1_000_000_000_u64 * den / num;
                                *frame_duration_set.lock().expect("fd set") = dur;
                            }
                        }
                    }
                }

                let src_frame = sample_to_rgba_frame(&sample)
                    .ok_or(gstreamer::FlowError::Error)?;
                let webcam_frame = lw2.lock().expect("webcam slot")
                    .clone()
                    .unwrap_or_else(|| video_coach_compositor::Frame::solid(2, 2, [0, 0, 0, 255]));
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
                    let frame_duration_ns = *frame_duration_read.lock().expect("fd read");
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
                // Source EOS — that's the signal that the OUTPUT is done.
                // Webcam EOS (which fires earlier with the 17s fixture) is
                // intentionally ignored; the source-driver continues using
                // the last received webcam frame until the source itself
                // EOSes.
                let _ = appsrc_eos.end_of_stream();
            })
            .build(),
    );

    // Bus loop: identical to Task 3 — break ONLY on filesink EOS, not on
    // appsink EOS (which fires per-input). With two appsinks, breaking on
    // first-EOS would truncate the output at the shorter input's duration.
    // Use `filesink.name()` captured into `filesink_name_for_bus` above.
    // ...same bus loop body as Task 3...

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

**Step 3: Add the dual-input test (inline, alongside Task 3's `passthrough_source_to_mov`).**

In the existing `#[cfg(test)] mod tests` block in `compose.rs`:

```rust
#[test]
fn compose_source_plus_webcam_produces_playable_mov() {
    let tmp_dir = tempfile::tempdir().unwrap();
    let out = tmp_dir.path().join("composed.mov");
    super::compose_two_files(
        fixture("source-1080p.mp4"),
        fixture("webcam.mov"),
        out.clone(),
    ).unwrap();
    let metadata = std::fs::metadata(&out).unwrap();
    assert!(
        metadata.len() > 100_000,
        "composed output too small: {} bytes",
        metadata.len(),
    );
}
```

Run:

```bash
cargo test -p video-coach-media --features media compose_source_plus_webcam
```

Expected: PASS in ~30-60s on macOS Metal; potentially much longer on Linux lavapipe (per-frame `device.poll(Maintain::Wait)` blocks). Output `.mov` should be ≥100 KB and play back with the webcam visible in the bottom-right corner of the source video.

**CI note:** the full 60-second `source-1080p.mp4` may exceed CI's reasonable per-test budget on lavapipe. If the `media-tests` job times out, the first remediation is to trim the test fixture to a 5-second clip rather than re-architecting the compose pipeline. Phase 6 will address compositor caching for genuine performance.

**Step 4: Verify other quality gates.**

```bash
cargo fmt --check
cargo clippy --workspace --all-targets --features media -- -D warnings
cargo test --workspace
cargo test --workspace --features media
cargo build -p video-coach-app --release --no-default-features
nm target/release/video-coach-app | grep -iE "wgpu|gstreamer" | head -3
```

All clean. The `nm` grep MUST return empty — if it shows wgpu or gstreamer symbols, the optional-dep gating from Task 1 regressed.

Test count: 60 (default) + 2 new media tests (passthrough from Task 3 + compose from Task 4) = 62 with `--features media`.

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
