#![cfg(feature = "media")]

//! Phase 10 Task 4 — full record + tag + export lifecycle E2E.
//!
//! Records a clip via the same FixtureSource path Phase 8/9 use, then
//! kicks off `Command::ExportCompilations` against `TagSelection::AllClips`
//! and asserts the per-tag + per-batch event sequence + the output .mp4's
//! existence + framerate. Companion to the unit-level export_smoke test
//! in `crates/video-coach-media/tests/export_smoke.rs`; this verifies the
//! bus + spawned-export-task wiring end-to-end (per Task 4 prep's
//! refactor: ExportCompilations now spawns a detached task so the bus
//! can process CancelExport mid-export).
//!
//! Also covers the mid-export cancel path: send Command::CancelExport
//! ~100ms into the run, assert export.batch.cancelled fires + the
//! partial output .mp4 is deleted.

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

/// Setup helper: launches the app, creates a project, adds the source
/// fixture, records a ~1.2s clip, returns the (App, project_path,
/// export_dir, project_name). Used by both tests below.
async fn launch_record_and_open(
    parent: &TempDir,
    project_name: &str,
) -> anyhow::Result<(App, PathBuf, TempDir)> {
    let webcam = webcam_fixture();
    let source = source_fixture();

    let project_path = parent.path().join(project_name);
    std::fs::create_dir(&project_path)?;
    let export_dir = TempDir::new()?;

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

    // Record a ~1.2s clip → recording.mov has plenty of frames for the
    // export to walk through. Per plan Task 4 step 2.
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
    app.wait_for_event("clip_recording.started", Duration::from_secs(10))
        .await?;

    tokio::time::sleep(Duration::from_millis(1200)).await;

    let stop = app
        .send(serde_json::json!({"cmd": "stop_clip_recording"}))
        .await?;
    assert_eq!(stop.ok, Some(true), "stop_clip_recording: {:?}", stop.error);
    app.wait_for_event("clip_recording.stopped", Duration::from_secs(10))
        .await?;

    Ok((app, project_path, export_dir))
}

#[tokio::test]
async fn export_full_lifecycle() -> anyhow::Result<()> {
    let parent = TempDir::new()?;
    let (mut app, _project_path, export_dir) =
        launch_record_and_open(&parent, "phase10-export-test").await?;

    // Per plan Task 4 step 5: dispatch ExportCompilations with
    // TagSelection::AllClips, R720 + Low (faster on lavapipe), tmp folder.
    // Resolution + Quality serde form is camelCase — `R720` → "r720",
    // `Low` → "low" (per project.rs's `#[serde(rename_all = "camelCase")]`).
    let export = app
        .send(serde_json::json!({
            "cmd": "export_compilations",
            "selections": [{ "kind": "all_clips" }],
            "output_folder": export_dir.path().to_string_lossy(),
            "resolution": "r720",
            "quality": "low",
            "project_name": "phase10-export-test",
        }))
        .await?;
    assert_eq!(
        export.ok,
        Some(true),
        "export_compilations dispatch: {:?}",
        export.error,
    );

    // Per plan Task 4 step 6 + 7. batch.started fires synchronously
    // before the spawned task; tag.started fires from inside the
    // spawned task as it enters the loop.
    let _started = app
        .wait_for_event("export.batch.started", Duration::from_secs(5))
        .await?;
    let _tag_started = app
        .wait_for_event("export.tag.started", Duration::from_secs(10))
        .await?;

    // Per plan Task 4 step 8: tag.completed timeout 60s for lavapipe-
    // slow runners + Windows mfh264enc cold-start. A 1.2s clip at 30
    // fps produces ~36 frames; assert >= 20 with margin (lavapipe can
    // skip a frame or two during state transitions).
    let tag_completed = app
        .wait_for_event("export.tag.completed", Duration::from_secs(60))
        .await?;
    let frames_pushed = tag_completed
        .other
        .get("frames_pushed")
        .and_then(|v| v.as_i64())
        .expect("export.tag.completed carries frames_pushed");
    assert!(
        frames_pushed >= 20,
        "expected ≥20 frames pushed (1.2s × 30fps ≈ 36), got {frames_pushed}",
    );

    // Per plan Task 4 step 9: batch.completed marks the end-of-batch
    // SucceededAll outcome write.
    let _batch_completed = app
        .wait_for_event("export.batch.completed", Duration::from_secs(10))
        .await?;

    // Per plan Task 4 step 10: file exists at expected path. The
    // sanitize_filename helper strips nothing problematic from
    // "all-clips" or "phase10-export-test"; expected name is
    // "all-clips - phase10-export-test.mp4".
    let expected_path = export_dir
        .path()
        .join("all-clips - phase10-export-test.mp4");
    assert!(
        expected_path.exists(),
        "expected output .mp4 at {}",
        expected_path.display(),
    );
    let size = std::fs::metadata(&expected_path)?.len();
    assert!(
        size > 50_000,
        "expected output > 50 KB, got {size} bytes at {}",
        expected_path.display(),
    );

    // Per plan Task 4 step 11: ffprobe-equivalent via Discoverer.
    // We can't import gstreamer in the harness crate without a feature
    // dep; verify the .mp4 is at least non-trivially formed by checking
    // size + the .mp4 magic bytes ("ftyp") at the standard ISO BMFF
    // offset (4 bytes in). The unit-level export_smoke test in
    // video-coach-media already asserts duration + framerate via
    // Discoverer; this test catches the bus + harness wiring.
    let bytes = std::fs::read(&expected_path)?;
    assert!(bytes.len() > 8, "file too short to be an .mp4");
    assert_eq!(
        &bytes[4..8],
        b"ftyp",
        "expected ISO BMFF magic at offset 4, got {:?}",
        &bytes[4..8],
    );

    app.quit().await?;
    Ok(())
}

