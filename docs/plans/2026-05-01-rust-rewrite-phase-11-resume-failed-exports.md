# Rust Rewrite — Phase 11 Plan #6: Resume Failed Exports (tag-level)

> **For Claude:** Implement via the per-phase sub-agent pattern (per
> `feedback_phase_per_subagent.md`). Phase 10's lessons say small per-task
> agents (4 small dispatches, NOT 1 big one). Match that here. ~250-400
> LOC across 4 tasks; each task fits inside the 700-LOC dispatch cap with
> headroom.

**Goal:** When a batch export ends in `PartialFailure` or `Cancelled`
(both are Phase-10 outcomes that already capture `completed: usize`),
the user re-opens the export sheet, ticks the same selections, and
clicks Export again. The bus's per-tag for-loop walks the selections
in the same order, but for each selection it first checks whether the
target output `.mp4` already exists on disk **and looks structurally
intact** (size + `ftyp` magic bytes). If yes, the tag is skipped with
a new `export.tag.skipped { reason = "already_exists" }` event and
the batch jumps to the next selection without re-encoding.

The result: a 6-tag batch that failed on tag 5 of 6 only re-renders
tags 5 and 6 on retry. A user with 30 minutes of GPU work behind them
keeps that work.

**Scope locked-in to (do not expand):**

1. **Tag-level resume only.** Mid-tag checkpointing (resume from frame
   N within a single tag) is OUT OF SCOPE — that requires fragment-
   aware mp4 restart and is much larger engineering. v1 didn't have
   it; not blocking shipment.
2. **Opt-in default.** A new `Preferences::export_overwrite_policy`
   field defaults to `Resume` (the new behavior). The legacy "always
   overwrite" Phase 10 behavior is preserved as the explicit
   `OverwriteAll` variant, surfaced as an "Overwrite existing"
   checkbox in the export sheet form. This is a behavior change for
   pre-Plan-#6 users; documented in closeout.
3. **Validation criterion: file exists + size > 50 KB + `ftyp` magic
   bytes at offset 4.** A file that exists but is corrupt (e.g.,
   killed mid-write before `qtmux` flushed the moov atom) MUST be
   re-encoded. We do NOT run `Discoverer` to verify duration — that's
   slower than re-encoding for short clips and is documented as
   future hardening. Specifically the validation is:
   - `metadata.len() >= 50_000` AND
   - first 8 bytes read; bytes 4..8 are exactly `b"ftyp"`.
4. **Skipped tags count toward `completed_tags`.** A run that skipped
   5 of 6 and freshly rendered 1 of 6 is `SucceededAll { tag_count:
   6 }`, not `PartialFailure`. The user got all 6 mp4s.
5. **No fingerprint-based staleness.** If the user re-records the
   clip between the failed run and the retry, Resume will happily
   reuse the stale .mp4. The "Overwrite existing" checkbox is the
   user's escape hatch. Documented in closeout.
6. **No new bus command.** Resume happens transparently inside the
   existing `Command::ExportCompilations` per-tag for-loop. The user
   doesn't need to know "resume" is a thing — they just re-click
   Export.

**Architecture:**

- New enum `Preferences::export_overwrite_policy: ExportOverwritePolicy`
  in `crates/video-coach-core/src/project.rs`. Variants `Resume` (skip
  if a structurally-valid output exists) and `OverwriteAll` (always
  re-encode — Phase 10 behavior). `#[serde(default)]` so pre-Plan-#6
  project.json deserializes as `Resume`. The field rides the existing
  `ExportPrefsSnapshot` (Plan #3 + Plan #7 both extended it; consistent
  pattern).
