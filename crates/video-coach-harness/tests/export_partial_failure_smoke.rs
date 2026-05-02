#![cfg(feature = "media")]

//! Phase 11 Plan #5 Task 3 — PartialFailure outcome E2E.
//!
//! Three clips × three tags; SECOND tag's only clip points at a
//! missing recording file. Exercises the per-tag loop's
//! `Ok(Err(other))` arm at `bus.rs:2870-2892`: emits `tag.failed` +
//! `batch.failed (reason=tag_failed)`, sets `final_outcome =
//! Some(ExportRunOutcome::PartialFailure { ... })`, then `break 'outer`
//! — third tag never starts. Validates fix #24 via negative-timeout.
//!
//! Forcing function: mutate `clip.recording_filename` to `"missing.mov"`
//! between quit and relaunch — `filesrc` errors at preroll →
//! `ExportError::StateChange("preroll: ...")`. adv-fix #5: do NOT
//! substring-match the error. adv-fix #2: `bad - <project>.mp4` is
//! absent OR < 1 KB (only `Cancelled` deletes partials). adv-fix #7:
//! body wrapped in guaranteed-quit shape.

mod common;

use std::time::Duration;
use tempfile::TempDir;

use common::{launch_with_first_source, quit_and_mutate_project, record_clip_at_playhead};

