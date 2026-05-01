//! Phase 10 Task 1 smoke tests for the export pipeline. Headless: no Slint,
//! no harness binary, no display. Builds a single-clip `CompilationPlan`
//! by hand and runs it through `export_compilation`.
//!
//! `VIDEO_COACH_NO_AUDIO=1` keeps the recording's audio chain on `fakesink`
//! for places that consult it; export's own audio chain is independent.
//! `GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,...` keeps macOS test runs off
//! VideoToolbox decoders/encoders that need a Cocoa runloop.
//!
//! These tests are expected to take ~5-15s on Linux CI (lavapipe) and
//! ~1-3s on Apple Silicon. Test 1 has a 60s wall budget worst-case; if a
//! local run exceeds that, mark it `#[ignore]` rather than reduce scope.

#![cfg(feature = "media")]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use uuid::Uuid;

use video_coach_compositor::Compositor;
use video_coach_core::compilation_plan::{CompilationEntry, CompilationPlan};
use video_coach_core::event::{CommentaryEvent, EventKind};
use video_coach_core::project::{Clip, Quality, Resolution};
use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};
use video_coach_core::timeline::{playback_segments, PlaybackSegment};
use video_coach_media::export::{export_compilation, ExportError, ExportInputs};

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

fn set_test_env() {
    std::env::set_var("VIDEO_COACH_NO_AUDIO", "1");
    // Match the rest of the media crate's tests: keep VT decoders/encoders
    // off so the cargo test harness doesn't need a Cocoa runloop on macOS.
    std::env::set_var(
        "GST_PLUGIN_FEATURE_RANK",
        "vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE",
    );
}

/// Build a single-clip CompilationPlan with one Stroke event so the
/// strokes path is exercised. Source duration is taken from the source
/// fixture — large enough to cover any plausible plan.
fn build_single_clip_plan(
    recording_duration: f64,
    source_duration: f64,
) -> (Clip, CompilationPlan) {
    let stroke = Stroke {
        id: Uuid::new_v4(),
        color: Rgba::RED,
        line_width: 0.012,
        // Two points, drawn at record_time = 0.1s (first point at t=0.0s,
        // last at t=0.1s relative to stroke start). visible_strokes() will
        // include this stroke for any record_time >= 0.0.
        points: vec![
            StrokePoint {
                x: 0.25,
                y: 0.5,
                t: 0.0,
            },
            StrokePoint {
                x: 0.75,
                y: 0.5,
                t: 0.1,
            },
        ],
        auto_clear_after_seconds: None,
    };
    let events = vec![CommentaryEvent {
        record_time: 0.1,
        kind: EventKind::Stroke(stroke),
    }];

    let clip = Clip {
        id: Uuid::new_v4(),
        name: "smoke-export".into(),
        notes: String::new(),
        tags: Vec::new(),
        source_index: 0,
        // 10s into source — same as preview_pipeline_smoke. Keeps us out
        // of the codec's first-keyframe boundary cases.
        start_source_seconds: 10.0,
        recording_duration,
        recording_filename: "webcam.mov".into(),
        events,
        sort_index: 0,
        created_at: Utc::now(),
    };

    let segments: Vec<PlaybackSegment> = playback_segments(&clip, source_duration);
    let entry = CompilationEntry {
        clip_id: clip.id,
        index_in_output: 0,
        composition_start: 0.0,
        segments,
        recording_duration,
    };
    let plan = CompilationPlan {
        total_duration_seconds: recording_duration,
        entries: vec![entry],
    };
    (clip, plan)
}

fn build_inputs(
    clip: Clip,
    plan: CompilationPlan,
    source: PathBuf,
    recording: PathBuf,
    source_duration: f64,
) -> ExportInputs {
    let clip_id = clip.id;
    let source_index = clip.source_index;
    let mut clips_by_id = HashMap::new();
    clips_by_id.insert(clip_id, clip);
    let mut source_paths = HashMap::new();
    source_paths.insert(source_index, source);
    let mut recording_paths = HashMap::new();
    recording_paths.insert(clip_id, recording);
    let mut source_durations = HashMap::new();
    source_durations.insert(source_index, source_duration);
    ExportInputs {
        plan,
        clips_by_id,
        source_paths,
        recording_paths,
        source_durations,
    }
}

