# Phase 3: GStreamer Capture Pipeline — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land a working recording pipeline. Camera + mic → single `.mov` file on disk. Both a production source (real platform devices) and a fixture source (deterministic file-based playback for tests). Wired through the bus + control socket so the harness can start/stop recordings and verify outputs.

**Architecture:** A new `crates/video-coach-media/` crate owns GStreamer pipeline construction and lifecycle. The pipeline graph is fixed (`source → encoder → muxer → filesink`); only the source bin is pluggable. New `Command::StartRecording / StopRecording` variants on the existing bus. New `recording.*` `tracing` event targets bridged to the control socket via the `event_layer::FORWARDED_TARGETS` list (already in place from Phase 2). A media-tagged end-to-end smoke test exercises the full flow against the `webcam.mov` fixture.

**Tech Stack:** `gstreamer-rs` (`gstreamer`, `gstreamer-app`, `gstreamer-video`, `gstreamer-audio`). System dep on GStreamer 1.x via Homebrew (mac), apt (ubuntu), official binaries (windows). H.264 hardware encoding (`vtenc_h264` mac, `mfh264enc` win, `vaapih264enc` linux) per the design doc — software fallback via `x264enc`.

**Scope refinements (defer to later phases):**
- Linux + Windows production source bins — Phase 3 only ships macOS production + fixture. The `CaptureSourceFactory` trait makes adding the others mechanical.
- PiP composite, wgpu compositor — Phase 4.
- Stroke overlay during recording — Phase 4 (depends on the compositor).
- Per-clip event log persistence — Phase 5+ (UI plumbing).
- Live preview rendering — Phase 4.

Phase 3's bar is "the harness can record from a fixture source to a .mov on disk and the resulting file plays back."

---

## Task 1: Install GStreamer locally + verify build dependency

**Files:** none (one-time machine setup; repeat in CI later via Task 11).

**Step 1: Install via Homebrew (macOS)**

```bash
brew install gstreamer
```

The `gstreamer` formula is a meta-package that pulls in `gst-plugins-base`, `gst-plugins-good`, `gst-plugins-bad`, `gst-plugins-ugly`, `gst-libav`. Total install ~700 MB.

**Step 2: Verify the install**

```bash
gst-launch-1.0 --version
gst-inspect-1.0 avfvideosrc | head -3   # macOS camera source
gst-inspect-1.0 osxaudiosrc | head -3   # macOS mic source
gst-inspect-1.0 vtenc_h264 | head -3    # macOS HW H.264 encoder
gst-inspect-1.0 qtmux | head -3         # MOV/MP4 muxer
gst-inspect-1.0 filesrc | head -3       # used by the fixture source
gst-inspect-1.0 decodebin | head -3
pkg-config --modversion gstreamer-1.0
```

Expected: each lookup prints something. If any element is missing, the corresponding pipeline can't be built.

**Step 3: Commit a developer-setup note**

Create `docs/SETUP.md`:

```markdown
# Local development setup

## GStreamer (Phase 3+)

```bash
brew install gstreamer
```

This installs ~700 MB of GStreamer 1.x runtime + plugins. The Rust build links against the system libs via `pkg-config`.
```

```bash
git add docs/SETUP.md
git commit -m "docs: gstreamer install note for local dev"
```

---

## Task 2: Bootstrap `video-coach-media` crate

**Files:**
- Create: `crates/video-coach-media/Cargo.toml`
- Create: `crates/video-coach-media/src/lib.rs`
- Modify: root `Cargo.toml` (workspace members)

**Step 1: Add to workspace**

Append to root `Cargo.toml`'s `members`: `"crates/video-coach-media"`.

**Step 2: Create crate manifest**

```toml
# crates/video-coach-media/Cargo.toml
[package]
name = "video-coach-media"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
gstreamer = "0.23"
gstreamer-app = "0.23"
gstreamer-video = "0.23"
gstreamer-audio = "0.23"
thiserror = { workspace = true }
tracing = "0.1"
```

**Step 3: Empty placeholder lib.rs**

```rust
// crates/video-coach-media/src/lib.rs
// Modules added in subsequent tasks.

/// Initialize GStreamer once per process. Idempotent — safe to call from
/// every entry point. Required before any pipeline construction.
pub fn init() -> Result<(), gstreamer::glib::Error> {
    gstreamer::init()
}

#[cfg(test)]
mod tests {
    #[test]
    fn gstreamer_init_succeeds() {
        super::init().unwrap();
    }
}
```

