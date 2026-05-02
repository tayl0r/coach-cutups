#![cfg(feature = "media")]

//! Phase 11 Plan #5 Task 1 — multi-source compilation export E2E.
//!
//! Two sources, two clips, one tag — exercises:
//! - `bus.rs::handle_add_source_video` second-source path (source.added
//!   only, no player.opened — adv-fixes #1, #6).
//! - `bus.rs::handle_export_compilations` for a single-tag dispatch.
//! - `export.rs:208-222` `referenced_source_indices` building >1
//!   `SourceVideoChain` when the plan references two distinct
//!   `source_index` values.
//! - `export.rs:1367-1524` `transition_to_source_chain` PAUSED↔PLAYING
//!   flip (fix #19/#27 — pause-when-inactive multi-source dedup).
//!
//! The recording flow at `bus.rs::StartClipRecording` line 1539 hardcodes
//! `source_index = 0`, so both clips are recorded against source[0]. Per
//! adv-fix #1 we hand-mutate `clips[1].source_index = 1` via
//! `quit_and_mutate_project` so the relaunched export sees two distinct
//! source indices and exercises the multi-source decoder path. The
//! recording bytes are unchanged — both clips are FixtureSource replays
//! of `webcam.mov` regardless of which source they nominally reference.
//!
//! ## Why `#[ignore]`
//!
//! Running this test against the real fixtures surfaces a production bug
//! in `crates/video-coach-compositor/src/compositor.rs:115-128`: the
//! compositor requests a wgpu device with `Limits::downlevel_defaults()`,
//! whose `max_texture_dimension_2d = 2048`. The second source fixture
//! (`source-4k.mp4`, 3840x2160) exceeds this limit, so the compose pass
//! at `compositor.rs:147` (`create_texture_with_data` with `label =
//! "source"`) panics inside the spawned export task with
//!
//! ```text
//! wgpu error: Validation Error
//!   In Device::create_texture, label = 'source'
//!     Dimension X value 3840 exceeds the limit of 2048
//! ```
//!
//! The bus-task surface is `export.tag.failed` with
//! `error = "export task panicked: …"`, then `export.batch.failed` with
//! `reason = "panic"`.
//!
//! Plan #5 is TESTS-ONLY (per "What Phase 11 Plan #5 deliberately does
//! NOT include" item 1: "If a test forces a real bug to surface … the
//! implementer STOPS and reports — the fix lives in a separate plan").
//! Raising the compositor's `max_texture_dimension_2d` to (say)
//! `8192` or sizing it from the first source's dimensions is the
//! follow-up fix; until that lands this test cannot pass against
//! `source-4k.mp4` and is gated behind `#[ignore]`. Local runs with the
//! follow-up fix can `cargo test … -- --ignored` to verify the harness
//! end-to-end.
//!
//! See also: `crates/video-coach-media/src/export.rs:208-222` and
//! `:1367-1524` — the multi-source decoder dedup + PAUSED↔PLAYING flip
//! that this test was designed to exercise. Once the compositor fix
//! lands, this test will exercise both.

mod common;

use std::time::Duration;
use tempfile::TempDir;

use common::{
    add_second_source, fixture_4k, launch_with_first_source, quit_and_mutate_project,
    record_clip_at_playhead,
};