- `Command::ExportCompilations` gains
  `overwrite_policy: ExportOverwritePolicy` (snake_case serde,
  `#[serde(default)]`). Bus loads from preferences if not provided on
  the command (the UI sends the current state of the form's checkbox).
- `crates/video-coach-app/src/bus.rs::handle_export_compilations`'s
  per-tag for-loop gains a pre-encode skip check:
  ```rust
  if matches!(overwrite_policy, ExportOverwritePolicy::Resume)
      && output_exists_and_intact(&output_path)
  {
      tracing::info!(
          target: "export.lifecycle",
          event = "export.tag.skipped",
          selection = %label,
          reason = "already_exists",
          output_path = %output_path.display(),
      );
      // bump completed_tags so SucceededAll captures the skipped row
      let mut g = export_progress_for_task.lock().expect("...");
      g.completed_tags = i + 1;
      g.batch_progress = ((i + 1) as f32 / total_tags as f32).min(1.0);
      drop(g);
      continue;
  }
  ```
  The existing Phase 10 fix #13 silent-prior-output-delete moves under
  `if matches!(policy, ExportOverwritePolicy::OverwriteAll) ||
  !output_exists_and_intact(&output_path)`.
- `output_exists_and_intact(path)` is a small helper in `bus.rs` (or
  a new `crates/video-coach-app/src/output_validation.rs`) that checks
  metadata size + reads the first 8 bytes. Unit tests cover empty
  file, truncated <50KB file, valid mp4 header, missing file, and
  Windows path edge cases.
- UI: a single "Overwrite existing" checkbox in the export-sheet Form
  view. Default unchecked (= `Resume`). Persists on toggle through
  `Command::SetPreferences` (existing) — no new command. The
  preference round-trips through `ExportPrefsSnapshot` (set on
  Export click) so a future Plan-#6-aware caller doesn't need to
  separately fetch it.
- Harness E2E: a new `export_resume_skips_existing_tags.rs` test that
  (a) runs an export to completion for one selection, (b) saves the
  output mtime + size + first-8-bytes hash, (c) re-runs the same
  selection, (d) asserts the bus emitted `export.tag.skipped { reason
  = "already_exists" }` and the file's mtime + size + bytes are
  unchanged.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; the "Adversarial-review fixes baked in"
   section below is non-negotiable.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`,
   especially:
   - Fix #13 (silent prior-output delete) — Plan #6 modifies this
     pattern; the modification must preserve the documented contract
     for non-Resume callers.
   - Fix #26 (empty-plan → `export.tag.skipped`) — the existing
     skip emit shape; Plan #6's new emit lives directly above it
     in the per-tag for-loop and reuses the event name + target.
   - Fix #34 (`ExportRunOutcome::PartialFailure` / `Cancelled`) —
     documents the two outcomes that Plan #6 lets users recover from.
   - The "Adversarial-review fixes baked in" section (40 fixes).
     **DO NOT re-raise these.** The adversarial sub-agent reviewer
     is briefed to skip Phase 10 fixes; the implementing sub-agent
     should treat those as already-shipped invariants.
3. `crates/video-coach-app/src/bus.rs::handle_export_compilations` —
   the per-tag for-loop where the skip-or-encode decision lives. Lines
   ~2670 (Phase 11 Plan #2 progress slot writer init) through ~2790
   (closure body) span the section Plan #6 augments.
4. `crates/video-coach-app/src/filename.rs::apply_template` — Phase 11
   Plan #7's per-tag filename construction. Plan #6 calls this BEFORE
   the skip check (we need the output path to know whether to skip).
5. `crates/video-coach-harness/tests/export_partial_failure_smoke.rs`
   (Phase 11 Plan #5 Task 3) — the test that creates a `PartialFailure`
   outcome. Plan #6's new harness E2E follows the same setup.
6. `crates/video-coach-app/src/frame_sink.rs::ExportRunOutcome` — the
   outcome enum + `ExportProgressSlotData::completed_tags`. Plan #6
   does NOT change this enum; it ensures `completed_tags` includes
   skipped tags.
7. `crates/video-coach-core/src/project.rs::Preferences` — where
   `export_overwrite_policy` lands. Note `#[serde(default)]` on the
   existing `last_export_codec` and the named-function default on
   `export_filename_template` — pattern to follow.
8. `crates/video-coach-app/ui/main.slint` — the export-sheet Form view
   where the new checkbox lives. Note Phase 10 fix #18 (Slint Dialog
   overlay pattern) and #32 (focus discipline).
9. `PROGRESS.txt` — Phase 11 Plan #6 starts here; check the section's
   shape from earlier Phase-11 plans for the row format.

---

## Adversarial-review fixes baked in

The main session ran one adversarial-review pass on this plan; the
fixes are **non-negotiable**. Sub-agent: every one must be present in
shipped code. Numbered here in order of pass and fix; the orchestrator
fills in this section after the adv-plan-review sub-agent reports.

(Section to be populated during the `ADV_REVIEWED` → `READY_FOR_TASK_0`
state transition.)

---

## What Plan #6 deliberately does NOT include