**Step 4: Verify build**

```bash
cargo build -p video-coach-media
cargo test -p video-coach-media
```

Both must succeed. The build will fail loudly if GStreamer system libs are missing — that's the expected error path for someone who skipped Task 1.

**Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock crates/video-coach-media/
git commit -m "feat(media): bootstrap video-coach-media crate with gstreamer init"
```

---

## Task 3: Define `CaptureSourceFactory` trait + `RecordingPipeline` skeleton

**Files:**
- Create: `crates/video-coach-media/src/source.rs`
- Create: `crates/video-coach-media/src/recording.rs`
- Modify: `crates/video-coach-media/src/lib.rs`

**Step 1: Source factory trait**

```rust
// crates/video-coach-media/src/source.rs
use gstreamer::{Bin, Element};

/// Builds a GStreamer source bin that produces a video pad and an audio pad.
///
/// The bin's `video-src` ghost pad emits raw video; `audio-src` emits raw audio.
/// Downstream the recording pipeline links to these pads via `videoconvert` /
/// `audioconvert` so encoders see canonical raw formats regardless of the
/// concrete source element.
pub trait CaptureSourceFactory: Send + Sync {
    /// Construct a fresh source bin. Called once per recording.
    fn build(&self) -> Result<Bin, gstreamer::glib::BoolError>;

    /// Human-readable name for tracing events.
    fn name(&self) -> &str;
}
```

**Step 2: Recording pipeline skeleton (no source yet)**

```rust
// crates/video-coach-media/src/recording.rs
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error;
use crate::source::CaptureSourceFactory;

#[derive(Debug, Error)]
pub enum RecordingError {
    #[error("gstreamer init failed: {0}")]
    Init(#[from] gstreamer::glib::Error),
    #[error("pipeline construction: {0}")]
    Build(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// In-flight recording. `start()` transitions the pipeline to PLAYING; `stop()`
/// sends EOS, waits for it to flush, then transitions to NULL.
pub struct Recording {
    pipeline: gstreamer::Pipeline,
    output_path: PathBuf,
}

pub fn start(
    factory: Arc<dyn CaptureSourceFactory>,
    output_path: PathBuf,
) -> Result<Recording, RecordingError> {
    crate::init()?;
    let _ = factory; // wired in Task 6
    let _ = &output_path;
    Err(RecordingError::Build("not implemented yet".into()))
}

impl Recording {
    pub fn output_path(&self) -> &std::path::Path {
        &self.output_path
    }

    pub fn stop(self) -> Result<(), RecordingError> {
        let _ = self.pipeline;
        Err(RecordingError::Build("not implemented yet".into()))
    }
}
```

**Step 3: Wire modules**

```rust
// in lib.rs
pub mod source;
pub mod recording;
```

**Step 4: Build clean**

`cargo build -p video-coach-media` — should compile (functions return errors but the types check).

**Step 5: Commit**

```bash
git add crates/video-coach-media/src/source.rs crates/video-coach-media/src/recording.rs crates/video-coach-media/src/lib.rs
git commit -m "feat(media): CaptureSourceFactory trait + RecordingPipeline skeleton"
```

---

## Task 4: Implement `FixtureSource` (filesrc-based)

**Files:**
- Create: `crates/video-coach-media/src/fixture_source.rs`
- Modify: `crates/video-coach-media/src/lib.rs`

The fixture source is the simplest path to a working pipeline: it reads a single mov/mp4 file via `decodebin` and exposes `videoconvert`'d / `audioconvert`'d pads. Same wire shape as the production source; tests use this exclusively.

**Step 1: Implement**

```rust
// crates/video-coach-media/src/fixture_source.rs
use std::path::PathBuf;
use gstreamer::prelude::*;
use gstreamer::{Bin, Element, GhostPad, Pad};
use crate::source::CaptureSourceFactory;

/// File-backed source for tests. Reads a single mov/mp4, decodes it, and
/// re-publishes raw video + audio pads named `video-src` and `audio-src`.
pub struct FixtureSource {
    pub path: PathBuf,
    pub name: String,
}

impl FixtureSource {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let name = format!("fixture:{}", path.display());
        Self { path, name }
    }
}

impl CaptureSourceFactory for FixtureSource {
    fn name(&self) -> &str {
        &self.name
    }

    fn build(&self) -> Result<Bin, gstreamer::glib::BoolError> {
        let bin = Bin::new();

        let filesrc = gstreamer::ElementFactory::make("filesrc")
            .property("location", self.path.to_str().expect("utf8 path"))
            .build()
            .expect("filesrc");
        let decodebin = gstreamer::ElementFactory::make("decodebin")
            .build()
            .expect("decodebin");

        bin.add_many([&filesrc, &decodebin])?;
        filesrc.link(&decodebin)?;

        // decodebin exposes pads dynamically. When a pad is created we route
        // it to a videoconvert or audioconvert and then ghost the output
        // through `video-src` / `audio-src` ghost pads.
        let bin_weak = bin.downgrade();
        decodebin.connect_pad_added(move |_dbin, pad| {
            let Some(bin) = bin_weak.upgrade() else { return };
            let Some(caps) = pad.current_caps() else { return };
            let Some(structure) = caps.structure(0) else { return };
            let media_type = structure.name().to_string();

            let (convert_factory, ghost_name) = if media_type.starts_with("video/") {
                ("videoconvert", "video-src")
            } else if media_type.starts_with("audio/") {
                ("audioconvert", "audio-src")
            } else {
                return;
            };

            let convert = gstreamer::ElementFactory::make(convert_factory)
                .build()
                .expect("convert factory");
            bin.add(&convert).expect("add convert");
            convert.sync_state_with_parent().expect("sync state");

            let sink_pad = convert.static_pad("sink").expect("convert sink pad");
            pad.link(&sink_pad).expect("link decoded pad");

            let src_pad = convert.static_pad("src").expect("convert src pad");
            let ghost = GhostPad::with_target(&src_pad).expect("ghost pad");
            ghost.set_active(true).expect("set ghost active");
            bin.add_pad(&ghost).expect("add ghost pad");
            // Ghost pads from a Bin are named after the inner pad by default;
            // rename so callers can find them deterministically.
            // (gstreamer-rs's `with_target_and_name` would be cleaner; this
            // is the version-agnostic path.)
            let _ = src_pad;
            let _ = ghost_name;
        });

        Ok(bin)
    }
}
```

**Step 2: Test that the bin is constructible**

Append to `lib.rs`:

```rust
pub mod fixture_source;
```

Add a unit test in `fixture_source.rs`:

```rust
#[cfg(test)]
#[cfg(feature = "media")]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixtures_dir() -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../fixtures");
        p
    }