#[tokio::test]
async fn export_cancel_deletes_partial_output() -> anyhow::Result<()> {
    let parent = TempDir::new()?;
    let (mut app, _project_path, export_dir) =
        launch_record_and_open(&parent, "phase10-cancel-test").await?;

    let export = app
        .send(serde_json::json!({
            "cmd": "export_compilations",
            "selections": [{ "kind": "all_clips" }],
            "output_folder": export_dir.path().to_string_lossy(),
            "resolution": "r720",
            "quality": "low",
            "project_name": "phase10-cancel-test",
        }))
        .await?;
    assert_eq!(
        export.ok,
        Some(true),
        "export_compilations dispatch: {:?}",
        export.error,
    );

    let _ = app
        .wait_for_event("export.batch.started", Duration::from_secs(5))
        .await?;
    let _ = app
        .wait_for_event("export.tag.started", Duration::from_secs(10))
        .await?;

    // Per plan Task 4 cancel-test step "Sleep 100ms (let the export
    // start producing frames)". Then dispatch CancelExport. The Task 4
    // prep refactor moved the export loop into a spawned task so the
    // bus can process this command — without that refactor, the bus
    // task would be blocked awaiting spawn_blocking and CancelExport
    // would queue forever.
    tokio::time::sleep(Duration::from_millis(100)).await;

    let cancel = app
        .send(serde_json::json!({"cmd": "cancel_export"}))
        .await?;
    assert_eq!(cancel.ok, Some(true), "cancel_export: {:?}", cancel.error);

    // The driver picks up the cancel flag at next tick (per fix #10),
    // tears down the pipeline (per fix #14), deletes the partial .mp4
    // (per fix #10 + Task 1's Cancelled error path), emits batch.cancelled.
    let cancelled = app
        .wait_for_event("export.batch.cancelled", Duration::from_secs(30))
        .await?;
    let tags_completed = cancelled
        .other
        .get("tags_completed")
        .and_then(|v| v.as_i64())
        .expect("export.batch.cancelled carries tags_completed");
    assert_eq!(
        tags_completed, 0,
        "expected 0 tags completed before cancel, got {tags_completed}",
    );

    // Per plan Task 4 cancel-test step "Verify the output file is
    // absent".
    let expected_path = export_dir
        .path()
        .join("all-clips - phase10-cancel-test.mp4");
    assert!(
        !expected_path.exists(),
        "partial output should be deleted on cancel; still found at {}",
        expected_path.display(),
    );

    app.quit().await?;
    Ok(())
}
