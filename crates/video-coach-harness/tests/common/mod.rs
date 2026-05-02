#![cfg(feature = "media")]
#![allow(dead_code)]

//! Phase 11 Plan #5 (coverage-hardening) — shared test helpers for the
//! multi-source / multi-tag / PartialFailure E2E tests in Tasks 1-3.
//!
//! ## Four contracts every caller MUST internalize
//!
//! 1. **`App::wait_for_event` silently DISCARDS non-matching events.** Per
//!    `harness/src/lib.rs:189-198`, the inner `recv().await` loop does NOT
//!    push non-matching events back into `pending`. A test that calls
//!    `wait_for_event("export.tag.completed", ...)` while a `tag.failed`
//!    is en-route silently drops the failure event and deadlocks (until
//!    timeout) on the `.completed` that will never come. Each caller's
//!    body MUST mirror the bus's exact emission order — no out-of-order
//!    waits. (Adv-fix #3.)
//!
//! 2. **The recording flow always sets `clip.source_index = 0`** —
//!    hard-coded at `bus.rs::StartClipRecording` line 1539
//!    (`let source_index = 0_usize;`, with the inline comment "MVP:
//!    sourceVideos[0]. Phase 7.5+ will track an active index when
//!    multi-source lands"). And `add_source_video` against an
//!    already-open project does NOT remount the player onto the new
//!    source — `try_spawn_current_player` at `bus.rs:3022` early-returns
//!    on `current_player.is_some()`, so the second source-add fires
//!    `source.added` ONLY (no `player.opened`). The v2 player has no
//!    source-swap command yet — this is by design. Multi-source tests
//!    work around both halves by recording N clips against source 0,
//!    then hand-mutating `clips[i].source_index` via
//!    `quit_and_mutate_project` so the relaunched export sees distinct
//!    `source_index` values. Do NOT "fix" this hand-mutation; the
//!    production-code defect is a Phase 12 candidate. (Adv-fixes #1, #6.)
//!
//! 3. **Hand-mutation of `project.json` is the ONLY way to inject tags
//!    or to swap a clip's `recording_filename` to a missing path.** The
//!    bus exposes recording, preview, export, source-add, and project
//!    lifecycle commands — but no `Command::SetClipTags`,
//!    `Command::SetClipSourceIndex`, etc. (tag editing is UI-only via
//!    Slint). `quit_and_mutate_project` quits the app, calls
//!    `project_store::read` + `mutate(&mut Project)` + `project_store
//!    ::write`, then relaunches and re-opens. There's no race — the
//!    mutator runs only after the child process has fully exited.
//!
//! 4. **Each test must use a guaranteed-quit shape.** `App` has no
//!    `Drop` impl; a test panic mid-export leaks the child Slint
//!    subprocess + the GStreamer fixture handle, which on Windows
//!    blocks `TempDir` cleanup with "directory not empty". Callers
//!    structure their bodies as:
//!
//!    ```ignore
//!    let result = async {
//!        // … all assertions here …
//!        Ok::<_, anyhow::Error>(())
//!    }.await;
//!    let _ = app.quit().await; // best-effort, ignore quit errors
//!    result?;
//!    ```
//!
//!    `wait_export_then_quit` codifies this for the simple "wait for
//!    batch end + quit" case. Tests that need negative assertions (e.g.
//!    Task 3's "no third tag.started fires") build the wrapper inline
//!    and return `Err(...)` from the inner block on regression instead
//!    of `panic!`. (Adv-fix #7.)

use std::path::{Path, PathBuf};
use std::time::Duration;
use tempfile::TempDir;
use uuid::Uuid;
use video_coach_core::project::Project;
use video_coach_core::project_store;
use video_coach_harness::{App, LaunchOptions};

/// Path to the canonical 1080p H.264 source fixture.
pub fn fixture_1080p() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures/source-1080p.mp4");
    p.canonicalize().expect("fixtures/source-1080p.mp4 exists")
}

/// Path to the second-source 4K H.264 fixture (manifest "purpose":
/// "a distinct second source asset for multi-source-video project tests").
pub fn fixture_4k() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures/source-4k.mp4");
    p.canonicalize().expect("fixtures/source-4k.mp4 exists")
}