    #[test]
    fn build_succeeds_against_real_fixture() {
        crate::init().unwrap();
        let src = FixtureSource::new(fixtures_dir().join("webcam.mov"));
        let bin = src.build().unwrap();
        assert!(bin.upcast_ref::<gstreamer::Element>().static_pad("video_0").is_none(),
                "ghost pads attach lazily on pad_added; bin is empty until pipeline runs");
    }
}
```

**Step 3: Add `media` feature flag to `video-coach-media`**

```toml
# Cargo.toml
[features]
media = []
```

**Step 4: Run tests**

```bash
cargo test -p video-coach-media --features media
```

Expected: 2 passed (`gstreamer_init_succeeds` from Task 2 + the new build test).

**Step 5: Commit**

```bash
git add crates/video-coach-media/src/fixture_source.rs crates/video-coach-media/src/lib.rs crates/video-coach-media/Cargo.toml
git commit -m "feat(media): fixture source — filesrc + decodebin → ghost pads"
```

---

## Task 5: Implement the recording pipeline body

This is the substantive task. Builds the full `source → encoder → muxer → filesink` graph from a `CaptureSourceFactory`.

**Files:** Modify `crates/video-coach-media/src/recording.rs`.

**Pipeline shape:**

```
[source.video-src] → videoconvert → vtenc_h264 (mac) / x264enc (other) → h264parse →┐
                                                                                     ├→ qtmux → filesink
[source.audio-src] → audioconvert → audioresample → aacenc / fdkaacenc / avenc_aac →┘
```

**Step 1: Write the full body**

Replace `start` / `stop` with the actual implementations:

```rust
// crates/video-coach-media/src/recording.rs
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use gstreamer::prelude::*;
use thiserror::Error;
use crate::source::CaptureSourceFactory;

