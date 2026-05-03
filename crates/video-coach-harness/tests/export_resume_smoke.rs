#![cfg(feature = "media")]

//! Phase 11 Plan #6 Task 3 — resume-mode skip-on-exists E2E.
//!
//! Records a single clip, hand-mutates the project to attach the tag
//! "drills", then runs `Command::ExportCompilations` twice on the SAME
//! launched app with `overwrite_policy: "resume"` (Plan #6 default —
//! pinned explicitly so the test isn't sensitive to a future default
//! flip).
//!
//! Run 1 must produce the .mp4 and emit the canonical
//! `tag.started → tag.completed → batch.completed` sequence. Run 2 —
//! issued without quitting (the bus's per-export state is fully reset
//! between batches) — must hit the skip-on-exists branch and emit
//! `export.tag.skipped { selection: "drills", reason: "already_exists" }`
//! while leaving the .mp4's bytes byte-for-byte unchanged
//! (`metadata.len()` + `metadata.modified()`). Adv-fix #1: the skip
//! path bumps `completed_tags` so the batch ends with `tag_count=1`,
//! NOT 0.
//!
//! Body wrapped in the Plan #5 guaranteed-quit shape (anyhow::ensure!
//! inside the inner async block, then explicit `app.quit().await`,
//! then `result?`) so a mid-test failure can't leak the child Slint
//! subprocess.

mod common;

use std::time::Duration;
use tempfile::TempDir;

use common::{launch_with_first_source, quit_and_mutate_project, record_clip_at_playhead};