/// Path to the webcam fixture replayed by `FixtureSource` in place of a
/// real camera capture during recording.
pub fn webcam_fixture() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures/webcam.mov");
    p.canonicalize().expect("fixtures/webcam.mov exists")
}

/// Common `LaunchOptions` setup: routes `start_clip_recording` through
/// `FixtureSource(webcam.mov)` instead of the platform default camera.
/// Required for any test that records clips in CI / on a sandboxed
/// runner without a real webcam.
pub fn default_launch_options() -> LaunchOptions {
    LaunchOptions {
        fixture_recording_source: Some(webcam_fixture().to_string_lossy().into_owned()),
    }
}

/// A launched app + the project folder it has open + an RAII export
/// tempdir that survives `quit_and_mutate_project`'s relaunch.
pub struct LaunchedProject {
    pub app: App,
    pub project_path: PathBuf,
    /// Per-test export-output tempdir. Held here so it cleans up at
    /// end-of-test rather than at the parent `TempDir`'s drop. Public
    /// so callers can `&launched.tmpdir.path()`-style it into the
    /// `output_folder` field of an `ExportCompilations` dispatch.
    pub tmpdir: TempDir,
}

/// Launch the app, create a new project under `parent/<project_name>`,
/// add the 1080p fixture as source[0], and wait for the player to mount.
///
/// Mirrors `export_smoke.rs::launch_record_and_open` lines 38-100, but
/// stops AFTER `player.opened` (no clip recording yet — caller drives
/// recording explicitly via `record_clip_at_playhead` so multi-clip
/// tests can stack more than one).
pub async fn launch_with_first_source(
    parent: &TempDir,
    project_name: &str,
) -> anyhow::Result<LaunchedProject> {
    let source = fixture_1080p();

    let project_path = parent.path().join(project_name);
    std::fs::create_dir(&project_path)?;
    let tmpdir = TempDir::new()?;

    let mut app = App::launch_with_options(default_launch_options()).await?;

    let create = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    anyhow::ensure!(
        create.ok == Some(true),
        "new_project failed: {:?}",
        create.error,
    );
    app.wait_for_event("project.opened", Duration::from_secs(2))
        .await?;

    let add = app
        .send(serde_json::json!({
            "cmd": "add_source_video",
            "absolute_path": source.to_string_lossy(),
        }))
        .await?;
    anyhow::ensure!(
        add.ok == Some(true),
        "add_source_video failed: {:?}",
        add.error,
    );
    // First source on a fresh project: `try_spawn_current_player`
    // (bus.rs:3022) DOES open a player here, so both events fire.
    app.wait_for_event("source.added", Duration::from_secs(5))
        .await?;
    app.wait_for_event("player.opened", Duration::from_secs(5))
        .await?;

    Ok(LaunchedProject {
        app,
        project_path,
        tmpdir,
    })
}

/// Send `add_source_video` against an already-open project.
///
/// **Awaits `source.added` ONLY** — per adv-fixes #1 / #6, the bus's
/// add-source codepath is a no-op for player remount when a player is
/// already mounted (`try_spawn_current_player` early-returns at
/// `bus.rs:3022` on `current_player.is_some()`), so NO `player.opened`
/// event fires for a second-or-later source-add. This is by design:
/// v2 has no source-swap command yet. A caller that waits for
/// `player.opened` here will deadlock until the timeout.
pub async fn add_second_source(app: &mut App, second_source: &Path) -> anyhow::Result<()> {
    let add = app
        .send(serde_json::json!({
            "cmd": "add_source_video",
            "absolute_path": second_source.to_string_lossy(),
        }))
        .await?;
    anyhow::ensure!(
        add.ok == Some(true),
        "add_source_video failed: {:?}",
        add.error,
    );
    app.wait_for_event("source.added", Duration::from_secs(5))
        .await?;
    // DO NOT wait for player.opened — bus.rs:3022 returns early when a
    // player is already mounted.
    Ok(())
}