#[tokio::test]
#[ignore = "blocked on compositor wgpu max_texture_dimension_2d limit (2048) < source-4k.mp4 width (3840); see file header"]
async fn export_multi_source_compilation_writes_one_mp4() -> anyhow::Result<()> {
    let project_name = "phase11-multi-source-test";
    let parent = TempDir::new()?;

    // 1. Launch + new_project + add source[0] (1080p) + wait player.opened.
    let mut launched = launch_with_first_source(&parent, project_name).await?;

    // 2. Clip A — recorded against source[0] (the only mounted player).
    let _clip_a = record_clip_at_playhead(&mut launched.app, 0.0).await?;

    // 3. Add source[1] (4k). Per adv-fix #1/#6: source.added fires; NO
    //    player.opened — try_spawn_current_player at bus.rs:3022
    //    early-returns when a player is already mounted.
    add_second_source(&mut launched.app, &fixture_4k()).await?;

    // 4. Clip B — STILL recorded against source[0] because
    //    bus.rs::StartClipRecording line 1539 hardcodes source_index = 0.
    //    The hand-mutation below sets clips[1].source_index = 1 so the
    //    export sees two distinct indices.
    let _clip_b = record_clip_at_playhead(&mut launched.app, 0.0).await?;

    // 5. Quit, mutate project.json: tag both clips with "drills" AND
    //    flip clips[1].source_index to 1 so build_referenced_source_chains
    //    builds two SourceVideoChains and the driver exercises the
    //    PAUSED↔PLAYING flip.
    let launched = quit_and_mutate_project(launched, |p| {
        // Sanity: the bus's record-flow appended exactly two clips. If
        // a future refactor changes that, fail loudly here instead of
        // silently exporting the wrong shape.
        assert_eq!(p.clips.len(), 2, "expected 2 clips, got {}", p.clips.len());
        for clip in &mut p.clips {
            clip.tags = vec!["drills".into()];
        }
        // Per adv-fix #1: hand-mutate clips[1].source_index to 1 so the
        // export's referenced_source_indices set has two entries —
        // exercising export.rs:208-222 multi-chain build +
        // export.rs:1367-1524 PAUSED↔PLAYING transition. Without this,
        // bus.rs:1539's hardcoded source_index=0 would mean both clips
        // share one decoder chain and we'd only exercise the
        // single-source path.
        p.clips[1].source_index = 1;
    })
    .await?;

    let mut app = launched.app;
    let tmpdir = launched.tmpdir;

    // 6. Dispatch ExportCompilations against the "drills" tag.
    let output_folder = tmpdir.path().to_string_lossy().into_owned();
    let export = app
        .send(serde_json::json!({
            "cmd": "export_compilations",
            "selections": [{"kind": "tag", "name": "drills"}],
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

    // 7. Wait events in bus emission order (per adv-fix #3,
    //    wait_for_event silently DROPS non-matching events — mirror
    //    the bus order exactly). Per the plan body sketch:
    //    batch.started → tag.started("drills") → tag.completed("drills")
    //    → batch.completed.
    let result = async {
        let _batch_started = app
            .wait_for_event("export.batch.started", Duration::from_secs(5))
            .await?;
        let tag_started = app
            .wait_for_event("export.tag.started", Duration::from_secs(10))
            .await?;
        let selection = tag_started.other.get("selection").and_then(|v| v.as_str());
        anyhow::ensure!(
            selection == Some("drills"),
            "expected tag.started selection=\"drills\", got {selection:?}",
        );

        // Two ~1.2s clips on lavapipe export in ~12-25s; 60s headroom
        // matches export_smoke.rs's tag.completed budget. If CI flakes
        // here, raise to 90s — never lower the frames_pushed floor.
        let tag_completed = app
            .wait_for_event("export.tag.completed", Duration::from_secs(60))
            .await?;
        let frames_pushed = tag_completed
            .other
            .get("frames_pushed")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| anyhow::anyhow!("tag.completed missing frames_pushed"))?;
        // Two ~1.2s clips × 30 fps × ~0.5 lavapipe margin ≈ 36; floor at
        // 30 (per plan) — same shape as export_smoke.rs's ≥20 floor
        // scaled for 2× content length.
        anyhow::ensure!(
            frames_pushed >= 30,
            "expected ≥30 frames pushed (2 × ~1.2s × 30fps), got {frames_pushed}",
        );

        let _batch_completed = app
            .wait_for_event("export.batch.completed", Duration::from_secs(10))
            .await?;

        // 8. Output .mp4 exists at the templated path, > 50 KB, ISO BMFF
        //    "ftyp" magic at offset 4 (Phase 10 baseline assertions).
        let expected_path = tmpdir.path().join(format!("drills - {project_name}.mp4"));
        anyhow::ensure!(
            expected_path.exists(),
            "expected output .mp4 at {}",
            expected_path.display(),
        );
        let bytes = std::fs::read(&expected_path)?;
        anyhow::ensure!(
            bytes.len() > 50_000,
            "expected output > 50 KB, got {} bytes at {}",
            bytes.len(),
            expected_path.display(),
        );
        anyhow::ensure!(
            bytes.len() > 8 && &bytes[4..8] == b"ftyp",
            "expected ISO BMFF magic at offset 4, got {:?}",
            bytes.get(4..8),
        );

        Ok::<_, anyhow::Error>(())
    }
    .await;

    // 9. Per adv-fix #7: guaranteed-quit shape so a panic / regression
    //    doesn't leak the Slint subprocess + GStreamer fixture handle
    //    (which on Windows would block TempDir cleanup).
    let _ = app.quit().await;
    result
}