- **Mid-tag checkpointing.** Resume from frame N within a single tag
  requires fragment-aware mp4 restart (or tee'ing intermediate frames
  to disk and re-muxing on resume). Out of scope. Plan #6 ships
  tag-level resume only — a tag whose output is incomplete is
  re-rendered from frame 0.
- **Fingerprint-based staleness detection.** If the user re-records
  the underlying clip after the .mp4 was written, Resume gives stale
  output. Mitigation: the "Overwrite existing" checkbox is the user's
  escape hatch. Implementing fingerprint detection (recording.mov
  mtime + clip.events hash) blurs into mid-tag checkpointing scope
  and is deferred. Documented in closeout.
- **`Discoverer`-based output validation.** The validation criterion
  is metadata size + `ftyp` magic bytes only. Running `Discoverer` to
  verify duration would catch (rare) truncated-but-magic-present files
  but is slower than re-encoding for short clips. Documented as
  future hardening.
- **A new "Resume" button in the UI.** Resume is transparent — the
  user re-clicks Export and it Just Works. The "Overwrite existing"
  checkbox toggles the OPPOSITE behavior (force re-encode); resume is
  the default. No separate Resume affordance.
- **Resuming an export interrupted by app crash mid-tag.** If the app
  crashed during tag K's encode, the partial `.mp4` will likely fail
  the `ftyp` magic check (qtmux flushes the moov atom only at EOS).
  The validation correctly identifies it as incomplete and re-encodes
  from frame 0. Plan #6 does NOT ship a recovery path that resumes
  inside the encoder; the encoder's own state is gone with the crashed
  process.
- **"Resume since N" telemetry.** The new `export.tag.skipped` event
  carries `reason = "already_exists"` but no separate counter for
  "this run skipped K of M tags". Aggregating across tags is the
  job of any future analytics consumer; the per-event log is the
  contract.

---

## Known unknowns (sub-agent may need to make calls)

1. **`ExportPrefsSnapshot` extension shape.** Plan #3 and Plan #7
   both extended this snapshot when they added new export prefs. Plan
   #6 should mirror that pattern — add `overwrite_policy` to the
   snapshot. If the sub-agent finds the snapshot is being deprecated
   in favor of separate `Command` fields, fall back to threading
   `overwrite_policy` directly through `Command::ExportCompilations`.
   The plan body assumes "ride on the snapshot" as the default.
2. **`fs::metadata` + `File::read_exact` Windows behaviour.** Reading
   the first 8 bytes from a file that another process has open for
   write should return the bytes already written, but Windows file-
   sharing semantics differ from POSIX. The validation runs BEFORE
   any export task is spawned for this tag, so there's no concurrent
   writer in our process — but a different app might still hold the
   handle. Sub-agent should test with a Windows VM if available;
   otherwise the harness E2E provides cross-platform coverage.
3. **Slint checkbox-state-after-toggle persistence.** Existing
   Phase 11 plans persist on toggle via `Command::SetPreferences`.
   If that command doesn't accept `export_overwrite_policy` yet, the
   sub-agent extends it (snake_case field, optional via
   `#[serde(default)]`). The bus handler updates
   `current.0.preferences.export_overwrite_policy` and writes
   project.json.
4. **Race between skip-check and concurrent file delete.** A user
   could open Finder + delete the .mp4 between the skip check and
   the next event. The window is on the order of milliseconds and
   the user's intent is unambiguous (they wanted re-encode); the
   skip will incorrectly fire and the bus will emit a "skipped"
   event for a file that no longer exists. This is acceptable; a
   subsequent run would re-encode and produce the file. Plan #6 does
   NOT ship lock-file-style serialization to close this race.

---

## Tasks (~4 total — each a separate sub-agent dispatch)

Each task is sized ≤ 200 LOC of production code (excluding tests) so
all four fit comfortably under the 700-LOC dispatch cap. PROGRESS.txt
flips happen as separate orchestrator commits between tasks; do not
batch.

### Task 0: Preflight — `ExportOverwritePolicy` enum + Preferences field + snapshot ride

**Files:**
- Modify: `crates/video-coach-core/src/project.rs`.
- Modify: `crates/video-coach-app/src/bus.rs` (`Command::ExportCompilations`
  shape; `ExportPrefsSnapshot` field; `Command::SetPreferences` field
  if applicable; serde tests).
- Modify: `crates/video-coach-app/src/frame_sink.rs` if any new slot
  field is needed (probably none; the existing `current_tag` and
  `completed_tags` are sufficient).