#[test]
fn export_compilation_writes_h264_mp4_for_single_clip_plan() {
    set_test_env();

    let source = fixture("source-1080p.mp4");
    // Recording fixture is webcam.mov; it's only used as a decodable .mov
    // for the recording chain — the test asserts on the OUTPUT, not on
    // the recording's contents.
    let recording = fixture("webcam.mov");

    // Plan: 1.5s of plain Play (no events that affect segments). One Stroke
    // event exercises visible_strokes() inside compose_entry_frame.
    let recording_duration = 1.5_f64;
    let source_duration = 60.0_f64;
    let (clip, plan) = build_single_clip_plan(recording_duration, source_duration);
    let inputs = build_inputs(clip, plan, source, recording, source_duration);

    let tmp = tempfile::tempdir().expect("tempdir");
    let out_path = tmp.path().join("export.mp4");

    let compositor = Arc::new(Compositor::new_headless().expect("headless compositor"));
    let cancel = Arc::new(AtomicBool::new(false));
    let on_progress: Box<dyn Fn(video_coach_media::export::ExportProgress) + Send + Sync> =
        Box::new(|_p| {});

    let started = std::time::Instant::now();
    let summary = export_compilation(
        inputs,
        &out_path,
        Resolution::R720, // smaller than source — exercises the videoscale leg.
        Quality::Low,
        /* source_volume    */ 1.0,
        /* commentary_volume*/ 1.0,
        compositor,
        cancel,
        on_progress,
    )
    .expect("export_compilation should succeed for single-clip Play plan");
    let elapsed = started.elapsed();
    eprintln!(
        "export_smoke: frames_pushed={}, elapsed={:?}",
        summary.frames_pushed, elapsed,
    );

    // 1.5s × 30fps = 45 frames pushed. Anything > 0 proves the driver ran;
    // the strict check guards against a regression where the entry loop
    // exits after only a handful of frames.
    assert!(
        summary.frames_pushed >= 30,
        "expected ≥30 frames pushed for 1.5s plan, got {}",
        summary.frames_pushed,
    );

    // Output file exists and has non-trivial size.
    let metadata = std::fs::metadata(&out_path).expect("output mp4 should exist");
    assert!(
        metadata.len() > 50_000,
        "expected > 50KB output, got {} bytes",
        metadata.len(),
    );

    // Discoverer probe: duration ≈ recording_duration ± 0.2s, video
    // framerate is 30/1. 60s discoverer timeout handles slow CI lavapipe.
    let _ = video_coach_media::init();
    let timeout = gstreamer::ClockTime::from_seconds(60);
    let discoverer = gstreamer_pbutils::Discoverer::new(timeout).expect("discoverer");
    let abs = out_path.canonicalize().expect("canonicalize output");
    let uri = format!("file://{}", abs.to_str().expect("output utf8 path"));
    let info = discoverer
        .discover_uri(&uri)
        .unwrap_or_else(|e| panic!("discover {uri}: {e}"));

    let duration = info
        .duration()
        .expect("output mp4 should report a duration");
    let dur_secs = duration.nseconds() as f64 / 1e9;
    eprintln!("export_smoke: output duration = {dur_secs}s");
    assert!(
        (dur_secs - recording_duration).abs() < 0.2,
        "output duration {dur_secs}s diverges from plan {recording_duration}s by > 0.2s",
    );

    let video_streams = info.video_streams();
    let v = video_streams
        .first()
        .expect("output mp4 should have a video stream");
    let fr = v.framerate();
    assert_eq!(
        (fr.numer(), fr.denom()),
        (30, 1),
        "expected 30/1 framerate, got {}/{}",
        fr.numer(),
        fr.denom(),
    );

    // Loose 60s wall-clock assertion. If a local run exceeds, prefer
    // marking #[ignore] over loosening this further.
    assert!(
        elapsed < Duration::from_secs(60),
        "export took {elapsed:?}, exceeded 60s budget",
    );
}

#[test]
fn export_compilation_cancel_deletes_partial_output() {
    set_test_env();

    let source = fixture("source-1080p.mp4");
    let recording = fixture("webcam.mov");

    // Longer plan (3s) so the cancel race is winnable on fast machines —
    // even Apple Silicon needs ~100ms to chew through this.
    let recording_duration = 3.0_f64;
    let source_duration = 60.0_f64;
    let (clip, plan) = build_single_clip_plan(recording_duration, source_duration);
    let inputs = build_inputs(clip, plan, source, recording, source_duration);

    let tmp = tempfile::tempdir().expect("tempdir");
    let out_path = tmp.path().join("export-cancel.mp4");

    let compositor = Arc::new(Compositor::new_headless().expect("headless compositor"));
    let cancel = Arc::new(AtomicBool::new(false));
    let cancel_for_thread = cancel.clone();
    let canceller = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        cancel_for_thread.store(true, Ordering::Release);
    });
    let on_progress: Box<dyn Fn(video_coach_media::export::ExportProgress) + Send + Sync> =
        Box::new(|_p| {});

    let result = export_compilation(
        inputs,
        &out_path,
        Resolution::R720,
        Quality::Low,
        1.0,
        1.0,
        compositor,
        cancel,
        on_progress,
    );
    canceller.join().expect("canceller thread");

    match result {
        Err(ExportError::Cancelled) => {}
        Err(other) => panic!("expected ExportError::Cancelled, got {other:?}"),
        Ok(summary) => panic!(
            "expected ExportError::Cancelled, got Ok({})",
            summary.frames_pushed
        ),
    }

    // Per fix #10: cancel deletes partial output.
    assert!(
        !out_path.exists(),
        "partial output should be deleted on cancel: {}",
        out_path.display(),
    );
}