#[tokio::test]
async fn export_resume_skips_existing_tag_on_second_run() -> anyhow::Result<()> {
    let project_name = "phase11-resume-test";
    let parent = TempDir::new()?;

    let mut launched = launch_with_first_source(&parent, project_name).await?;

    // One clip, then quit-mutate to attach the "drills" tag (the bus
    // exposes no SetClipTags command — UI-only — so hand-mutation via
    // project_store is the canonical injection path; see common/mod.rs
    // contract #3).
    let _clip = record_clip_at_playhead(&mut launched.app, 0.0).await?;
    let launched = quit_and_mutate_project(launched, |p| {
        assert_eq!(p.clips.len(), 1, "expected 1 clip, got {}", p.clips.len());
        p.clips[0].tags = vec!["drills".into()];
    })
    .await?;

    let mut app = launched.app;
    let tmpdir = launched.tmpdir;
    let output_folder = tmpdir.path().to_string_lossy().into_owned();
    let output_path = tmpdir.path().join(format!("drills - {project_name}.mp4"));

    // The same dispatch payload runs both times — `overwrite_policy:
    // "resume"` is the Plan #6 default but we pin it so this test
    // remains a Resume-path regression check even if the default ever
    // flips. Pre-Plan-#7 default template `"{tag} - {project}"`
    // reproduces the Phase 10 output filename byte-for-byte.
    let dispatch = serde_json::json!({
        "cmd": "export_compilations",
        "selections": [{"kind": "tag", "name": "drills"}],
        "output_folder": output_folder,
        "resolution": "r720",
        "quality": "low",
        "codec": "h264",
        "project_name": project_name,
        "filename_template": "{tag} - {project}",
        "overwrite_policy": "resume",
    });

    let result = async {
        // ── Run 1 — fresh encode. ──────────────────────────────────────
        let export = app.send(dispatch.clone()).await?;
        anyhow::ensure!(
            export.ok == Some(true),
            "run 1 export_compilations dispatch failed: {:?}",
            export.error,
        );

        let batch_started = app
            .wait_for_event("export.batch.started", Duration::from_secs(5))
            .await?;
        let tc = batch_started
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("run 1 batch.started missing tag_count"))?;
        anyhow::ensure!(tc == 1, "run 1 batch.started tag_count: {tc}");

        let tag_started = app
            .wait_for_event("export.tag.started", Duration::from_secs(10))
            .await?;
        let sel = tag_started.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(
            sel == Some("drills"),
            "run 1 tag.started selection: {sel:?}"
        );

        let tag_completed = app
            .wait_for_event("export.tag.completed", Duration::from_secs(60))
            .await?;
        let frames = tag_completed
            .other
            .get("frames_pushed")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("run 1 tag.completed missing frames_pushed"))?;
        anyhow::ensure!(
            frames >= 15,
            "run 1 expected >=15 frames pushed, got {frames}"
        );

        let batch_completed = app
            .wait_for_event("export.batch.completed", Duration::from_secs(10))
            .await?;
        let tc = batch_completed
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("run 1 batch.completed missing tag_count"))?;
        anyhow::ensure!(tc == 1, "run 1 batch.completed tag_count: {tc}");

        // File-shape sanity (validates the structural intactness check
        // that run 2 will rely on: size > 50 KB AND ftyp@4 AND moov in
        // tail).
        anyhow::ensure!(
            output_path.exists(),
            "run 1 expected output at {}",
            output_path.display(),
        );
        let first_metadata = std::fs::metadata(&output_path)?;
        let first_size = first_metadata.len();
        let first_mtime = first_metadata.modified()?;
        anyhow::ensure!(
            first_size > 50_000,
            "run 1 expected output > 50 KB, got {first_size} B at {}",
            output_path.display(),
        );

        // ── Run 2 — skip-on-exists. ────────────────────────────────────
        // Same app, same dispatch. Bus's per-export state is fully
        // reset between batches; no quit needed.
        let export = app.send(dispatch.clone()).await?;
        anyhow::ensure!(
            export.ok == Some(true),
            "run 2 export_compilations dispatch failed: {:?}",
            export.error,
        );

        let batch_started = app
            .wait_for_event("export.batch.started", Duration::from_secs(5))
            .await?;
        let tc = batch_started
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("run 2 batch.started missing tag_count"))?;
        anyhow::ensure!(tc == 1, "run 2 batch.started tag_count: {tc}");

        // The skip event MUST fire before any tag.started. (If the bus
        // emitted tag.started on run 2 we'd be re-encoding — Plan #6
        // contract violation.)
        let skipped = app
            .wait_for_event("export.tag.skipped", Duration::from_secs(10))
            .await?;
        let sel = skipped.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(
            sel == Some("drills"),
            "run 2 tag.skipped selection: {sel:?}"
        );
        let reason = skipped.other.get("reason").and_then(|v| v.as_str());
        anyhow::ensure!(
            reason == Some("already_exists"),
            "run 2 tag.skipped reason: {reason:?} (expected \"already_exists\")"
        );

        // Adv-fix #1: skipped tag bumps completed_tags, so
        // batch.completed reports tag_count=1 (NOT 0).
        let batch_completed = app
            .wait_for_event("export.batch.completed", Duration::from_secs(10))
            .await?;
        let tc = batch_completed
            .other
            .get("tag_count")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("run 2 batch.completed missing tag_count"))?;
        anyhow::ensure!(
            tc == 1,
            "run 2 batch.completed tag_count: {tc} (expected 1; adv-fix #1 contract)"
        );

        // File invariance: skip path does NOT touch the .mp4. Size +
        // mtime equality is the canonical witness — the bus's skip
        // branch performs zero writes against `output_path`, so even on
        // filesystems with coarse mtime resolution (NTFS 100 ns, some
        // ext4 setups: seconds), the assertion holds because nothing
        // updated the inode at all.
        let second_metadata = std::fs::metadata(&output_path)?;
        anyhow::ensure!(
            second_metadata.len() == first_size,
            "run 2 expected output size unchanged ({first_size} B), got {} B",
            second_metadata.len(),
        );
        anyhow::ensure!(
            second_metadata.modified()? == first_mtime,
            "run 2 expected output mtime unchanged (skip path performs no writes)"
        );

        Ok::<_, anyhow::Error>(())
    }
    .await;

    // Plan #5 guaranteed-quit shape: best-effort quit, then propagate
    // the inner result. A panic mid-test would otherwise leak the
    // Slint subprocess + GStreamer fixture handle, blocking TempDir
    // cleanup on Windows.
    let _ = app.quit().await;
    result
}