**Add to `crates/video-coach-core/src/project.rs`:**
```rust
/// Phase 11 Plan #6. Selects whether a batch export overwrites
/// pre-existing per-tag .mp4 files (`OverwriteAll`, the Phase 10
/// behavior) or skips them when they already exist on disk and look
/// structurally complete (`Resume`, the new default).
///
/// `#[serde(default)]` on `Preferences::export_overwrite_policy` (named-
/// function form below) makes a pre-Plan-#6 project.json deserialize as
/// `Resume` — i.e. existing users opt INTO the new behavior on first
/// open. Documented as a behavior change in the Phase 11 Plan #6
/// closeout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ExportOverwritePolicy {
    /// Skip a per-tag output if it exists on disk and passes the
    /// structural validation (size > 50 KB AND `ftyp` magic at offset
    /// 4..8). Default for new projects and the migration path for
    /// pre-Plan-#6 projects.
    #[default]
    Resume,
    /// Always re-encode every selected tag, deleting any prior output
    /// silently before encode starts. Reproduces the Phase 10 behavior
    /// for users who explicitly want it (the export-sheet "Overwrite
    /// existing" checkbox).
    OverwriteAll,
}

pub fn default_overwrite_policy() -> ExportOverwritePolicy {
    ExportOverwritePolicy::Resume
}
```

Add to `Preferences`:
```rust
/// Phase 11 Plan #6. See `ExportOverwritePolicy` doc-comment.
#[serde(default = "default_overwrite_policy")]
pub export_overwrite_policy: ExportOverwritePolicy,
```

Update `Preferences::default()` to set `export_overwrite_policy:
default_overwrite_policy()` (= `Resume`).

**Update `Command::ExportCompilations` in bus.rs** to add:
```rust
/// Phase 11 Plan #6. Defaults to `Resume` so a pre-Plan-#6 caller
/// (e.g. a v2 harness that hasn't been updated yet) gets the new
/// behavior. The UI always sends the current value of the
/// "Overwrite existing" checkbox so the bus reflects the user's
/// intent at click time.
#[serde(default = "default_overwrite_policy_for_command")]
overwrite_policy: ExportOverwritePolicy,
```
…with a `default_overwrite_policy_for_command()` helper that delegates
to `video_coach_core::project::default_overwrite_policy()`. Mirror the
named-function pattern Plan #7 used for `default_command_filename_template`.

**Update `ExportPrefsSnapshot`** (the slot struct that Plan #3 introduced)
to ride `overwrite_policy: ExportOverwritePolicy`. The snapshot is set
when an export run begins so the UI's progress + summary views see the
exact policy that drove the run.

**Update `Command::SetPreferences`** (or whatever command exposes
preferences to the UI) to accept `export_overwrite_policy:
Option<ExportOverwritePolicy>`. The bus handler writes the field to
`current.0.preferences.export_overwrite_policy` and writes project.json.
If `SetPreferences` doesn't exist yet, this task adds the minimum needed
for the UI to round-trip the checkbox. Keep the additive serde shape so
older callers' command JSON keeps working.

**Stub the bus's per-tag skip:** add a TODO comment in
`handle_export_compilations` at the location where Task 1 will insert
the skip check (just before the silent-delete-and-encode block). This
keeps the diff for Task 1 small and surgical.

**Bus serde tests:**
- `export_overwrite_policy_serializes_to_camel_case` — covers `Resume`
  → `"resume"` and `OverwriteAll` → `"overwriteAll"`.
- `export_overwrite_policy_default_is_resume` — verifies the named-
  function default for both `Preferences` and `Command` shapes.
- `command_export_compilations_omitted_overwrite_policy_round_trips`
  — verifies a pre-Plan-#6 command JSON (no `overwrite_policy` field)
  deserializes as `Resume`.
- `preferences_legacy_project_json_round_trips` — fixture JSON without
  `exportOverwritePolicy` deserializes as `Resume`.

**Update PROGRESS.txt** with a Phase 11 Plan #6 section + Task 0 row
marked shipped + commit SHA.

---

### Task 1: Bus per-tag skip-on-exists logic

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs` (the per-tag for-loop in
  `handle_export_compilations`; new helper `output_exists_and_intact`).
- Modify: existing bus unit tests (add coverage for the skip path).