#[tokio::test]
async fn export_partial_failure_completes_first_tag_fails_second_skips_third() -> anyhow::Result<()>
{
    let project_name = "phase11-partial-test";
    let parent = TempDir::new()?;

    let mut launched = launch_with_first_source(&parent, project_name).await?;

    // Three back-to-back clips (~1.2s each, same flow as Task 2).
    let _clip_x = record_clip_at_playhead(&mut launched.app, 0.0).await?;
    let _clip_y = record_clip_at_playhead(&mut launched.app, 0.0).await?;
    let _clip_z = record_clip_at_playhead(&mut launched.app, 0.0).await?;

    // Mutate project: clip[0]→good-1, clip[1]→bad+missing.mov, clip[2]→good-2.
    let launched = quit_and_mutate_project(launched, |p| {
        assert_eq!(p.clips.len(), 3, "expected 3 clips, got {}", p.clips.len());
        p.clips[0].tags = vec!["good-1".into()];
        p.clips[1].tags = vec!["bad".into()];
        p.clips[1].recording_filename = "missing.mov".into();
        p.clips[2].tags = vec!["good-2".into()];
    })
    .await?;

    let mut app = launched.app;
    let tmpdir = launched.tmpdir;

    // Dispatch: good-1 → bad → good-2. Explicit filename_template
    // defeats no-placeholders gate (adv-fix #8).
    let output_folder = tmpdir.path().to_string_lossy().into_owned();
    let export = app
        .send(serde_json::json!({
            "cmd": "export_compilations",
            "selections": [
                {"kind": "tag", "name": "good-1"},
                {"kind": "tag", "name": "bad"},
                {"kind": "tag", "name": "good-2"},
            ],
            "output_folder": output_folder,
            "resolution": "r720",
            "quality": "low",
            "codec": "h264",
            "project_name": project_name,
            "filename_template": "{tag} - {project}",
        }))
        .await?;
    anyhow::ensure!(
        export.ok == Some(true),
        "export_compilations dispatch failed: {:?}",
        export.error,
    );

    // Wait events in bus emission order (adv-fix #3 — wait_for_event
    // silently drops non-matching events). Sequence:
    //   batch.started (tag_count=3)
    //   → tag.started "good-1" → tag.completed "good-1"
    //   → tag.started "bad"    → tag.failed   "bad"
    //   → batch.failed (reason=tag_failed, selection=bad)
    //   → 5s negative-timeout: NO third tag.started.
    let result = async {
        let batch_started = app
            .wait_for_event("export.batch.started", Duration::from_secs(5))
            .await?;
        let tc = batch_started
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("batch.started missing tag_count"))?;
        anyhow::ensure!(tc == 3, "expected batch.started tag_count=3, got {tc}");

        let started_good_1 = app
            .wait_for_event("export.tag.started", Duration::from_secs(10))
            .await?;
        let sel = started_good_1
            .other
            .get("selection")
            .and_then(|v| v.as_str());
        anyhow::ensure!(sel == Some("good-1"), "tag.started selection: {sel:?}");
        let completed_good_1 = app
            .wait_for_event("export.tag.completed", Duration::from_secs(60))
            .await?;
        let sel = completed_good_1
            .other
            .get("selection")
            .and_then(|v| v.as_str());
        anyhow::ensure!(sel == Some("good-1"), "tag.completed selection: {sel:?}");
        let frames = completed_good_1
            .other
            .get("frames_pushed")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("tag.completed missing frames_pushed"))?;
        anyhow::ensure!(
            frames >= 15,
            "expected >=15 frames for good-1, got {frames}"
        );

        let started_bad = app
            .wait_for_event("export.tag.started", Duration::from_secs(10))
            .await?;
        let sel = started_bad.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(sel == Some("bad"), "tag.started selection: {sel:?}");
        let failed_bad = app
            .wait_for_event("export.tag.failed", Duration::from_secs(60))
            .await?;
        let sel = failed_bad.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(sel == Some("bad"), "tag.failed selection: {sel:?}");
        // adv-fix #5: non-empty error only; Display of
        // ExportError::StateChange carries no path/element info.
        // `error` is a top-level Frame field, not nested in `other`.
        let err = failed_bad
            .error
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("tag.failed missing error"))?;
        anyhow::ensure!(!err.is_empty(), "tag.failed.error is empty");

        let batch_failed = app
            .wait_for_event("export.batch.failed", Duration::from_secs(10))
            .await?;
        let reason = batch_failed.other.get("reason").and_then(|v| v.as_str());
        anyhow::ensure!(
            reason == Some("tag_failed"),
            "batch.failed reason: {reason:?}"
        );
        let sel = batch_failed.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(sel == Some("bad"), "batch.failed selection: {sel:?}");

        // Negative assertion: NO third tag.started within 5s.
        // adv-fix #7: regression arm returns Err(...) not panic!.
        match tokio::time::timeout(
            Duration::from_secs(5),
            app.wait_for_event("export.tag.started", Duration::from_secs(5)),
        )
        .await
        {
            Err(_elapsed) => {}
            Ok(Err(_inner)) => {}
            Ok(Ok(frame)) => {
                let sel = frame.other.get("selection").and_then(|v| v.as_str());
                anyhow::bail!(
                    "regression: third tag.started fired after batch.failed; selection={sel:?}",
                );
            }
        }

        // File-existence assertions.
        let path_good_1 = tmpdir.path().join(format!("good-1 - {project_name}.mp4"));
        let path_bad = tmpdir.path().join(format!("bad - {project_name}.mp4"));
        let path_good_2 = tmpdir.path().join(format!("good-2 - {project_name}.mp4"));
        anyhow::ensure!(
            path_good_1.exists(),
            "expected good-1 output at {} (fix #36)",
            path_good_1.display(),
        );
        // adv-fix #2: absent OR < 1 KB.
        if path_bad.exists() {
            let size = std::fs::metadata(&path_bad)?.len();
            anyhow::ensure!(
                size < 1_024,
                "expected bad absent or <1 KB, got {size} B at {}",
                path_bad.display(),
            );
        }
        anyhow::ensure!(
            !path_good_2.exists(),
            "expected good-2 NOT written (skipped after break 'outer); found {}",
            path_good_2.display(),
        );

        Ok::<_, anyhow::Error>(())
    }
    .await;

    // adv-fix #7: guaranteed-quit shape.
    let _ = app.quit().await;
    result
}