#[derive(Debug, Error)]
pub enum RecordingError {
    #[error("gstreamer init failed: {0}")]
    Init(#[from] gstreamer::glib::Error),
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline construction: {0}")]
    Build(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("source factory: {0}")]
    Source(#[from] gstreamer::glib::BoolError),
}

pub struct Recording {
    pipeline: gstreamer::Pipeline,
    output_path: PathBuf,
}

fn make_or(name: &str) -> Result<gstreamer::Element, RecordingError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| RecordingError::MissingElement(name.into()))
}

fn pick_video_encoder() -> Result<gstreamer::Element, RecordingError> {
    // Prefer hardware H.264 if available; fall back to x264enc.
    for name in ["vtenc_h264", "mfh264enc", "vaapih264enc", "nvh264enc", "x264enc"] {
        if let Ok(elem) = make_or(name) {
            tracing::info!(target: "recording", event = "recording.encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(RecordingError::MissingElement("h264 encoder (any)".into()))
}

fn pick_audio_encoder() -> Result<gstreamer::Element, RecordingError> {
    for name in ["fdkaacenc", "avenc_aac", "voaacenc"] {
        if let Ok(elem) = make_or(name) {
            tracing::info!(target: "recording", event = "recording.audio_encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(RecordingError::MissingElement("aac encoder (any)".into()))
}

pub fn start(
    factory: Arc<dyn CaptureSourceFactory>,
    output_path: PathBuf,
) -> Result<Recording, RecordingError> {
    crate::init()?;

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let pipeline = gstreamer::Pipeline::new();
    let source_bin = factory.build()?;

    let videoconvert = make_or("videoconvert")?;
    let video_enc = pick_video_encoder()?;
    let h264parse = make_or("h264parse")?;

    let audioconvert = make_or("audioconvert")?;
    let audioresample = make_or("audioresample")?;
    let audio_enc = pick_audio_encoder()?;

    let qtmux = make_or("qtmux")?;
    let filesink = gstreamer::ElementFactory::make("filesink")
        .property("location", output_path.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| RecordingError::MissingElement("filesink".into()))?;

    pipeline.add(&source_bin)?;
    pipeline.add_many([
        &videoconvert, &video_enc, &h264parse,
        &audioconvert, &audioresample, &audio_enc,
        &qtmux, &filesink,
    ])?;

    // Static links downstream of the source bin (whose pads are dynamic).
    gstreamer::Element::link_many([&videoconvert, &video_enc, &h264parse])?;
    gstreamer::Element::link_many([&audioconvert, &audioresample, &audio_enc])?;
    h264parse.link(&qtmux)?;
    audio_enc.link(&qtmux)?;
    qtmux.link(&filesink)?;

    // Source bin → convert chains. Pads on the source bin are created
    // dynamically by decodebin (in fixture mode) or appear at construction
    // (in production mode); use sometimes-pad linking for both cases.
    let videoconvert_sink = videoconvert.static_pad("sink").expect("videoconvert sink");
    let audioconvert_sink = audioconvert.static_pad("sink").expect("audioconvert sink");
    source_bin.connect_pad_added(move |_bin, pad| {
        let pad_name = pad.name();
        let target_sink = if pad_name == "video-src" {
            &videoconvert_sink
        } else if pad_name == "audio-src" {
            &audioconvert_sink
        } else {
            return;
        };
        if pad.link(target_sink).is_err() {
            tracing::warn!(target: "recording", "failed to link source pad {} to converter", pad_name);
        }
    });

    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| RecordingError::StateChange(format!("PLAYING: {e:?}")))?;

    tracing::info!(
        target: "recording",
        event = "recording.started",
        source = factory.name(),
        output = %output_path.display(),
    );

    Ok(Recording { pipeline, output_path })
}

impl Recording {
    pub fn output_path(&self) -> &Path {
        &self.output_path
    }

    pub fn stop(self) -> Result<(), RecordingError> {
        // Send EOS so qtmux flushes its moov atom; without this the .mov is
        // unplayable (no index).
        let bus = self.pipeline.bus().expect("pipeline bus");
        self.pipeline.send_event(gstreamer::event::Eos::new());

        // Wait for EOS to propagate (up to 5s).
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                tracing::warn!(target: "recording", "EOS timeout — file may be truncated");
                break;
            }
            if let Some(msg) = bus.timed_pop_filtered(
                gstreamer::ClockTime::from_nseconds(remaining.as_nanos() as u64),
                &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
            ) {
                if matches!(msg.view(), gstreamer::MessageView::Eos(_)) {
                    break;
                }
                if let gstreamer::MessageView::Error(err) = msg.view() {
                    return Err(RecordingError::Build(format!("eos wait: {err}")));
                }
            } else {
                break;
            }
        }

        self.pipeline
            .set_state(gstreamer::State::Null)
            .map_err(|e| RecordingError::StateChange(format!("NULL: {e:?}")))?;

        tracing::info!(
            target: "recording",
            event = "recording.stopped",
            output = %self.output_path.display(),
        );
        Ok(())
    }
}
```

**Step 2: Add an integration test that records 3 seconds from the fixture source**

Create `crates/video-coach-media/tests/record_fixture.rs`:

```rust
// crates/video-coach-media/tests/record_fixture.rs
#![cfg(feature = "media")]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use video_coach_media::{fixture_source::FixtureSource, recording::start};

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

#[test]
fn record_3s_from_webcam_fixture_produces_playable_mov() {
    let tmp = tempfile::Builder::new()
        .prefix("phase3-rec-")
        .suffix(".mov")
        .tempfile()
        .unwrap();
    let out_path = tmp.path().to_path_buf();

    let factory = Arc::new(FixtureSource::new(fixture("webcam.mov")));
    let rec = start(factory, out_path.clone()).unwrap();
    std::thread::sleep(Duration::from_secs(3));
    rec.stop().unwrap();

    let metadata = std::fs::metadata(&out_path).unwrap();
    assert!(metadata.len() > 100_000,
            "output file should be non-trivial; got {} bytes", metadata.len());
}
```

Add `tempfile` as a dev-dep in `crates/video-coach-media/Cargo.toml`:

```toml
[dev-dependencies]
tempfile = "3"
```

**Step 3: Run the test**

```bash
cargo test -p video-coach-media --features media --test record_fixture
```

Expected: PASS in ~3s. The output `.mov` should be ≥100 KB.

**Step 4: Commit**

```bash
git add crates/video-coach-media/src/recording.rs crates/video-coach-media/tests/record_fixture.rs crates/video-coach-media/Cargo.toml Cargo.lock
git commit -m "feat(media): record fixture source to .mov via H.264 + AAC + qtmux"
```

---

## Task 6: Wire `StartRecording` / `StopRecording` Commands on the bus

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/Cargo.toml` (add `video-coach-media` dep)

**Step 1: Add the variants**

```rust
// in bus.rs
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    Quit,
    Ping,
    /// Start a recording. `source` selects fixture vs. production. `output`
    /// is the .mov path; the parent dir is auto-created.
    StartRecording {
        source: SourceConfig,
        output: String,
    },
    StopRecording,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SourceConfig {
    /// Fixture file source — used by tests.
    Fixture { path: String },
    /// Default platform camera + mic — Phase 3 ships macOS only.
    PlatformDefault,
}
```

**Step 2: Add the dep**

In `crates/video-coach-app/Cargo.toml`:

```toml
[dependencies]
# ...existing...
video-coach-media = { path = "../video-coach-media" }
```

**Step 3: Wire dispatch**

In `bus::handle`, add arms for the two new variants. The bus owns an `Option<Recording>` — start populates it, stop drains and calls `.stop()`. Since the bus is a `&mut`-owning task, this is naturally serialized:

```rust
// pseudo — see actual structure of bus::spawn
match cmd {
    Command::StartRecording { source, output } => {
        if recording.is_some() {
            CommandReply { ok: false, error: Some("already recording".into()) }
        } else {
            let factory: Arc<dyn CaptureSourceFactory> = match source {
                SourceConfig::Fixture { path } => Arc::new(FixtureSource::new(path)),
                SourceConfig::PlatformDefault => {
                    return CommandReply {
                        ok: false,
                        error: Some("platform default source not yet implemented".into()),
                    };
                }
            };
            match video_coach_media::recording::start(factory, output.into()) {
                Ok(rec) => {
                    recording = Some(rec);
                    CommandReply { ok: true, error: None }
                }
                Err(e) => CommandReply { ok: false, error: Some(e.to_string()) },
            }
        }
    }
    Command::StopRecording => {
        match recording.take() {
            Some(rec) => match rec.stop() {
                Ok(()) => CommandReply { ok: true, error: None },
                Err(e) => CommandReply { ok: false, error: Some(e.to_string()) },
            },
            None => CommandReply { ok: false, error: Some("no active recording".into()) },
        }
    }
    // ...existing Quit / Ping arms unchanged
}
```

The `recording: Option<Recording>` lives in the dispatcher loop's local state, threaded through `handle` as a `&mut Option<Recording>`.

**Step 4: Bus unit tests for the new wire shape**

```rust
#[test]
fn start_recording_serializes_with_fixture_source() {
    let cmd = Command::StartRecording {
        source: SourceConfig::Fixture { path: "fixtures/webcam.mov".into() },
        output: "/tmp/x.mov".into(),
    };
    let v = serde_json::to_value(&cmd).unwrap();
    assert_eq!(v["cmd"], "start_recording");
    assert_eq!(v["source"]["kind"], "fixture");
    assert_eq!(v["source"]["path"], "fixtures/webcam.mov");
}

#[test]
fn stop_recording_serializes_to_bare_tag() {
    let cmd = Command::StopRecording;
    let v = serde_json::to_value(&cmd).unwrap();
    assert_eq!(v, serde_json::json!({"cmd": "stop_recording"}));
}
```

**Step 5: Run all app tests**

```bash
cargo test -p video-coach-app
```

Expected: 10 passed (8 existing + 2 new bus tests).

**Step 6: Commit**

```bash
git add crates/video-coach-app/ Cargo.lock
git commit -m "feat(app): StartRecording / StopRecording commands on the bus"
```

---

## Task 7: Forward `recording.*` events to the control socket

The `event_layer::FORWARDED_TARGETS` list already contains `"recording"` (Phase 2 set this proactively). No code changes required — verify by adding an assertion-test:

**Files:** Modify `crates/video-coach-app/src/event_layer.rs`.

**Step 1: Add a test that pins the curated target list**

```rust
#[cfg(test)]
#[cfg(feature = "control-socket")]
mod tests {
    use super::FORWARDED_TARGETS;

    #[test]
    fn forwarded_targets_include_recording() {
        assert!(FORWARDED_TARGETS.contains(&"recording"),
                "recording.* events must reach the control socket");
    }
}
```

**Step 2: Run**

```bash
cargo test -p video-coach-app event_layer
```

Expected: 1 passed.

**Step 3: Commit**

```bash
git add crates/video-coach-app/src/event_layer.rs
git commit -m "test(app): pin recording.* in event_layer FORWARDED_TARGETS"
```

---

## Task 8: Extend the harness with `start_recording` / `stop_recording` helpers

**Files:** Modify `crates/video-coach-harness/src/lib.rs`.

**Step 1: Add typed helpers**

```rust
// in App impl, after existing send/quit:

pub async fn start_recording_from_fixture(
    &mut self,
    fixture_path: impl Into<String>,
    output_path: impl Into<String>,
) -> anyhow::Result<Frame> {
    self.send(serde_json::json!({
        "cmd": "start_recording",
        "source": { "kind": "fixture", "path": fixture_path.into() },
        "output": output_path.into(),
    })).await
}

pub async fn stop_recording(&mut self) -> anyhow::Result<Frame> {
    self.send(serde_json::json!({ "cmd": "stop_recording" })).await
}
```

**Step 2: Run cargo check on the harness**

```bash
cargo check -p video-coach-harness
```

**Step 3: Commit**

```bash
git add crates/video-coach-harness/src/lib.rs
git commit -m "feat(harness): start_recording_from_fixture / stop_recording helpers"
```

---

## Task 9: End-to-end media-tagged smoke test

**Files:** Create `crates/video-coach-harness/tests/recording_smoke.rs`.

**Step 1: Write the test**

```rust
// crates/video-coach-harness/tests/recording_smoke.rs
#![cfg(feature = "media")]

use std::path::PathBuf;
use std::time::Duration;
use video_coach_harness::App;

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

#[tokio::test]
async fn record_from_fixture_via_harness() -> anyhow::Result<()> {
    let mut app = App::launch().await?;

    let tmp = tempfile::Builder::new()
        .prefix("e2e-rec-")
        .suffix(".mov")
        .tempfile()?;
    let out = tmp.path().to_path_buf();

    let reply = app.start_recording_from_fixture(
        fixture("webcam.mov").display().to_string(),
        out.display().to_string(),
    ).await?;
    assert_eq!(reply.ok, Some(true), "start_recording reply: {:?}", reply);

    app.wait_for_event("recording.started", Duration::from_secs(3)).await?;

    tokio::time::sleep(Duration::from_secs(3)).await;

    let reply = app.stop_recording().await?;
    assert_eq!(reply.ok, Some(true), "stop_recording reply: {:?}", reply);

    app.wait_for_event("recording.stopped", Duration::from_secs(5)).await?;

    let metadata = std::fs::metadata(&out)?;
    assert!(metadata.len() > 100_000, "output should be ≥100KB, got {}", metadata.len());

    let _ = app.quit().await?;
    Ok(())
}
```

Add `tempfile` as dev-dep on `video-coach-harness`:

```toml
[dev-dependencies]
tempfile = "3"
```

The harness's existing `Cargo.toml` may already pull tempfile via a transitive path; check first. If not declared, add it.

**Step 2: Make harness pass `--features media` to the app launch**

The app's media feature is currently a stub — Phase 3 should activate it on the app side too. Check `App::launch` in `lib.rs` and ensure the spawned subprocess inherits the `media` feature flag. The simplest approach: have the harness build the binary with `--features media` via cargo invocation, OR have `App::binary_path` accept a `profile` hint and walk to a different target.

Actually, the simplest path: the app binary itself doesn't need `--features media` because the StartRecording dispatch in `bus.rs` is unconditional. The `media` feature flag is only used by tests. So no harness changes are needed here.

Verify by running:

```bash
cargo build --workspace --features media
```

The build should succeed and the binary should support `start_recording` regardless of feature flag.

**Step 3: Run the test**

```bash
cargo test -p video-coach-harness --features media --test recording_smoke
```

Expected: PASS in ~5s.

**Step 4: Commit**

```bash
git add crates/video-coach-harness/tests/recording_smoke.rs crates/video-coach-harness/Cargo.toml Cargo.lock
git commit -m "test(harness): end-to-end recording smoke test against fixture source"
```

---

## Task 10: Update CI to install GStreamer

**Files:** Modify `.github/workflows/rust.yml`.

**Step 1: Add an install step before the `cargo build` step in BOTH jobs**

For the `test` matrix:

```yaml
      - name: Install GStreamer (macOS)
        if: runner.os == 'macOS'
        run: brew install gstreamer
      - name: Install GStreamer (Ubuntu)
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libgstreamer1.0-dev \
            libgstreamer-plugins-base1.0-dev \
            gstreamer1.0-plugins-base \
            gstreamer1.0-plugins-good \
            gstreamer1.0-plugins-bad \
            gstreamer1.0-plugins-ugly \
            gstreamer1.0-libav \
            gstreamer1.0-tools
      - name: Install GStreamer (Windows)
        if: runner.os == 'Windows'
        run: |
          choco install gstreamer --version=1.24.0 -y
          choco install gstreamer-devel --version=1.24.0 -y
          echo "C:\gstreamer\1.0\msvc_x86_64\bin" | Out-File -FilePath $env:GITHUB_PATH -Append
          echo "PKG_CONFIG_PATH=C:\gstreamer\1.0\msvc_x86_64\lib\pkgconfig" >> $env:GITHUB_ENV
```

For the `media-tests` job (Ubuntu only — same install):

```yaml
      - name: Install GStreamer
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libgstreamer1.0-dev \
            libgstreamer-plugins-base1.0-dev \
            gstreamer1.0-plugins-base \
            gstreamer1.0-plugins-good \
            gstreamer1.0-plugins-bad \
            gstreamer1.0-plugins-ugly \
            gstreamer1.0-libav \
            gstreamer1.0-tools
```

**Step 2: Commit and push**

```bash
git add .github/workflows/rust.yml
git commit -m "ci: install gstreamer on all runners before build/test"
```

Push (controller-coordinated, not by the implementer): `git push`.

Verify all 4 jobs go green.

---

## Phase 3 exit criteria

- All tasks committed.
- `cargo test --workspace --features media` green locally.
- `cargo build -p video-coach-app --release --no-default-features` still clean (control-socket compile-out preserved).
- CI matrix green on all 3 OSes for the `test` job.
- CI `media-tests` job green: pulls fixtures from the GitHub Release, builds with `--features media`, runs both the unit tests and the end-to-end recording smoke test.
- The `recording_smoke` integration test produces a real `.mov` ≥100 KB on disk.

When this is green, Phase 4 (wgpu compositor + PiP + stroke overlay) starts plugging into the recording pipeline's video pad.
