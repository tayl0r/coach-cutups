//! Phase 9 Task 2 smoke test (per adversarial fix #10). Headless: no Slint,
//! no harness binary, no display. Builds a `Clip` directly, runs through
//! the preview pipeline, asserts a non-trivial frame count flowed through
//! the FrameSink in 1s of playback.
//!
//! `VIDEO_COACH_NO_AUDIO=1` keeps the webcam audio chain on `fakesink`
//! so CI runners without an audio daemon don't fail PAUSED→PLAYING.
//! `GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE` keeps macOS test runs off the
//! VideoToolbox decoders that need a Cocoa runloop.

#![cfg(feature = "media")]

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use uuid::Uuid;

use video_coach_compositor::Compositor;
use video_coach_core::event::{CommentaryEvent, EventKind};
use video_coach_core::project::Clip;
use video_coach_media::preview_pipeline::PreviewPipeline;
use video_coach_media::source_player::FrameSink;

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

struct CountingSink(Arc<AtomicU64>);
impl FrameSink for CountingSink {
    fn push_frame(&self, _w: u32, _h: u32, _data: &[u8]) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

fn set_test_env() {
    std::env::set_var("VIDEO_COACH_NO_AUDIO", "1");
    // Match the rest of the media crate's tests: keep VT decoders off so
    // the cargo test harness doesn't need a Cocoa runloop on macOS.
    std::env::set_var(
        "GST_PLUGIN_FEATURE_RANK",
        "vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE",
    );
}

fn smoke_clip(events: Vec<CommentaryEvent>, recording_duration: f64) -> Clip {
    Clip {
        id: Uuid::new_v4(),
        name: "smoke".into(),
        notes: String::new(),
        tags: Vec::new(),
        source_index: 0,
        // 10s into the source; far enough from t=0 to exercise the seek
        // (per fix #23 case (a): initial mount seeks to segments[0].source_start).
        start_source_seconds: 10.0,
        recording_duration,
        recording_filename: "webcam.mov".into(),
        events,
        sort_index: 0,
        created_at: Utc::now(),
    }
}

#[test]
fn preview_pipeline_pushes_frames_for_a_simple_clip() {
    set_test_env();

    let source = fixture("source-1080p.mp4");
    let webcam = fixture("webcam.mov");
    // 1.5s of pure playback, no events → one Play segment.
    let clip = smoke_clip(Vec::new(), 1.5);

    let count = Arc::new(AtomicU64::new(0));
    let sink: Box<dyn FrameSink> = Box::new(CountingSink(count.clone()));

    let compositor = Arc::new(Compositor::new_headless().expect("headless compositor"));
    let pipeline = PreviewPipeline::open(
        &source, &webcam, &clip, /* source_duration_seconds */ 60.0, compositor, sink,
    )
    .expect("preview pipeline open");

    pipeline.play().expect("play");
    std::thread::sleep(Duration::from_secs(1));

    let frames = count.load(Ordering::SeqCst);
    // CI lavapipe (Linux software wgpu) is ~3× slower than Apple Silicon and
    // gets even slower when the runner has just finished a 135s compose
    // test (cold caches + GC). The 30 Hz preview pulled 9 frames in 1s on
    // CI run 25230117796; matches Phase 9's closeout pattern of relaxing
    // frame-count floors for lavapipe. >= 5 keeps the test honest about
    // "the driver is producing frames" without flaking on slow runners.
    eprintln!("preview_pipeline_smoke: expected ≥5 frames in 1s, got {frames}");
    assert!(
        frames >= 5,
        "expected ≥5 frames in 1s of preview playback, got {frames}",
    );

    pipeline.stop().expect("stop");
}

#[test]
fn preview_pipeline_opens_clip_with_freeze_segment() {
    // Bonus test: clip with a Pause/Play pair → a Freeze segment lands
    // between two Play segments. Pre-decode runs for the Freeze; this
    // asserts the pre-decode path doesn't panic and the pipeline opens
    // cleanly. We don't validate visual output here — just lifecycle.
    set_test_env();

    let source = fixture("source-1080p.mp4");
    let webcam = fixture("webcam.mov");

    let events = vec![
        CommentaryEvent {
            record_time: 0.5,
            kind: EventKind::Pause,
        },
        CommentaryEvent {
            record_time: 1.0,
            kind: EventKind::Play,
        },
    ];
    let clip = smoke_clip(events, 1.5);

    let count = Arc::new(AtomicU64::new(0));
    let sink: Box<dyn FrameSink> = Box::new(CountingSink(count.clone()));

    let compositor = Arc::new(Compositor::new_headless().expect("headless compositor"));
    let pipeline = PreviewPipeline::open(&source, &webcam, &clip, 60.0, compositor, sink)
        .expect("preview pipeline open with freeze segment");

    // Brief play → tear down. Mostly proves: (a) pre-decode succeeded
    // for the Freeze segment, (b) the driver runs across segment
    // boundaries without panicking, (c) teardown is clean.
    pipeline.play().expect("play");
    std::thread::sleep(Duration::from_millis(500));
    pipeline.stop().expect("stop");

    // Loose lower bound — even at 30Hz with a 500ms run we should see a
    // few frames; this just guards against "the pipeline never produced
    // any pixels" regressions.
    let frames = count.load(Ordering::SeqCst);
    eprintln!("freeze-segment smoke: frames pushed = {frames}");
    assert!(frames > 0, "expected >0 frames during freeze-segment smoke");
}
