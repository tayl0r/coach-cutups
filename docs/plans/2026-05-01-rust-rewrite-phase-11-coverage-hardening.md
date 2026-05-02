# Rust Rewrite — Phase 11 Plan #5: Coverage hardening (multi-source / multi-tag / PartialFailure E2Es)

Branch: `rust-rewrite`. Phase 11 is Polish + deferred items from Phase 10's
closeout. This plan fills the three "Coverage gaps (acceptable for shipping)"
called out at the bottom of Phase 10's closeout: multi-source compilation
export E2E, multi-tag batch export E2E, and PartialFailure outcome E2E. It
is a **tests-only** plan — no production code change.

---

## Goal (one paragraph)

Phase 10 shipped multi-source decoder dedup (fix #19/#27 — pause-when-inactive),
the multi-tag sequential export loop (fix #24), and the four-state
`ExportRunOutcome` machine (fix #34) including the `PartialFailure` arm. All
three paths are exercised by unit tests at the `export.rs` and bus-handler
layers, but no harness E2E runs >2 sources, >1 tag in one batch, or forces a
mid-batch tag failure. Plan #5 lands one harness test per gap, plus a small
shared helper module for "build a multi-source / multi-tag project". The
fixtures already include a second source video (`source-4k.mp4`) explicitly
purposed in the manifest as "a distinct second source asset for multi-source-
video project tests" — no LFS upload needed. Defensive backstop for Plan #1
(audio mix) and Plan #6 (resume failed exports), which both touch the
multi-source code path; landing these tests first means those plans can't
silently regress these scenarios.

---

## What Phase 11 Plan #5 deliberately does NOT include

1. **No production code changes.** If a test forces a real bug to surface
   (e.g. multi-source decoder dedup deadlocks under a real two-source plan),
   the implementer STOPS and reports — the fix lives in a separate plan,
   not this one. The test is the deliverable.
2. **No new fixture videos.** `source-4k.mp4` (already LFS-tracked, already
   in `fixtures/manifest.json` since Phase 7) is reused as the second source.
   The manifest's `purpose` field already documents this dual role. If a
   future test genuinely needs a third distinct source we add it then; not
   this plan.
3. **No bus command for tagging clips.** There is no `Command::SetClipTags`
   today (the bus exposes recording, preview, export, source-add, and
   project lifecycle; tag editing is UI-only via Slint). The multi-tag
   tests work around this by editing the on-disk `project.json` directly
   via `video_coach_core::project_store::{read, write}` between a quit and
   a re-launched `OpenProject` — same pattern the test author would use
   to inject any state the bus doesn't expose. Adding a real tag-edit
   command is a UI concern, out of scope.
4. **No `App::Drop` impl.** The harness's `App` struct currently has no
   `Drop` — if a test panics mid-export the child Slint subprocess leaks.
   Documented as a known risk in "Known performance risks" below; tests
   call `app.quit().await?` on every success path and the test runner
   reaps the orphan via SIGCHLD on process exit. A `Drop` impl that
   `child.start_kill()`s on panic is a separate hardening task.
5. **No HEVC variant of these tests.** Phase 11 Plan #1's closeout
   already deferred a Linux x265enc CPU-runtime budget for a HEVC harness
   E2E. Plan #5's tests run H.264 only. If a future plan wants HEVC
   coverage of multi-source / multi-tag, fork these tests with a codec
   parameter then.
6. **No real progress-bar (Plan #2) coverage.** These tests assert on
   `export.tag.completed` / `export.batch.completed` events and the
   `ExportRunOutcome` slot transitions. They do NOT poll the
   `current_tag_progress` / `batch_progress` `f32` fields mid-export —
   that's Plan #2's surface area.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; especially the per-task sections below.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`'s
   "Closeout — Phase 10 SHIPPED" section, in particular the **Coverage
   gaps (acceptable for shipping)** subsection — these are the three
   gaps this plan closes — and the "Adversarial-review fixes baked in"
   list (DO NOT re-raise; especially fix #19/#27 multi-source dedup,
   fix #24 sequential per-tag loop, fix #34 four-state outcome,
   fix #36 Reveal on PartialFailure when completed > 0).
3. `crates/video-coach-harness/tests/export_smoke.rs` — the Phase 10
   baseline E2E. Note `launch_record_and_open` helper (lines 38–103)
   which factors out launch+project+source+record so both `export_full
   _lifecycle` and `export_cancel_deletes_partial_output` can share it.
   Plan #5 extends this pattern — see Task 0.
4. `crates/video-coach-harness/tests/preview_clip_smoke.rs` — Phase 9
   record-then-do-something pattern; useful for understanding the
   record loop's event sequencing (`clip_recording.started` /
   `.stopped`) for tests that record multiple clips.
5. `crates/video-coach-harness/src/lib.rs` — `App::launch_with_options`
   and the `send` / `wait_for_event` / `quit` API. Note: **no `Drop`
   impl on `App`**. Tests must call `app.quit().await?` explicitly.
6. `crates/video-coach-app/src/bus.rs::handle_export_compilations`
   (lines 2344–2980, especially the spawned-task per-tag loop at
   2625–2916). Confirm: the loop fires `export.tag.started`,
   `export.tag.completed` / `export.tag.failed` per tag, `export.batch.
   completed` / `export.batch.failed` / `export.batch.cancelled` once
   per batch. The `final_outcome = Some(ExportRunOutcome::PartialFailure
   { … })` write at line 2885 is what we're forcing in Task 3.
7. `crates/video-coach-app/src/frame_sink.rs:166-192` —
   `ExportRunOutcome` enum. Note that the slot is NOT exposed via the
   control socket — tests assert on **events**, not on the slot.
8. `crates/video-coach-media/src/export.rs:140-225` —
   `export_compilation` signature + the `referenced_source_indices`
   loop at 211–222 that builds one decoder chain per unique
   `source_index`. Multi-source dedup happens here.
9. `crates/video-coach-core/src/project_store.rs` — `read(folder)` and
   `write(&project, folder)` public API. Used by Tasks 1+2+3 to mutate
   `clip.tags` between recording and exporting.
10. `fixtures/manifest.json` — confirm `source-4k.mp4` is present
    (it already is) and read its `durationSeconds` (30) for sanity.

---

## Adversarial-review fixes baked in

**This section is populated by the orchestrator's PLAN_WRITTEN → ADV_REVIEWED
stage transition.** The adversarial reviewer reads this plan, returns net-new
findings (Phase 10's 40 fixes are off-limits to re-raise), the orchestrator
triages REAL / SPECULATIVE / OVERSTATED, and folds REAL/OVERSTATED-trimmed
into this section as numbered Fix entries. Initial draft has zero fixes —
the reviewer hasn't run yet. Numbering matches Phase 10's plan style
(`Fix #N — title`, REAL/HIGH style).

_(empty — populated post-adversarial-review)_

---

## Test design — multi-source

Two source videos in one project. Record one clip from each. Tag both with
the same tag. Export that tag. The output `.mp4` is a single file containing
both clips back-to-back.

### What "multi-source" exercises in the export pipeline

`export.rs:211-222` builds `source_chains: HashMap<usize, SourceChain>` with
one entry per unique `source_index` referenced by `plan.entries`. The driver
at `export.rs:1367-1524`'s `transition_to_source_chain` switches between
chains by sending the previous chain to PAUSED and the new chain to PLAYING
(per fix #27 — pause-when-inactive). A single-source plan never hits the
transition path; this test is the first to exercise it E2E from the bus.

### Project shape (two sources, two clips, one tag)

```
sources: [source-1080p.mp4, source-4k.mp4]
clips:
  - source_index=0, recording=clip-A, tags=["drills"]
  - source_index=1, recording=clip-B, tags=["drills"]
```

### Recording two clips from two different sources

The bus's `add_source_video` command swaps the player onto the new source
when called against an existing project. Sequence:

1. `new_project`
2. `add_source_video` (1080p) → fires `source.added` + `player.opened`
3. `start_clip_recording` → record ~1.0s → `stop_clip_recording`. The clip
   gets `source_index=0` (the first source). Capture `clip_id` from
   `clip_recording.started`.
4. `add_source_video` (4k) → fires `source.added` + (per Phase 7) the
   player reopens onto the second source.
5. `start_clip_recording` → record ~1.0s → `stop_clip_recording`. The clip
   gets `source_index=1`.

`clip.source_index` is set by the recording flow at the time the clip is
created (`bus.rs::StartClipRecording`); it picks up whichever source the
player is currently mounted on (per Phase 7 source-transport plan). That's
how we get one clip per source without needing a "set source" intermediate
command.

**Open question to verify in Task 1**: does `add_source_video` against an
already-open project actually swap the player, or does it require a quit
+ relaunch? The implementer must confirm by reading `bus.rs::handle_add
_source_video` and the `source.added` / `player.opened` event firing
order before proceeding. If it does NOT auto-swap, fall back to: quit →
edit `project.json` to add the second source → relaunch → OpenProject →
record both clips with explicit "switch source" command (which doesn't
exist; would need a quit-and-relaunch between clips). Plan B is uglier
but still tests the multi-source export path.

### Tagging both clips

After recording, before exporting, the test:

1. `app.quit().await?`
2. `let mut p = project_store::read(&project_path)?;`
3. For each clip in `p.clips`: set `clip.tags = vec!["drills".into()]`.
4. `project_store::write(&p, &project_path)?;`
5. Relaunch `App::launch_with_options(...)` with the same fixture.
6. Send `Command::OpenProject { path: project_path }` → wait for
   `project.opened`.
7. Dispatch `Command::ExportCompilations { selections: [Tag { name:
   "drills" }], ... }`.

This is the same pattern Tasks 2 and 3 use for the two- and three-tag
projects.

### Assertions

- `export.batch.started` fires once.
- `export.tag.started` fires exactly once with `selection = "drills"`.
- `export.tag.completed` fires exactly once with `selection = "drills"`
  and `frames_pushed >= 30` (two ~1.0s clips × 30 fps × 0.5 lavapipe
  margin ≈ 30 — the threshold matches `export_smoke.rs`'s ≥20 floor
  scaled for 2× content length).
- `export.batch.completed` fires once with `tag_count = 1`.
- The output `.mp4` exists at `<export_dir>/drills - <project_name>.mp4`
  (default filename template, Phase 11 Plan #7's `{tag} - {project}`).
- File size > 100 KB (Phase 10's smoke test asserts > 50 KB for a 1.2s
  single-clip export; doubling for two clips with margin).
- ISO BMFF magic at byte offset 4 (`b"ftyp"`), same as Phase 10.

We do NOT verify the output's exact duration via `Discoverer` — that
would require a `gstreamer-pbutils` dep on the harness crate (Phase 10
explicitly avoided this; the unit-level `export_smoke` in `video-coach-
media` covers Discoverer-based duration assertions). File size + magic
bytes + the `frames_pushed` floor cover "did the multi-source path
actually produce output".

---

## Test design — multi-tag batch

Three clips, two real tags + AllClips, in one batch.

### Project shape

```
sources: [source-1080p.mp4]   ← single source, multi-source is Task 1's job
clips:
  - clip-X, tags=["a"]
  - clip-Y, tags=["a", "b"]    ← in both
  - clip-Z, tags=["b"]
```

`TagSelection::Tag { name: "a" }` → 2 clips. `Tag { name: "b" }` → 2 clips.
`AllClips` → 3 clips. Three output files.

### Why not just two tags?

A two-tag batch tests the loop iterates >1 time but doesn't exercise
the synthetic `AllClips` row alongside named tags. Three selections —
two named tags plus AllClips — exercises both paths and matches what a
real user would tick (most projects export "AllClips + each individual
tag" in one batch).

### Recording three clips from one source

After `new_project` + `add_source_video`: three back-to-back
`start_clip_recording` / `stop_clip_recording` cycles, each ~0.8s. Total
recording time ≈ 2.4s + control-socket round trips. Capture clip_ids in
recording order from `clip_recording.started`.

Then: quit, mutate `project.json` to set `clips[0].tags = ["a"]`,
`clips[1].tags = ["a", "b"]`, `clips[2].tags = ["b"]`, write, relaunch,
`OpenProject`.

### Dispatch

```json
{
  "cmd": "export_compilations",
  "selections": [
    { "kind": "tag", "name": "a" },
    { "kind": "tag", "name": "b" },
    { "kind": "all_clips" }
  ],
  "output_folder": "<tmp>",
  "resolution": "r720",
  "quality": "low",
  "codec": "h264",
  "project_name": "phase11-multi-tag-test",
  "filename_template": "{tag} - {project}"
}
```

### Assertions

- `export.batch.started` fires once with `total_tags = 3`.
- Three `export.tag.started` events, in dispatch order: selection `"a"`
  → `"b"` → `"all-clips"`.
- Three `export.tag.completed` events, in same order, each with
  `frames_pushed >= 15` (0.8s × 30fps ≈ 24 with lavapipe margin → 15
  floor).
- One `export.batch.completed` with `tag_count = 3`.
- No `export.tag.failed` / `export.batch.failed`.
- Three output `.mp4` files exist:
  - `<dir>/a - phase11-multi-tag-test.mp4` — 2 clips' worth (X + Y)
  - `<dir>/b - phase11-multi-tag-test.mp4` — 2 clips' worth (Y + Z)
  - `<dir>/all-clips - phase11-multi-tag-test.mp4` — 3 clips' worth
- File-size ordering: AllClips file > tag-A file ≈ tag-B file (same
  number of clips per tag; AllClips has all three). Test asserts
  AllClips size > both per-tag sizes by at least 20 KB. Avoids exact
  byte counts (encoder QP varies).

### Event ordering caveat

The spawned export task's events arrive on the harness's event channel
in the same order they fire. `wait_for_event` returns the first matching
event after the call site, so a sequence of three `wait_for_event(
"export.tag.started", ...)` calls observes the three events in firing
order. Verify the `selection` field on each. Same for `export.tag
.completed`.

---

## Test design — PartialFailure E2E

Three clips, three tags — but one tag's clip points at a missing
recording file. The export pipeline fails when it tries to open the
recording, the per-tag loop catches the error and writes
`PartialFailure`.

### Forcing the failure

`bus.rs::handle_export_compilations` resolves recording paths at line
2491 by joining `recordings_dir(project_folder)` with `clip
.recording_filename`. If we set `clip.recording_filename` to a
nonexistent file (e.g. `"clip-DOES-NOT-EXIST.mov"`), the path resolves
to a path that doesn't exist on disk; the export driver passes it to
`export_compilation` which passes it to GStreamer's recording-chain
`filesrc`, which fails to open and returns
`ExportError::Construction(...)` (or a state-change error — the exact
variant depends on whether `filesrc.set_state(Ready)` errors or
`set_state(Playing)` errors first).

The per-tag match arm at `bus.rs:2870` catches `Ok(Err(other))` and
writes `final_outcome = Some(ExportRunOutcome::PartialFailure { ... })`,
then `break 'outer` — remaining tags are skipped per fix #24. This is
the path under test.

### Project shape

```
sources: [source-1080p.mp4]
clips:
  - clip-X (real recording), tags=["good-1"]
  - clip-Y (real recording), tags=["bad"]    ← Y's recording_filename mutated to "missing.mov" before export
  - clip-Z (real recording), tags=["good-2"]
selections: [Tag "good-1", Tag "bad", Tag "good-2"]
```

Tag order matters: "good-1" runs first (succeeds), "bad" runs second
(fails → `final_outcome` set → `break 'outer`), "good-2" never runs.
This validates fix #24's "sequential, no skip-ahead-on-fail" guarantee.

### Recording sequence

Same as multi-tag: three real clips. Quit. Edit project.json:
- `clips[0].tags = ["good-1"]`, leave `recording_filename` real
- `clips[1].tags = ["bad"]`, set `recording_filename = "missing.mov"`
- `clips[2].tags = ["good-2"]`, leave `recording_filename` real

Write, relaunch, OpenProject, ExportCompilations.

### Why mutating `recording_filename` (vs deleting the file)

Two options for forcing the failure:

(a) **Mutate `recording_filename` to a nonexistent name.** The recording
    file at the original name is still on disk (the test won't delete
    it; tempdir cleans up at the end). The clip just points at the
    wrong name. Idempotent, no FS race.

(b) **Delete the recording file from disk.** The original
    `recording_filename` is preserved but the file is gone. Equivalent
    failure on Linux; on Windows there's a small race where the file
    handle could still be open from the prior recording session and
    `fs::remove_file` returns `ERROR_SHARING_VIOLATION`.

We pick (a). Cross-platform-clean, no FS race, and the assertion is
the same — the export pipeline reports a recording open failure.

### Assertions

- `export.batch.started` fires once with `total_tags = 3`.
- `export.tag.started` for "good-1" fires.
- `export.tag.completed` for "good-1" fires with `frames_pushed >= 15`.
- `export.tag.started` for "bad" fires.
- `export.tag.failed` for "bad" fires with non-empty `error` field.
- `export.batch.failed` fires with `reason = "tag_failed"` and
  `selection = "bad"`. (See `bus.rs:2878-2884`.)
- **Neither** `export.tag.started` nor `export.tag.completed` for
  "good-2" fires within a 5s window after `batch.failed`. (Negative
  assertion via `tokio::time::timeout` on `wait_for_event` — expect
  a timeout error.)
- The output file `<dir>/good-1 - phase11-partial-test.mp4` exists
  (per fix #36 — Reveal needs partial successes preserved).
- The output file `<dir>/bad - phase11-partial-test.mp4` does NOT
  exist (the failed tag's partial output is deleted per fix #10's
  cancel/error path; verify by reading `export.rs`'s error path —
  Phase 10 Task 1 step "delete partial on Cancelled or other error").
- The output file `<dir>/good-2 - phase11-partial-test.mp4` does NOT
  exist (the tag was skipped, never started writing).
- The slot's `outcome` is NOT directly observable from the harness
  (no event carries `ExportRunOutcome::PartialFailure { folder,
  completed, failed_tag, error }` as a payload — see `bus.rs:2960-2978`
  where the slot is written but no event carries the variant). The
  closest signal we have is the `batch.failed` event's `reason` +
  `selection` fields, which we assert above. Document this in the test
  comment.

### Error string assertion

The `error` field on `tag.failed` is the `Display` of the
`ExportError`. The exact string depends on which `ExportError` variant
fires (e.g. `Construction`, `StateChange`, or some platform-specific
GStreamer error message). We assert the string is non-empty and
contains `"missing.mov"` OR contains `"recording"` (case-insensitive)
— either of those proves the failure is the recording-open path. Hard-
coding the exact `ExportError` variant would be brittle.

---

## Tasks (4 total — fits in 3 sub-agent dispatches well under 700 LOC each)

### Task 0: Shared helpers + multi-clip recording in `tests/common/mod.rs`

**Files:**
- Create: `crates/video-coach-harness/tests/common/mod.rs` (~120 LOC)
- (Optional, if needed for cargo): touch `tests/common/main.rs` empty
  shim or add `mod common;` to each test file. Pattern: Rust's standard
  approach is `tests/common/mod.rs` referenced by `mod common;` in
  each integration test file; the module-folder shape (vs a flat
  `common.rs`) prevents cargo from treating the helper file itself as
  a top-level integration test.

**Helpers exposed:**

```rust
pub fn fixture_1080p() -> PathBuf;
pub fn fixture_4k() -> PathBuf;
pub fn webcam_fixture() -> PathBuf;

pub struct LaunchedProject {
    pub app: App,
    pub project_path: PathBuf,
    pub _parent: TempDir,    // RAII cleanup
}

/// Launch + new_project + add_source_video for ONE source. Returns
/// the launched app + project path. Caller does the recording.
pub async fn launch_new_project_with_source(
    project_name: &str,
    source: &Path,
) -> anyhow::Result<LaunchedProject>;

/// Records a clip from the currently-mounted source. Returns the
/// clip_id. Caller can call this multiple times to stack clips.
pub async fn record_clip(
    app: &mut App,
    duration_ms: u64,
) -> anyhow::Result<uuid::Uuid>;

/// Sends `add_source_video` against an already-open project. Awaits
/// `source.added` + `player.opened`.
pub async fn add_second_source(
    app: &mut App,
    source: &Path,
) -> anyhow::Result<()>;

/// Quits the app, mutates clip tags + recording_filename via
/// project_store, returns. Caller relaunches + OpenProject.
///
/// `mutator` is called with `&mut Project` so the caller can apply
/// arbitrary edits (set tags, swap recording_filename to "missing.mov",
/// etc.).
pub async fn quit_and_mutate_project<F>(
    app: App,
    project_path: &Path,
    mutator: F,
) -> anyhow::Result<()>
where F: FnOnce(&mut video_coach_core::project::Project);

/// Relaunches an app, sends OpenProject, awaits project.opened.
pub async fn relaunch_and_open(
    project_path: &Path,
) -> anyhow::Result<App>;
```

**Why a shared module is needed.** The three tests below all do roughly:
launch → add source → record N clips → quit → mutate JSON → relaunch →
OpenProject → export → assert. Without a shared module, ~80 LOC of
boilerplate is duplicated 3×. The shared module is also where the
"does add_source_video against an open project actually swap the player"
question gets answered ONCE — if the answer is "no, we have to
quit+relaunch with two sources pre-injected", that quirk lives in
`add_second_source` and the tests don't have to know.

**Verification:**
- The module compiles under `--features media` (it's only included
  via `mod common;` in cfg-gated tests).
- It does NOT compile under `--no-default-features` (the harness's
  test-binary build doesn't define `media`); this is enforced by the
  `#![cfg(feature = "media")]` at the top of every test file that
  uses it.
- `cargo test --workspace --features media -- --list` shows the
  three new test functions (added in Tasks 1-3) but no test from
  `common.rs` itself (it's a helper, not a test).

**Exit gate before progressing to Task 1:** the implementer must
verify by reading `bus.rs::handle_add_source_video` whether
`add_source_video` against an open project swaps the player or
errors. Document the answer in a comment on `add_second_source`.
If it errors, `add_second_source` is implemented as: quit, edit
project.json to insert the second source as a second `SourceRef`,
relaunch with `OpenProject`. Document which branch was taken.

**Commit:** `phase11(coverage-hardening, task 0): shared test helpers
+ multi-clip recording`.

---

### Task 1: Multi-source export E2E — `tests/export_multi_source_smoke.rs`

**Files:**
- Create: `crates/video-coach-harness/tests/export_multi_source_smoke.rs`
  (~140 LOC).

**Test name:** `export_multi_source_compilation_writes_one_mp4`.

**Body sketch:**

```rust
#![cfg(feature = "media")]
mod common;
use common::*;

#[tokio::test]
async fn export_multi_source_compilation_writes_one_mp4()
    -> anyhow::Result<()>
{
    let project_name = "phase11-multi-source-test";
    let mut lp = launch_new_project_with_source(
        project_name, &fixture_1080p()).await?;

    // Clip from source 0 (1080p).
    let _clip_a = record_clip(&mut lp.app, 1000).await?;

    // Add source 1 (4k) — auto-swaps player or requires relaunch
    // (decided in Task 0 by reading bus.rs).
    add_second_source(&mut lp.app, &fixture_4k()).await?;

    // Clip from source 1.
    let _clip_b = record_clip(&mut lp.app, 1000).await?;

    // Tag both clips with "drills" via project_store.
    quit_and_mutate_project(lp.app, &lp.project_path, |p| {
        for clip in &mut p.clips {
            clip.tags = vec!["drills".into()];
        }
    }).await?;

    let mut app = relaunch_and_open(&lp.project_path).await?;

    let export_dir = TempDir::new()?;
    let export = app.send(serde_json::json!({
        "cmd": "export_compilations",
        "selections": [{"kind": "tag", "name": "drills"}],
        "output_folder": export_dir.path().to_string_lossy(),
        "resolution": "r720",
        "quality": "low",
        "codec": "h264",
        "project_name": project_name,
        "filename_template": "{tag} - {project}",
    })).await?;
    assert_eq!(export.ok, Some(true), "{:?}", export.error);

    let _ = app.wait_for_event("export.batch.started",
        Duration::from_secs(5)).await?;
    let tag_started = app.wait_for_event("export.tag.started",
        Duration::from_secs(10)).await?;
    assert_eq!(
        tag_started.other.get("selection").and_then(|v| v.as_str()),
        Some("drills"),
    );
    let tag_completed = app.wait_for_event("export.tag.completed",
        Duration::from_secs(90)).await?;
    let frames_pushed = tag_completed.other.get("frames_pushed")
        .and_then(|v| v.as_i64()).expect("frames_pushed");
    assert!(frames_pushed >= 30,
        "expected ≥30 frames (2 × 1s × 30fps), got {frames_pushed}");
    let _ = app.wait_for_event("export.batch.completed",
        Duration::from_secs(10)).await?;

    let expected = export_dir.path()
        .join(format!("drills - {project_name}.mp4"));
    assert!(expected.exists(), "{}", expected.display());
    let bytes = std::fs::read(&expected)?;
    assert!(bytes.len() > 100_000, "size {}", bytes.len());
    assert_eq!(&bytes[4..8], b"ftyp");

    app.quit().await?;
    Ok(())
}
```

**Lavapipe runtime budget.** Two ~1s clips export in ~12-25s on lavapipe
(empirical from Phase 10 cancel test extrapolation). The 90s
`tag.completed` timeout is the same headroom as `export_smoke`'s 60s for
a 1.2s clip, scaled 1.5×. If CI flakes, raise to 120s — never lower
the frames_pushed floor.

**Commit:** `phase11(coverage-hardening, task 1): multi-source export
E2E`.

---

### Task 2: Multi-tag batch export E2E — `tests/export_multi_tag_smoke.rs`

**Files:**
- Create: `crates/video-coach-harness/tests/export_multi_tag_smoke.rs`
  (~130 LOC).

**Test name:** `export_multi_tag_batch_writes_three_mp4s`.

**Body sketch:** record 3 clips × ~0.8s each from `source-1080p.mp4`.
Quit. Edit `clips[0].tags = ["a"]`, `clips[1].tags = ["a", "b"]`,
`clips[2].tags = ["b"]`. Relaunch + OpenProject + ExportCompilations
with three `TagSelection`s.

Assertions:
- `batch.started` with `total_tags = 3`.
- Three `tag.started` in order: `"a"`, `"b"`, `"all-clips"`. Use
  `wait_for_event("export.tag.started", ...)` 3× and assert each
  `selection`.
- Three `tag.completed`, each `frames_pushed >= 15`.
- One `batch.completed` with `tag_count = 3`.
- Three files exist with correct names.
- Size ordering: AllClips > max(tag-A, tag-B) by at least 20 KB.
- No `tag.failed` / `batch.failed` events fire (inferred — if either
  did, `batch.completed` wouldn't, so the batch.completed wait would
  time out).

**Lavapipe runtime budget.** Three ~0.8s clips × 3 tags = 9 effective
clip-encodes. ~30-50s total on lavapipe. Each `tag.completed` waits up
to 60s; total wall budget on the test ~120s. Mark `#[ignore]` only
if local Apple-Silicon runs exceed 90s.

**Commit:** `phase11(coverage-hardening, task 2): multi-tag batch export
E2E`.

---

### Task 3: PartialFailure E2E — `tests/export_partial_failure_smoke.rs`

**Files:**
- Create: `crates/video-coach-harness/tests/export_partial_failure_smoke
  .rs` (~150 LOC).

**Test name:** `export_partial_failure_completes_first_tag_fails_second_skips_third`.

**Body sketch:** record 3 clips. Quit. Edit tags AND mutate
`clips[1].recording_filename = "missing.mov"`. Relaunch + OpenProject
+ ExportCompilations with three real-tag selections (no AllClips,
order: `"good-1"`, `"bad"`, `"good-2"`).

Assertions:
- `batch.started` with `total_tags = 3`.
- `tag.started` "good-1" → `tag.completed` "good-1" (frames_pushed ≥
  15).
- `tag.started` "bad" → `tag.failed` "bad" with non-empty `error`,
  AND `error` contains either `"missing.mov"` OR (case-insensitive)
  `"recording"`.
- `batch.failed` with `reason = "tag_failed"`, `selection = "bad"`.
- Negative assertion: 5-second timeout on `wait_for_event(
  "export.tag.started", ...)` after `batch.failed` returns Err
  (no third tag fired).
- `<dir>/good-1 - <project>.mp4` exists (per fix #36).
- `<dir>/bad - <project>.mp4` does NOT exist (failed tag's partial
  output deleted; verify in `export.rs`'s error path).
- `<dir>/good-2 - <project>.mp4` does NOT exist (skipped).

**Why a 4-test plan landed here.** The decomposition could have folded
PartialFailure assertions into Task 2 (one test that does both 3-tag
batch AND PartialFailure), but separating keeps each test asserting
ONE outcome. A green Task 2 + red Task 3 immediately tells the
investigator the failure path is broken; a single combined test makes
the failure mode harder to localize.

**Negative-assertion implementation.** `wait_for_event` returns an
error if the timeout elapses before a matching event arrives. Tests
should:

```rust
match tokio::time::timeout(
    Duration::from_secs(5),
    app.wait_for_event("export.tag.started", Duration::from_secs(5)),
).await {
    Err(_elapsed) => {} // expected — outer timeout fired first; no event
    Ok(Err(_inner)) => {} // also OK — wait_for_event itself timed out
    Ok(Ok(frame)) => panic!("unexpected third tag.started: {:?}", frame),
}
```

The double-timeout shape (outer `tokio::time::timeout` + inner
`wait_for_event` timeout) is a defence against `wait_for_event`'s
inner timeout being increased in the future without breaking this
test.

**Commit:** `phase11(coverage-hardening, task 3): PartialFailure E2E`.

---

## Files-touched summary

| Path | LOC | Purpose |
|---|---|---|
| `crates/video-coach-harness/tests/common/mod.rs` | ~120 | Shared launch + record + tag-mutate helpers |
| `crates/video-coach-harness/tests/export_multi_source_smoke.rs` | ~140 | Multi-source export E2E |
| `crates/video-coach-harness/tests/export_multi_tag_smoke.rs` | ~130 | Multi-tag batch export E2E |
| `crates/video-coach-harness/tests/export_partial_failure_smoke.rs` | ~150 | PartialFailure outcome E2E |
| `PROGRESS.txt` | — | Per-task `[ ]` → `[x]` flips (orchestrator does these) |

Total: ~540 LOC across 4 test files. No production code change.

---

## Known performance risks

1. **CI runtime growth.** The three new tests collectively add ~3-5
   minutes to the `media-tests` job's lavapipe runtime (Task 1: ~30-60s;
   Task 2: ~90-120s; Task 3: ~60-90s). The `media-tests` job currently
   runs in ~10 minutes; this brings it to ~13-15 minutes. Acceptable
   per Phase 10's cap (15 min) but trims the headroom. Future plans
   that add more lavapipe E2E tests should consider sharding.
2. **LFS bandwidth.** No new fixtures; `source-4k.mp4` (70.8 MB) is
   already in LFS. Tasks 1-3 don't bump bandwidth.
3. **Harness `App` Drop semantics.** The `App` struct has no `Drop`
   impl; a test panic mid-export leaks the child Slint subprocess.
   The cargo-test process exit reaps orphans via SIGCHLD on
   Linux/macOS but on Windows a leaked child process can persist
   until the test runner exits. Tests use `?` aggressively + RAII
   `TempDir`, but a stray panic could leave a Slint window subprocess
   alive in CI. Documented; a real `Drop` impl is a separate plan
   item.
4. **Project-state mutation race.** `quit_and_mutate_project` calls
   `app.quit()` which awaits the child process exit, then reads +
   rewrites `project.json`. There's no race because `project_store
   ::write` doesn't run until after the child process is gone, and
   `project_store::read` after relaunch doesn't run until after
   `OpenProject` is sent. Documented as defence in depth — the
   implementer must NOT call `app.quit()` and the mutator
   concurrently.

---

## Risks / unknowns (sub-agent may need to make calls)

1. **`add_source_video` against an open project.** Does it auto-swap
   the player or error? Task 0 must read `bus.rs::handle_add_source_video`
   and document the answer. If "auto-swap", `add_second_source` is a
   single bus call; if "error", it's a quit + edit project.json + relaunch.
   The plan handles both branches.
2. **Exact `ExportError` variant on missing recording.** Task 3
   asserts `error` field contains `"missing.mov"` OR `"recording"`.
   If the actual error string contains neither (e.g. some platform
   reports "filesrc: No such file or directory" with no leading
   path), Task 3 must adjust the assertion based on what fires.
   Document the actual string in a comment.
3. **Source swap on `add_source_video`.** If the player swap takes
   longer than `wait_for_event`'s 5s default timeout (the existing
   `export_smoke` uses 5s for `source.added` + `player.opened`),
   raise the per-event timeout in `add_second_source` to 15s.
4. **Negative-assertion timeout window.** Task 3's "no third
   tag.started fires" assertion uses a 5s window. If `batch.failed`
   fires faster than the test's downstream wait_for_event(no-third-
   tag), there's no race — events arrive in the order they fire,
   so a third tag.started would have already arrived if it were going
   to. 5s is the lavapipe-margin floor.
5. **Tag iteration order.** `bus.rs::handle_export_compilations`
   iterates `selections` in the order the harness sent them. The
   tests rely on this. If a future refactor sorts or shuffles
   selections (none planned), Tasks 2 + 3's order assertions break
   and the orchestrator triages the regression as a real change.

---

## Done when

- All four task commits land on `rust-rewrite` with green per-task
  scoped verification.
- Closeout commit appended to this plan + PROGRESS.txt updated with
  the final CI run id.
- CI run is green on all 4 jobs (`test (ubuntu-latest)`, `test
  (windows-latest)`, `test (macos-latest)`, `media-tests`). The new
  tests run only on the `media-tests` job (cfg-gated `feature =
  "media"`); the other three jobs build the workspace without media
  and the new test files compile out.

---

## Closeout — _(filled in at READY_FOR_CLOSEOUT stage)_

_(empty — populated by orchestrator's CLOSEOUT_COMMITTED → CI_DONE
transitions)_