**The skip check itself.** In the per-tag for-loop in
`handle_export_compilations`, after `output_path` is constructed via
`apply_template` but before the silent-delete (Phase 10 fix #13) and
the export task spawn:
```rust
// Phase 11 Plan #6: tag-level resume.
//
// If the user requested Resume mode AND the target output already
// exists on disk AND it passes a quick structural check (size + ftyp
// magic), skip the encode and emit a "skipped" event. This lets a
// retry of a failed batch only re-render the failed/remaining tags,
// not the ones that already succeeded.
//
// The check happens BEFORE the silent-delete (Phase 10 fix #13)
// because skipping must NOT delete the prior output. The silent-
// delete still runs on the OverwriteAll path and on Resume-with-
// invalid-output.
if matches!(overwrite_policy, ExportOverwritePolicy::Resume)
    && output_exists_and_intact(&output_path)
{
    tracing::info!(
        target: "export.lifecycle",
        event = "export.tag.skipped",
        selection = %label,
        reason = "already_exists",
        output_path = %output_path.display(),
    );

    // Bump the slot so the success summary shows N of N rendered
    // (skipped tags count toward `completed_tags`; Plan #6 contract).
    {
        let mut g = export_progress_for_task
            .lock()
            .expect("export_progress poisoned");
        g.completed_tags = i + 1;
        g.batch_progress = ((i + 1) as f32 / total_tags as f32).min(1.0);
        // Reset current_tag_progress so the UI's per-tag bar doesn't
        // show stale data from the prior tag.
        g.current_tag_progress = 0.0;
    }

    continue;
}

// Silently delete prior output (per Phase 10 fix #13). Runs on the
// OverwriteAll path and on Resume-with-invalid-output (the file
// existed but failed the structural check, so it's a corrupt prior
// run that we want to overwrite).
let _ = std::fs::remove_file(&output_path);
```

**Helper:**
```rust
/// Phase 11 Plan #6. Cheap structural check for "this output looks
/// complete enough to skip re-encoding". The contract is:
///
/// - File exists.
/// - `metadata.len() >= 50_000` (rules out empty / truncated outputs;
///   the smallest valid 30 fps × 1 s × VBR-low h.264 mp4 in our test
///   fixtures is ~80 KB so 50 KB is a comfortable floor).
/// - First 8 bytes are readable; bytes 4..8 are exactly `b"ftyp"`
///   (the standard ISO Base Media File Format file-type box magic).
///   This rules out a partial output that died before qtmux wrote
///   the `moov` atom — but more importantly, a file that's not an
///   mp4 at all (e.g., a stale .txt the user renamed).
///
/// We do NOT run `gstreamer_pbutils::Discoverer` here — it'd catch a
/// few additional edge cases (truncated tail, unwriteable moov) but
/// is much slower than re-encoding for a 1-s clip. Future hardening
/// could add a Discoverer probe behind a flag.
///
/// I/O errors (permission denied, etc.) are treated as "not intact" —
/// the export will then attempt to delete + re-encode, which surfaces
/// the real error via the export pipeline's own error path.
fn output_exists_and_intact(path: &std::path::Path) -> bool {
    use std::io::Read;
    let metadata = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if !metadata.is_file() || metadata.len() < 50_000 {
        return false;
    }
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut header = [0u8; 8];
    if file.read_exact(&mut header).is_err() {
        return false;
    }
    &header[4..8] == b"ftyp"
}
```

**Unit tests for the helper** (in bus.rs's `#[cfg(test)]` block):
- `intact_when_size_and_ftyp_magic_present` — write a synthetic file
  with `[0u8; 4]` followed by `b"ftyp"` followed by a 60_000-byte
  payload, assert true.
- `not_intact_when_missing` — pass a non-existent path, assert false.
- `not_intact_when_too_small` — write a 10_000-byte file with valid
  magic, assert false.
- `not_intact_when_magic_wrong` — write a 60_000-byte file starting
  with `b"00000000"`, assert false.
- `not_intact_when_directory` — pass a directory path, assert false.
- `not_intact_on_io_error` — pass a path on a permission-denied
  parent (Linux/macOS: chmod 000 + open; skip on Windows). If the
  test isn't reliably cross-platform, document with a `#[cfg(unix)]`
  guard. Acceptable to omit if the harness can't reproduce it.

**Bus integration tests** (extend the existing `bus.rs::tests` module
that already exercises `handle_export_compilations` with mock fixtures):
- `export_skips_tag_when_resume_and_output_intact` — fixture: pre-
  populate the output folder with a valid-looking .mp4 for tag "good".
  Send `Command::ExportCompilations { selections: [good], policy:
  Resume, ... }`. Assert: `export.tag.skipped { reason: "already_
  exists" }` is emitted; the per-tag spawn isn't called (or is fast-
  pathed); the file is not deleted; `completed_tags` becomes 1.
- `export_re_encodes_tag_when_overwrite_all` — same fixture; send
  with `policy: OverwriteAll`. Assert: `export.tag.started` is
  emitted (no skip); the file is replaced.
- `export_re_encodes_tag_when_resume_but_output_corrupt` — fixture:
  pre-populate with a file that's < 50 KB or has wrong magic. Assert:
  `export.tag.started` is emitted (the skip did NOT fire); the silent
  delete ran; the file was re-encoded.
- `export_skipped_tag_count_includes_in_succeeded_all` — fixture:
  3 selections, all with valid pre-existing outputs. Assert the
  outcome is `SucceededAll { tag_count: 3 }`, not `Cancelled` or
  `PartialFailure`, and `completed_tags == 3`.

**No PROGRESS.txt flip in the task commit** — orchestrator handles.

---

### Task 2: UI surface — "Overwrite existing" checkbox in export sheet

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint` (export-sheet Form
  view; new checkbox component).
- Modify: `crates/video-coach-app/src/ui.rs` (binding setup; toggle
  handler dispatches `Command::SetPreferences`).
- Modify: `crates/video-coach-app/src/bus.rs` if `SetPreferences`
  needs to be extended to accept `export_overwrite_policy` (this may
  have happened in Task 0 already — double-check before duplicating).

**Slint changes** in the export-sheet Form view:
- Add a `CheckBox` (or use Slint's `CheckBoxStyle` if one exists)
  labeled "Overwrite existing files". Default unchecked = `Resume`.
- Bind `checked` to a new in/out property
  `export-overwrite-existing: bool` on the export-sheet component
  (snake_case in Slint per existing convention isn't enforced; use
  the project's existing kebab-case-to-Rust-field convention,
  matching e.g. `export-sheet-visible`).
- The checkbox's `toggled` callback dispatches a Slint callback
  `export-overwrite-existing-changed(bool)` which `ui.rs` subscribes
  to and forwards as `Command::SetPreferences { export_overwrite_
  policy: Some(if checked { OverwriteAll } else { Resume }), .. }`.

**`ui.rs` changes:**
- On window setup, hydrate `export-overwrite-existing` from
  `current.preferences.export_overwrite_policy` (= true if
  `OverwriteAll`, false if `Resume`). Pull from
  `state_for_window.lock().preferences.export_overwrite_policy` —
  the same shape Plan #7's filename-template hydration uses.
- On `export-overwrite-existing-changed(bool)` callback, fire
  `Command::SetPreferences` with the converted policy. Reuse the
  existing send-to-bus pattern (probably `command_tx.send(...)` or
  whatever the project's existing pattern is).
- On Export click, the `Command::ExportCompilations` payload picks up
  the current value from preferences (either via the `ExportPrefsSnapshot`
  pattern from Task 0 or by reading prefs at click time). Either is
  fine; the snapshot pattern is preferred for consistency with Plan #3
  and #7.

**Slint focus discipline (per Phase 10 fix #32):**
- The new checkbox lives inside the existing `FocusScope` for the
  export-sheet form; no new key handling needed.
- The checkbox's `toggled` doesn't move focus by itself; verify the
  default Slint behavior matches the existing form-field UX (clicking
  a checkbox shouldn't grab keyboard focus from an open text input).

**No new bus handler changes** if Task 0 already extended
`SetPreferences`. If it didn't, this task adds the minimum extension
+ a serde test.

**Slint preview-mode test (best-effort):**
- The Slint compiler's `slint::ComponentHandle` test pattern can
  instantiate the component and toggle the checkbox; if the project
  has existing UI unit tests for `main.slint`, follow that pattern.
  Otherwise the harness E2E (Task 3) is sufficient coverage for the
  UI binding.

**No PROGRESS.txt flip** — orchestrator handles.

---

### Task 3: Harness E2E — `export_resume_skips_existing_tags.rs`

**Files:**
- Create: `crates/video-coach-harness/tests/export_resume_skips_existing_tags.rs`.

**Test flow:**
1. Open temp project + add a fixture source video (use the same
   fixture path as `export_smoke.rs`).
2. Use `--fixture-recording-source` to record a 1.5s clip.
3. Set `last_export_resolution = R720` for speed.
4. **First export run:**
   a. Send `Command::ExportCompilations { selections:
      [TagSelection::AllClips], output_folder: tmp.path(),
      resolution: R720, quality: Low, project_name: "test",
      overwrite_policy: Resume }`.
   b. Wait for `export.batch.completed` (timeout 60s — same lavapipe
      headroom as `export_smoke.rs`).
   c. Verify `<tmp>/all-clips - test.mp4` exists, size > 50 KB.
   d. Capture `metadata.modified()` (mtime) and a SHA-256 of the
      first 1024 bytes. Both serve as "did the file change?"
      witnesses.
5. **Second export run (the actual resume test):**
   a. Send the same `Command::ExportCompilations` with the same
      selections + `overwrite_policy: Resume`.
   b. Wait for `export.batch.started`.
   c. Wait for `export.tag.skipped` with attributes `selection_kind=
      "all_clips"` AND `reason="already_exists"`. Timeout 5s
      (skipping is local file I/O, no GPU work).
   d. Wait for `export.batch.completed`. Assert the outcome
      reflected in `ExportProgressSlot` is `SucceededAll { tag_count:
      1 }`.
   e. Re-read the .mp4's metadata + first-1024-bytes SHA-256. Assert
      mtime is unchanged (or, if the test framework's mtime resolution
      isn't reliable across filesystems, assert the SHA-256 matches
      step 4d).
6. **Third run with overwrite forced:**
   a. Send `Command::ExportCompilations { ..., overwrite_policy:
      OverwriteAll }`.
   b. Wait for `export.tag.started` (NOT skipped). Wait for
      `export.batch.completed`.
   c. Verify the file's mtime updated (or, equivalently, the first-
      1024-bytes SHA-256 changed — encoder timestamps in qtmux can
      drift between runs even on identical input).
7. Quit cleanly.

**Cancel-then-resume test** (separate `#[test]`):
- Setup: 2 tags, "tag-a" and "tag-b" (set on the clip via
  hand-writing project.json — `SetClipTags` may not exist as a bus
  command in the current codebase; if it doesn't, use the AllClips
  selection pattern + tweak the test to use one tag = AllClips).
  *If multi-tag setup proves expensive, this test reduces to
  AllClips + a second selection that's known-empty (also tests the
  empty-plan + already-exists interaction).*