/// Record one clip at the given playhead. Sleeps ~1.2s so the
/// recording produces enough frames for a downstream export to walk
/// through (matches `export_smoke.rs`'s 1.2s record window).
///
/// Returns the clip's `Uuid` parsed from `clip_recording.started`'s
/// `clip_id` field. Falls back to `Uuid::nil()` if the event lacks a
/// `clip_id` field or if the value isn't a parseable UUID — production
/// always emits a valid UUID (see `bus.rs:1611`), but the fallback
/// keeps the helper from panicking on a hypothetical schema regression.
/// Callers that genuinely need the UUID should assert it's not nil
/// after the call.
pub async fn record_clip_at_playhead(app: &mut App, playhead: f64) -> anyhow::Result<Uuid> {
    let start = app
        .send(serde_json::json!({
            "cmd": "start_clip_recording",
            "playhead_snapshot_seconds": playhead,
        }))
        .await?;
    anyhow::ensure!(
        start.ok == Some(true),
        "start_clip_recording failed: {:?}",
        start.error,
    );
    let started = app
        .wait_for_event("clip_recording.started", Duration::from_secs(10))
        .await?;
    let clip_id = started
        .other
        .get("clip_id")
        .and_then(|v| v.as_str())
        .and_then(|s| Uuid::parse_str(s).ok())
        .unwrap_or(Uuid::nil());

    tokio::time::sleep(Duration::from_millis(1200)).await;

    let stop = app
        .send(serde_json::json!({"cmd": "stop_clip_recording"}))
        .await?;
    anyhow::ensure!(
        stop.ok == Some(true),
        "stop_clip_recording failed: {:?}",
        stop.error,
    );
    app.wait_for_event("clip_recording.stopped", Duration::from_secs(10))
        .await?;

    Ok(clip_id)
}

/// Quit the app, hand-mutate `project.json` via `project_store::{read,
/// write}`, relaunch, send `OpenProject`, and wait for `project.opened`.
///
/// Returns a fresh `LaunchedProject` carrying the new `App` + the
/// original `project_path` + the original export `tmpdir` (so the
/// caller's `output_folder` PathBuf stays valid across the relaunch).
///
/// Sequence: quit → fs read project.json → mutate → fs write →
/// re-`launch_with_options` (with the same fixture-recording source
/// per `default_launch_options`) → `OpenProject` → wait `project.opened`.
/// There's no race: `app.quit().await` blocks on the child process exit
/// before the read+write run.
pub async fn quit_and_mutate_project(
    launched: LaunchedProject,
    mutate: impl FnOnce(&mut Project),
) -> anyhow::Result<LaunchedProject> {
    let LaunchedProject {
        app,
        project_path,
        tmpdir,
    } = launched;
    app.quit().await?;

    let mut project = project_store::read(&project_path)?;
    mutate(&mut project);
    project_store::write(&project, &project_path)?;

    let mut app = App::launch_with_options(default_launch_options()).await?;
    let open = app
        .send(serde_json::json!({
            "cmd": "open_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    anyhow::ensure!(
        open.ok == Some(true),
        "open_project failed: {:?}",
        open.error,
    );
    app.wait_for_event("project.opened", Duration::from_secs(5))
        .await?;

    Ok(LaunchedProject {
        app,
        project_path,
        tmpdir,
    })
}

/// Wait for one of `export.batch.{completed,failed,cancelled}` —
/// whichever fires first — then quit the app (consuming it).
///
/// Useful for the simple "wait for batch end + clean up" case at the
/// tail of Task 1's success-path test. Tasks 2 + 3 wait on more
/// granular events inline (per the bus's emission-order contract,
/// adv-fix #3) and then call `app.quit().await` themselves inside the
/// guaranteed-quit wrapper.
///
/// `export_dir` is accepted for symmetry / future assertions but
/// currently unused — file-existence checks are the caller's job.
pub async fn wait_export_then_quit(mut app: App, _export_dir: &Path) -> anyhow::Result<()> {
    // Drain events until ANY of the three batch-end events arrives.
    // `wait_for_event` would deadlock-on-timeout if we picked one and
    // the other fired (drop-on-mismatch, adv-fix #3). The hand-rolled
    // loop here matches whichever lands first.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let frame = tokio::time::timeout(remaining, app.next_event())
            .await
            .map_err(|_| anyhow::anyhow!("timed out waiting for export.batch.* end event"))?
            .ok_or_else(|| anyhow::anyhow!("event channel closed before batch ended"))?;
        if let Some(name) = frame.event.as_deref() {
            if matches!(
                name,
                "export.batch.completed" | "export.batch.failed" | "export.batch.cancelled"
            ) {
                break;
            }
        }
    }
    app.quit().await?;
    Ok(())
}
