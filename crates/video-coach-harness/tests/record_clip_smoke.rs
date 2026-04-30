#![cfg(feature = "media")]

//! Phase 8 Task 5 — full record-clip lifecycle E2E.
//!
//! Drives the binary with `--fixture-recording-source=<webcam.mov>` so
//! the bus's `StartClipRecording` handler uses a `FixtureSource` (file-
//! backed) instead of the platform-default camera/mic. Avoids needing
//! webcam permissions or an audio daemon on CI runners.
//!
//! Verifies:
//!   - `start_clip_recording` succeeds and emits `recording.started`.
//!   - `append_stroke` with synthetic JSON points succeeds in mode
//!     Recording, errors in mode Scanning.
//!   - `stop_clip_recording` succeeds, finalizes a `Clip` in
//!     `project.clips`, persists `project.json` to disk, and the
//!     output `.mov` is non-trivial.

use std::path::PathBuf;
use std::time::Duration;
use tempfile::TempDir;
use video_coach_harness::{App, LaunchOptions};

fn webcam_fixture() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures/webcam.mov");
    p.canonicalize().expect("fixtures/webcam.mov exists")
}

fn source_fixture() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures/source-1080p.mp4");
    p.canonicalize().expect("fixtures/source-1080p.mp4 exists")
}

#[tokio::test]
async fn record_clip_full_lifecycle() -> anyhow::Result<()> {
    let webcam = webcam_fixture();
    let source = source_fixture();

    let parent = TempDir::new()?;
    let project_path = parent.path().join("phase8-record-test");
    std::fs::create_dir(&project_path)?;

    let mut app = App::launch_with_options(LaunchOptions {
        fixture_recording_source: Some(webcam.to_string_lossy().into_owned()),
    })
    .await?;

    let create = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(create.ok, Some(true), "new_project: {:?}", create.error);
    app.wait_for_event("project.opened", Duration::from_secs(2))
        .await?;

    let add = app
        .send(serde_json::json!({
            "cmd": "add_source_video",
            "absolute_path": source.to_string_lossy(),
        }))
        .await?;
    assert_eq!(add.ok, Some(true), "add_source_video: {:?}", add.error);
    app.wait_for_event("source.added", Duration::from_secs(5))
        .await?;
    app.wait_for_event("player.opened", Duration::from_secs(5))
        .await?;

    // Append stroke before recording — must error.
    let early_stroke = app
        .send(serde_json::json!({
            "cmd": "append_stroke",
            "points_json": "[{\"x\":0.5,\"y\":0.5,\"t\":0.0}]",
        }))
        .await?;
    assert_eq!(
        early_stroke.ok,
        Some(false),
        "append_stroke before recording should error",
    );

    // Start recording. Snapshot playhead = 0 (project just loaded).
    let start = app
        .send(serde_json::json!({
            "cmd": "start_clip_recording",
            "playhead_snapshot_seconds": 0.0,
        }))
        .await?;
    assert_eq!(
        start.ok,
        Some(true),
        "start_clip_recording: {:?}",
        start.error
    );
    let started = app
        .wait_for_event("clip_recording.started", Duration::from_secs(10))
        .await?;
    let clip_id = started
        .other
        .get("clip_id")
        .and_then(|v| v.as_str())
        .expect("recording.started carries clip_id")
        .to_string();
    let filename = started
        .other
        .get("filename")
        .and_then(|v| v.as_str())
        .expect("recording.started carries filename")
        .to_string();
    assert!(
        filename.starts_with("clip-") && filename.ends_with(".mov"),
        "filename should be clip-<uuid>.mov, got {filename:?}",
    );

    // Append a stroke during recording. Synthetic 3-point path.
    let stroke = app
        .send(serde_json::json!({
            "cmd": "append_stroke",
            "points_json": "[{\"x\":0.10,\"y\":0.10,\"t\":0.05},{\"x\":0.50,\"y\":0.50,\"t\":0.15},{\"x\":0.90,\"y\":0.90,\"t\":0.30}]",
        }))
        .await?;
    assert_eq!(stroke.ok, Some(true), "append_stroke: {:?}", stroke.error);

    // Let the recording run ~1.2s so duration is ≈ 1s.
    tokio::time::sleep(Duration::from_millis(1200)).await;

    let stop = app
        .send(serde_json::json!({"cmd": "stop_clip_recording"}))
        .await?;
    assert_eq!(stop.ok, Some(true), "stop_clip_recording: {:?}", stop.error);
    let stopped = app
        .wait_for_event("clip_recording.stopped", Duration::from_secs(10))
        .await?;
    assert_eq!(
        stopped.other.get("clip_id").and_then(|v| v.as_str()),
        Some(clip_id.as_str()),
    );
    let dur = stopped
        .other
        .get("duration_seconds")
        .and_then(|v| v.as_f64());
    assert!(
        dur.is_some_and(|d| d > 0.5 && d < 5.0),
        "duration_seconds should be ~1s, got {:?}",
        dur,
    );

    // Verify project.json on disk.
    let json = std::fs::read_to_string(project_path.join("project.json"))?;
    let parsed: serde_json::Value = serde_json::from_str(&json)?;
    let clips = parsed
        .get("clips")
        .and_then(|v| v.as_array())
        .expect("clips array");
    assert_eq!(clips.len(), 1, "expected exactly one clip");
    let clip = &clips[0];
    assert_eq!(
        clip.get("id").and_then(|v| v.as_str()),
        Some(clip_id.as_str())
    );
    assert_eq!(
        clip.get("recordingFilename").and_then(|v| v.as_str()),
        Some(filename.as_str()),
    );
    assert_eq!(clip.get("sourceIndex").and_then(|v| v.as_u64()), Some(0));
    let events = clip
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events");
    let stroke_events = events
        .iter()
        .filter(|e| {
            e.get("kind")
                .and_then(|v| v.as_object())
                .map(|m| m.contains_key("stroke"))
                .unwrap_or(false)
        })
        .count();
    assert!(
        stroke_events >= 1,
        "expected at least one stroke event in clip; got {events:?}",
    );

    // Verify the recording .mov exists + non-trivial.
    let mov_path = project_path.join("recordings").join(&filename);
    let meta = std::fs::metadata(&mov_path)?;
    assert!(
        meta.len() > 10_000,
        "{} should be > 10 KB, got {} bytes",
        mov_path.display(),
        meta.len()
    );

    app.quit().await?;
    Ok(())
}