- Run 1: send `Command::ExportCompilations { selections: [tag-a,
  tag-b], policy: Resume }`. After tag-a's `export.tag.completed`
  fires, send `Command::CancelExport`. Wait for `export.batch.
  cancelled`. Verify `tag-a.mp4` exists; `tag-b.mp4` does not.
- Run 2: send the same `Command::ExportCompilations` again. Assert:
  - `export.tag.skipped { selection: "tag-a", reason: "already_
    exists" }` fires.
  - `export.tag.started { selection: "tag-b" }` then `export.tag.
    completed` fires.
  - `export.batch.completed` fires; `ExportRunOutcome::SucceededAll
    { tag_count: 2 }`.
  - `tag-a.mp4` mtime is unchanged. `tag-b.mp4` exists, size > 50 KB.
- Quit cleanly.

**Test structure:**
- Mirror `export_partial_failure_smoke.rs`'s test harness setup
  exactly (same `common::` helpers, same socket-event-wait pattern).
- Use `wait_for_event` with explicit `selection` + `reason` filters
  if the harness's event matcher supports them; otherwise filter
  in the test body.
- Frame-pushed assertions: only assert frames_pushed >= 20 on
  rendered tags (skipped tags don't emit frames). The Phase 10
  closeout already documented this floor; mirror it.

**Update PROGRESS.txt + commit.**

---

## Done when

- All 4 tasks committed.
- CI matrix green on macOS / Linux / Windows + media-tests.
- New `export_resume_skips_existing_tags` harness E2E passing.
- New `export.tag.skipped { reason = "already_exists" }` event flows
  over the socket alongside the existing `reason = "empty_plan"`
  event, with the same target (`export.lifecycle`).
- Toggling "Overwrite existing" in the export-sheet form persists
  through quit + relaunch (project.json round-trip).
- A second click of Export after a `PartialFailure` skips the already-
  rendered tags (verified manually + by harness).
- A second click of Export after `Cancelled` skips the already-
  rendered tags (verified manually + by harness).
- No regressions in Phase 1–10 + earlier Phase 11 tests.
- PROGRESS.txt reflects each task + the plan SHIPPED line + CI
  run id.

---

## Closeout — Phase 11 Plan #6 SHIPPED (placeholder, fill in at CI green)

**CI run**: <run-id> (final SHA <sha>), green on all 4 jobs.

### Commits (in shipping order)

| Stage | SHA | Summary |
|---|---|---|
| Plan first pass | TBD | Initial plan + N baked-in fixes |
| Plan first adversarial | TBD | Plan fixes #N1-Nn |
| Task 0 | TBD | Preflight: ExportOverwritePolicy enum, Preferences field, Command field, ExportPrefsSnapshot ride, SetPreferences extension, serde tests |
| Task 1 | TBD | Bus per-tag skip-on-exists: output_exists_and_intact helper + per-tag for-loop skip branch + bus integration tests |
| Task 2 | TBD | UI: "Overwrite existing" checkbox in export-sheet Form, ui.rs binding + toggle handler |
| Task 3 | TBD | Harness E2E: export_resume_skips_existing_tags + cancel-then-resume coverage |
| Closeout | TBD | PROGRESS.txt SHA fill-in + plan closeout |

### Adversarial-fix coverage

(To be populated during the `READY_FOR_CLOSEOUT` → `CLOSEOUT_COMMITTED`
state transition. Each adversarial fix from the section above should
get a ✅ row here naming the commit that shipped it.)

### Behavior changes from Phase 10

- **Default behavior changed.** Phase 10's `Command::ExportCompilations`
  always silently re-encoded a per-tag output even if it existed on
  disk. Plan #6 changes the default to skip-if-exists. Users relying
  on the old behavior must tick the new "Overwrite existing" checkbox
  in the export-sheet form.
- **New `export.tag.skipped` reason.** `reason = "already_exists"` is
  new in Plan #6; `reason = "empty_plan"` continues to fire from
  Phase 10's empty-plan code path. Consumers of the event log should
  match on the `reason` attribute, not just the event name.
- **`completed_tags` semantics expanded.** Skipped-as-already-existing
  tags now contribute to the `completed_tags` counter in
  `ExportProgressSlotData`. A run that skipped 5 of 6 and rendered 1
  of 6 reports `completed_tags = 6` and `outcome = SucceededAll {
  tag_count: 6 }`.

### Deferred to Phase 12 (or later)

- **Mid-tag checkpointing.** Resume from frame N within a single tag.
  Requires fragment-aware mp4 restart (or tee'ing intermediate frames
  to disk and re-muxing on resume).
- **Fingerprint-based staleness detection.** Detecting when the user
  re-recorded the underlying clip after the .mp4 was written and
  forcing re-encode in that case.
- **`Discoverer`-based output validation.** Replacing the metadata-
  size + magic-bytes check with a true gst-pbutils probe for files
  that pass the cheap check but fail full media validation.
- **"Show me which tags will be skipped" preview.** A pre-export
  panel that lists tags with green "(will skip — already exists)" /
  yellow "(will overwrite — file invalid)" / blue "(will render —
  no prior output)" labels. Plan #6 ships the implementation; a
  future plan adds the preview affordance.
- **A separate "Force re-encode this one" per-tag toggle.** Currently
  the "Overwrite existing" checkbox is global to the batch. A future
  plan could let the user override per-row.

### Known-flaky tests / future hardening

- (Populated post-CI — likely none, but document any flakes the
  harness E2E exposes here.)

### Coverage gaps (acceptable for shipping)

- The "Overwrite existing" checkbox's `toggled` event firing while
  an export is in flight. The bus may or may not pick up the new
  policy mid-batch; specifying which is out of scope for Plan #6
  (the user's intent is ambiguous — did they mean "this batch" or
  "from now on"?). The implementation captures the policy at
  Export click time via the `ExportPrefsSnapshot`; a mid-batch
  toggle has no effect on the running batch. Documented here.
- Multi-tag batch with mixed Resume + corrupt + missing outputs.
  The per-tag for-loop handles each independently, but no single
  test exercises all three branches in one run.
- Concurrent Finder-delete during the skip check window. Documented
  in "Known unknowns" #4 as out-of-scope.
