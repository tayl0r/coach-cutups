#![cfg(feature = "media")]

//! Phase 11 Plan #5 Task 2 — multi-tag batch compilation export E2E.
//!
//! Three clips × two tags (with overlap on clip B) + AllClips, in one
//! batch dispatch. Exercises:
//! - `bus.rs::handle_export_compilations` per-tag loop iterating >1
//!   time (lines 2625-2916).
//! - `TagSelection::AllClips` resolution to `Project::all_clips_compilation_plan`
//!   alongside named-tag resolution.
//! - Bus emission order: batch.started → 3 × (tag.started → tag.completed)
//!   → batch.completed (per adv-fix #3 — wait_for_event silently DROPS
//!   non-matching events, so the test mirrors emission order exactly).
//!
//! Per adv-fix #4 the `tag_count` field on batch.started / batch.completed
//! is named `tag_count`, NOT `total_tags`. Per adv-fix #7 the body is
//! wrapped in the guaranteed-quit shape.

mod common;

use std::time::Duration;
use tempfile::TempDir;

use common::{launch_with_first_source, quit_and_mutate_project, record_clip_at_playhead};

#[tokio::test]
async fn export_multi_tag_batch_writes_three_mp4s() -> anyhow::Result<()> {
    let project_name = "phase11-multi-tag-test";
    let parent = TempDir::new()?;

    // 1. Launch + new_project + add source-1080p as source[0]. Single
    //    source — the multi-source path is Task 1's job; this test is
    //    purely about the per-tag loop iterating >1 time.
    let mut launched = launch_with_first_source(&parent, project_name).await?;

    // 2. Three back-to-back clips × ~1.2s each (record_clip_at_playhead's
    //    internal sleep matches export_smoke.rs). Total wall ≈ 3 × 1.2s
    //    plus control-socket round trips.
    let _clip_x = record_clip_at_playhead(&mut launched.app, 0.0).await?;
    let _clip_y = record_clip_at_playhead(&mut launched.app, 0.0).await?;
    let _clip_z = record_clip_at_playhead(&mut launched.app, 0.0).await?;

    // 3. Quit, mutate project.json: clips[0].tags=["a"],
    //    clips[1].tags=["a","b"], clips[2].tags=["b"]. Sanity-check the
    //    clip count first so a future bus refactor changing record-flow
    //    output fails loudly here.
    let launched = quit_and_mutate_project(launched, |p| {
        assert_eq!(p.clips.len(), 3, "expected 3 clips, got {}", p.clips.len());
        p.clips[0].tags = vec!["a".into()];
        p.clips[1].tags = vec!["a".into(), "b".into()];
        p.clips[2].tags = vec!["b".into()];
    })
    .await?;

    let mut app = launched.app;
    let tmpdir = launched.tmpdir;

    // 4. Dispatch ExportCompilations with three selections in dispatch
    //    order: Tag "a" → Tag "b" → AllClips. The bus iterates selections
    //    in dispatch order; the wait sequence below mirrors that exactly.
    let output_folder = tmpdir.path().to_string_lossy().into_owned();
    let export = app
        .send(serde_json::json!({
            "cmd": "export_compilations",
            "selections": [
                {"kind": "tag", "name": "a"},
                {"kind": "tag", "name": "b"},
                {"kind": "all_clips"},
            ],
            "output_folder": output_folder,
            "resolution": "r720",
            "quality": "low",
            "codec": "h264",
            "project_name": project_name,
            "filename_template": "{tag} - {project}",
            // Phase 11 Plan #6 Task 0 (adv-fix #4). Pin OverwriteAll
            // so the multi-tag smoke isn't subject to the new
            // Plan-#6 Resume default; this test's frames_pushed
            // assertions assume every tag re-encodes.
            "overwrite_policy": "overwriteAll",
        }))
        .await?;
    anyhow::ensure!(
        export.ok == Some(true),
        "export_compilations dispatch failed: {:?}",
        export.error,
    );

    // 5. Wait events in bus emission order (per adv-fix #3,
    //    wait_for_event silently DROPS non-matching events — mirror
    //    emission order exactly). Sequence:
    //      batch.started (tag_count=3)
    //      → tag.started "a" → tag.completed "a"
    //      → tag.started "b" → tag.completed "b"
    //      → tag.started "all-clips" → tag.completed "all-clips"
    //      → batch.completed (tag_count=3)
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

        for expected_selection in ["a", "b", "all-clips"] {
            let started = app
                .wait_for_event("export.tag.started", Duration::from_secs(10))
                .await?;
            let sel = started.other.get("selection").and_then(|v| v.as_str());
            anyhow::ensure!(
                sel == Some(expected_selection),
                "expected tag.started selection={expected_selection:?}, got {sel:?}",
            );

            // 60s budget per tag (matches Task 1 + export_smoke.rs).
            let completed = app
                .wait_for_event("export.tag.completed", Duration::from_secs(60))
                .await?;
            let sel = completed.other.get("selection").and_then(|v| v.as_str());
            anyhow::ensure!(
                sel == Some(expected_selection),
                "expected tag.completed selection={expected_selection:?}, got {sel:?}",
            );
            let frames_pushed = completed
                .other
                .get("frames_pushed")
                .and_then(|v| v.as_i64())
                .ok_or_else(|| anyhow::anyhow!("tag.completed missing frames_pushed"))?;
            // Plan floor: 0.8s × 30 fps × lavapipe margin → 15.
            anyhow::ensure!(
                frames_pushed >= 15,
                "expected ≥15 frames pushed for tag {expected_selection:?}, got {frames_pushed}",
            );
        }

        let batch_completed = app
            .wait_for_event("export.batch.completed", Duration::from_secs(10))
            .await?;
        let tc = batch_completed
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("batch.completed missing tag_count"))?;
        anyhow::ensure!(tc == 3, "expected batch.completed tag_count=3, got {tc}");

        // 6. Three .mp4 files exist on disk with the templated names.
        let path_a = tmpdir.path().join(format!("a - {project_name}.mp4"));
        let path_b = tmpdir.path().join(format!("b - {project_name}.mp4"));
        let path_all = tmpdir
            .path()
            .join(format!("all-clips - {project_name}.mp4"));
        for p in [&path_a, &path_b, &path_all] {
            anyhow::ensure!(p.exists(), "expected output .mp4 at {}", p.display());
        }

        // 7. AllClips covers 3 clips; per-tag covers 2. AllClips file
        //    must be ≥ each per-tag file by at least 20 KB. Floor avoids
        //    flakiness from encoder-QP variance on identical content.
        let size_a = std::fs::metadata(&path_a)?.len();
        let size_b = std::fs::metadata(&path_b)?.len();
        let size_all = std::fs::metadata(&path_all)?.len();
        anyhow::ensure!(
            size_all >= size_a + 20_000,
            "expected AllClips ({size_all} B) ≥ tag-a ({size_a} B) + 20 KB",
        );
        anyhow::ensure!(
            size_all >= size_b + 20_000,
            "expected AllClips ({size_all} B) ≥ tag-b ({size_b} B) + 20 KB",
        );

        Ok::<_, anyhow::Error>(())
    }
    .await;

    // 8. Per adv-fix #7: guaranteed-quit shape so a panic / regression
    //    doesn't leak the Slint subprocess + GStreamer fixture handle.
    let _ = app.quit().await;
    result
}
