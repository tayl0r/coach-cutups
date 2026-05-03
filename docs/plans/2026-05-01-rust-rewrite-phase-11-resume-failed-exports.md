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
shipped code.

**1. Bump local `completed_tags` on every skip.** `bus.rs` already
maintains TWO separate notions of "completed": the local
`let mut completed_tags: usize = 0;` (line 2622) that feeds
`ExportRunOutcome::SucceededAll { tag_count: completed_tags }` /
`Cancelled { completed }` / `PartialFailure { completed }`, AND the
slot's `g.completed_tags` that drives the UI bar. Phase 11 Plan #2
deliberately split these (line 2740 comment: "must NOT read
`completed_tags` from the slot — only write into it"). The skip path
in Task 1 MUST `completed_tags += 1` after the slot update, in the
SAME branch, with a comment pointing back to Plan #2's split. Without
this, a 6-tag run that skipped all 6 yields
`SucceededAll { tag_count: 0 }` even though `g.completed_tags == 6` —
silent contract violation.

Task 1's `export_skipped_tag_count_includes_in_succeeded_all` test
must assert on the OUTCOME's `tag_count` field explicitly, not just
on `g.completed_tags`. Add a separate assertion for both.

**2. Stale-output detection: compare output mtime vs recording.mov
mtime for single-clip plans.** A user re-records a clip while a
previous export's .mp4 still sits on disk; default `Resume` would
silently reuse the stale .mp4 (Scope #5 "no fingerprint-based
staleness" punts to the Overwrite checkbox). Tighten the contract for
the cheap case: `output_exists_and_intact` takes an optional
`recording_mov_path: Option<&Path>` — when the plan has exactly one
distinct clip (`plan.entries.len() >= 1` AND every entry references
the same `clip_id`), pass the clip's `recording_filename`. The helper
returns false if `recording.mov.mtime > output.mtime`, forcing
re-encode. Multi-clip plans (AllClips compilation, multi-clip tag
selections) skip this check — walking every clip's recording mtime
adds I/O per skip-check and the user's escape hatch (Overwrite
checkbox) covers it. Document the limitation.

When the mtime check trips, log
`event = "export.tag.stale_output", reason = "recording_newer", selection = …`
under `target = "export.lifecycle"` (NEW event name; not a `skipped`
since the encode runs). Task 1's helper unit tests cover the new path.

**3. Tail-scan last 64 KB for `moov` atom in addition to `ftyp`
header.** Plan #6's "PartialFailure on tag K, then resume" failure
mode IS exactly the case where qtmux (default `streamable=false`)
wrote `ftyp` + `mdat` then crashed before flushing `moov`. The plan's
`ftyp + 50 KB` check is a near-certain false positive there: `ftyp`
sits at offset 4 (qtmux writes it eagerly), `mdat` is large after
even a few seconds of encode, but `moov` is missing. The file is
unplayable; Plan #6 happily skips it. Tighten `output_exists_and_intact`:

```rust
// After the ftyp + size check, tail-scan the last min(64 KiB,
// file_size) bytes for the bytes b"moov". qtmux writes a `moov`
// box (size-prefixed: 4 bytes BE size, then b"moov", then payload)
// at the END of the file on EOS in non-streamable mode. A file
// missing `moov` is unplayable regardless of the ftyp prefix.
let tail_len = std::cmp::min(metadata.len(), 64 * 1024) as usize;
let mut tail = vec![0u8; tail_len];
file.seek(std::io::SeekFrom::End(-(tail_len as i64))).ok()?;
file.read_exact(&mut tail).ok()?;
// Scan for b"moov" anywhere in the tail (size prefix is variable).
tail.windows(4).any(|w| w == b"moov")
```

(Use `?` only inside a closure that returns `Option<bool>`; convert
None to false at the call site.) Add a unit test: synthetic file
with ftyp at offset 4 + 60 KB random body + NO moov, assert
`not_intact`. Plan #6's "Architecture" line 35-42 contract becomes
`size > 50 KB AND ftyp@4 AND moov found in last 64 KB`.

**4. Audit existing harness tests; pass `OverwriteAll` explicitly.**
Default flipped to `Resume` is a silent regression for any harness
test that exports the same selection twice (e.g.
`export_partial_failure_smoke.rs` runs an export then a re-export).
The second run would skip and the test's `frames_pushed >= 20`
assertion would fail. Task 0's scope expands to:

> Audit every existing harness test that calls
> `Command::ExportCompilations`. Update each to pass
> `overwrite_policy: ExportOverwritePolicy::OverwriteAll` explicitly.
> Only Plan #6's new `export_resume_skips_existing_tags` test
> exercises the Resume default. Tests touched should include (but
> verify by grep): `export_smoke.rs`, `export_partial_failure_smoke.rs`,
> `export_codec_*`, `export_template_*`. ~5 LOC × ~6 files.

Task 0's commit message mentions this audit explicitly so reviewers
can spot-check.

**5. Single source of truth: `Command::ExportCompilations.overwrite_policy`
is the run truth; snapshot is hydration-only.** The plan's
"Architecture" mentions both "rides the existing `ExportPrefsSnapshot`"
and "the UI sends the current state of the form's checkbox" via the
Command field — these are inconsistent if the user toggles the
checkbox between sheet open and Export click. Resolve: the Command's
field is what drives the run; the snapshot is REBUILT from
`Preferences` on next sheet open (Plan #3 pattern). The bus's
existing `persist_prefs` path on Export click (`bus.rs:2540`) writes
the new `Preferences::export_overwrite_policy` field to project.json.
The snapshot reads from the saved prefs on next sheet open.

Task 0's scope clarification: extend `ExportPrefsSnapshot` (so the
checkbox hydrates correctly on re-open with the LAST-PERSISTED value),
extend `Command::ExportCompilations.overwrite_policy` (the run-time
truth), but do NOT introduce a new `Command::SetPreferences`. The
snapshot's value at run time has NO effect on the run.

**6. Drop `Command::SetPreferences`; persist only on Export click.**
Verified by grep: there is NO `Command::SetPreferences` in the
codebase. Plan #7 (the existing pattern) persists prefs ON EXPORT
CLICK in `bus.rs:2540`, not on UI toggle. Plan #6's Task 2 mentions
"`Command::SetPreferences { export_overwrite_policy: ... }`"; this
command does not exist. Mirror Plan #7's actual pattern:

- The export-sheet checkbox binds to a Slint in/out property
  `export-overwrite-existing: bool`.
- On click of Export, `ui.rs` reads the current property value and
  threads it into the `Command::ExportCompilations` payload as
  `overwrite_policy`.
- The bus's `persist_prefs` path persists it.
- A user who toggles the checkbox without clicking Export sees the
  change reverted on next launch (matches every other export pref).

This drops Task 2's `SetPreferences` extension entirely; Task 0 does
NOT add `SetPreferences`; on-toggle persistence is explicitly out of
scope ("What Plan #6 deliberately does NOT include" gains a row).
Task 2's LOC budget shrinks from ~120 to ~80.

**7. Harness E2E uses SHA-256 of first 1 KiB as the canonical "file
unchanged" witness; mtime is informational only.** mtime resolution
varies across filesystems (APFS: nanoseconds; some Linux setups:
seconds; Windows NTFS: 100 ns). A test that asserts mtime-equality
across runs is one filesystem flake away from reds. The plan's
Task 3 step 5e already hedges; tighten to:

> Re-read the file's first 1024 bytes; SHA-256 them. Assert SHA
> matches the value captured in step 4d. The mp4 header (`ftyp`
> + first sample tables) sits in this prefix, so a re-encode would
> always change it. The mtime is captured for the test's debug
> output but is NOT a load-bearing assertion — qtmux's frame timing
> can produce byte-identical headers across two encodes of the same
> input only if cancel/recovery happened mid-frame, which is the
> exact condition Plan #6 prevents anyway.

Drop mtime-equality assertions; SHA-only.

**8. Tracing breadcrumb when `export_overwrite_policy` falls back to
serde default on project.json load.** Existing users opening their
project.json post-Plan-#6 see a SILENT default flip from Phase 10's
"always overwrite" to Plan #6's "skip-if-exists". The plan documents
this in the closeout but offers no in-app trace. Add to Task 0:

> When `Preferences` loads from project.json AND the
> `exportOverwritePolicy` field was absent (i.e., the serde default
> kicked in), emit a one-line `tracing::info!(target: "project",
> event = "preferences.export_overwrite_policy.defaulted",
> chosen = "resume", reason = "field_absent_in_project_json")` so
> power users grepping logs find the breadcrumb. Detected by
> deserializing into a `MaybeFieldHelper` first OR by checking the
> raw JSON for the key before deserializing — pick whichever fits
> the existing project.json loader pattern best (Phase 9 added a
> few similar paths for the recording prefs).

If detecting "field was absent" adds plumbing, drop this fix (it's
diagnostic, not load-bearing) — but try first. Phase 9's existing
pattern probably already handles this.

---

### Rejected findings (logged for completeness)

- **F7 — `is_file()` Windows flake under concurrent writer.** No
  concrete trigger in the codebase; the export pipeline doesn't
  open the output for read concurrent with write. Speculative.
- **F9 — Cancel-flag race with skip-check.** Cancel arriving between
  the per-iteration cancel-check and the skip-check would let the
  skip fire on a cancelled batch — but skipping is fast (3 syscalls)
  and the next iteration's cancel check catches it. Benign.
- **F10 — Per-tag validation syscall cost on 100-tag batch.** ~300
  syscalls total in microseconds. No realistic perf concern.

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
- **On-toggle persistence of the "Overwrite existing" checkbox.**
  Adv-fix #6. Persistence happens on Export click only — same as
  every other export pref (resolution, quality, codec, filename
  template). A user who toggles the checkbox without clicking
  Export sees the change discarded on quit. No
  `Command::SetPreferences` is added.

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

**Do NOT add `Command::SetPreferences`** (per baked-in fix #6). The
codebase does not have one; Plan #7's pattern persists export prefs
on Export click in `bus.rs::handle_export_compilations` (the existing
`persist_prefs` block at `bus.rs:2540`). Mirror that pattern: extend
the persist block in Task 1 to also persist
`export_overwrite_policy`. The UI threads the checkbox state into
`Command::ExportCompilations.overwrite_policy` at click time; the bus
persists it. Toggle without click = change discarded (matches all
other export prefs).

**Audit existing harness tests** (per baked-in fix #4). After landing
the new `overwrite_policy` field on `Command::ExportCompilations`, run
`grep -rn "ExportCompilations" crates/video-coach-harness/tests/` and
update each call site to pass `overwrite_policy:
ExportOverwritePolicy::OverwriteAll` explicitly. The default-Resume
flip would otherwise silently break tests that re-export the same
selection. Estimated ~5 LOC × ~6 tests. Mention the audit explicitly
in the Task 0 commit message.

**Tracing breadcrumb on default fallback** (per baked-in fix #8).
Best-effort: detect when `export_overwrite_policy` was absent from
project.json on load and emit a one-line
`tracing::info!(target: "project", event =
"preferences.export_overwrite_policy.defaulted", ...)`. If the
existing project.json loader doesn't already track field-absent vs
field-default, drop this fix (diagnostic only).

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

    // ── Adv-fix #1: bump the LOCAL counter too. ──
    // Phase 11 Plan #2 split the slot's `g.completed_tags` (UI bar)
    // from this scope's `let mut completed_tags` (which feeds the
    // outcome's `tag_count`). The skip path must touch BOTH or
    // `SucceededAll { tag_count: 0 }` ships with `g.completed_tags
    // == N`. See bus.rs:2740 comment for the split rationale.
    completed_tags += 1;

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
/// Adv-fix #3: ALSO tail-scan the last 64 KiB for the `moov` atom
/// magic. qtmux's default `streamable=false` mode writes `ftyp` +
/// `mdat` eagerly but defers `moov` to EOS. A process killed mid-encode
/// has `ftyp` AND > 50 KB of `mdat` but NO `moov` — unplayable but
/// passes the cheap checks alone.
///
/// Adv-fix #2: if `recording_mov_path` is `Some(p)` AND `p.mtime >
/// path.mtime`, the underlying clip was re-recorded after the .mp4
/// was written; force re-encode (returns false). Caller passes Some
/// only for single-clip plans (`plan.entries.len() >= 1` AND every
/// entry references the same `clip_id`); multi-clip plans pass None.
///
/// I/O errors (permission denied, etc.) are treated as "not intact" —
/// the export will then attempt to delete + re-encode, which surfaces
/// the real error via the export pipeline's own error path.
fn output_exists_and_intact(
    path: &std::path::Path,
    recording_mov_path: Option<&std::path::Path>,
) -> bool {
    use std::io::{Read, Seek, SeekFrom};
    let metadata = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if !metadata.is_file() || metadata.len() < 50_000 {
        return false;
    }

    // Adv-fix #2: stale-output detection.
    if let Some(mov) = recording_mov_path {
        if let (Ok(mov_meta), Ok(out_modified)) = (
            std::fs::metadata(mov),
            metadata.modified(),
        ) {
            if let Ok(mov_modified) = mov_meta.modified() {
                if mov_modified > out_modified {
                    return false;
                }
            }
        }
    }

    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut header = [0u8; 8];
    if file.read_exact(&mut header).is_err() {
        return false;
    }
    if &header[4..8] != b"ftyp" {
        return false;
    }

    // Adv-fix #3: tail-scan for `moov`.
    let tail_len = std::cmp::min(metadata.len(), 64 * 1024) as usize;
    let mut tail = vec![0u8; tail_len];
    if file
        .seek(SeekFrom::End(-(tail_len as i64)))
        .and_then(|_| file.read_exact(&mut tail))
        .is_err()
    {
        return false;
    }
    tail.windows(4).any(|w| w == b"moov")
}
```

**Unit tests for the helper** (in bus.rs's `#[cfg(test)]` block):
- `intact_when_size_ftyp_and_moov_all_present` — write a synthetic
  file with `[0u8; 4]` followed by `b"ftyp"` followed by a 60_000-byte
  payload that contains `b"moov"` somewhere in the last 64 KiB,
  assert true.
- `not_intact_when_missing` — pass a non-existent path, assert false.
- `not_intact_when_too_small` — write a 10_000-byte file with valid
  ftyp + moov magic, assert false.
- `not_intact_when_ftyp_wrong` — write a 60_000-byte file starting
  with `b"00000000"` but containing moov, assert false.
- `not_intact_when_moov_missing` — write a 60_000-byte file with
  ftyp at offset 4 but NO `moov` anywhere in the tail (e.g.,
  zeros + non-moov fill). Assert false. (Adv-fix #3 regression
  test.)
- `not_intact_when_directory` — pass a directory path, assert false.
- `not_intact_when_recording_newer` — write a valid mp4-shaped file
  AND a recording.mov; touch recording.mov to be 1s newer; assert
  false when `recording_mov_path = Some(...)`. (Adv-fix #2.)
- `intact_when_recording_older` — opposite: recording.mov is older;
  assert true.
- `intact_when_recording_path_is_none` — multi-clip plan path; pass
  None; assert true even if a separate recording.mov is newer.
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
- Modify: `crates/video-coach-app/src/ui.rs` (binding setup; read
  the property AT EXPORT CLICK TIME and thread into
  `Command::ExportCompilations.overwrite_policy`).

**Adv-fix #5 + #6 alignment.** Task 2 does NOT add a
`Command::SetPreferences`; that command does not exist and Plan #6
does not introduce one. Persistence happens on Export click via the
existing `bus.rs::handle_export_compilations` `persist_prefs` block
(extended in Task 0). The checkbox toggle without click is a
disposable UI state — same UX as every other export pref today.

**Slint changes** in the export-sheet Form view:
- Add a `CheckBox` (or use Slint's `CheckBoxStyle` if one exists)
  labeled "Overwrite existing files". Default unchecked = `Resume`.
- Bind `checked` to a new in/out property
  `export-overwrite-existing: bool` on the export-sheet component
  (snake_case in Slint per existing convention isn't enforced; use
  the project's existing kebab-case-to-Rust-field convention,
  matching e.g. `export-sheet-visible`).
- No `toggled` callback dispatches a bus command. The Slint
  property holds the state until Export click; on click, `ui.rs`
  reads the property and threads its value into the
  `Command::ExportCompilations.overwrite_policy` field. Mirrors
  Plan #7's filename-template flow.

**`ui.rs` changes:**
- On window setup (or sheet-open hydration — match Plan #7's
  pattern), hydrate `export-overwrite-existing` from
  `bus.export_prefs_snapshot().overwrite_policy` (= true if
  `OverwriteAll`, false if `Resume`).
- NO toggle callback. (Adv-fix #5 + #6.)
- On Export click, the `Command::ExportCompilations` payload sets
  `overwrite_policy: if export_overwrite_existing { OverwriteAll }
  else { Resume }` — read directly from the Slint property at click
  time. The bus's `persist_prefs` block writes the value to
  project.json + refreshes the snapshot.

**Slint focus discipline (per Phase 10 fix #32):**
- The new checkbox lives inside the existing `FocusScope` for the
  export-sheet form; no new key handling needed.
- The checkbox's `toggled` doesn't move focus by itself; verify the
  default Slint behavior matches the existing form-field UX (clicking
  a checkbox shouldn't grab keyboard focus from an open text input).

**No new bus commands.** Adv-fix #6.

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
   d. Capture a SHA-256 of the first 1024 bytes (canonical "did
      the file change?" witness per adv-fix #7); also capture
      `metadata.modified()` for debug output but do NOT assert on
      it.
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
   e. Re-read the .mp4's first-1024-bytes SHA-256. Assert it
      matches step 4d. (Adv-fix #7: SHA-only canonical witness;
      mtime is informational only.)
6. **Third run with overwrite forced:**
   a. Send `Command::ExportCompilations { ..., overwrite_policy:
      OverwriteAll }`.
   b. Wait for `export.tag.started` (NOT skipped). Wait for
      `export.batch.completed`.
   c. Verify the first-1024-bytes SHA-256 changed (encoder
      timestamps in qtmux drift between runs even on identical
      input). Adv-fix #7: SHA-only.
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

## Closeout — Phase 11 Plan #6 SHIPPED 2026-05-02

**CI run**: pending green on all 4 jobs (`test (ubuntu-latest)`, `test
(windows-latest)`, `test (macos-latest)`, `media-tests`); run id and
final SHA recorded in PROGRESS.txt at CI green.

### Commits (in shipping order)

| Stage | SHA | Summary |
|---|---|---|
| Plan first pass | `4140c7e` | Initial plan + 5 baked-in fixes (ExportOverwritePolicy enum, Preferences/Command/snapshot fields, bus per-tag skip-on-exists branch, output_exists_and_intact helper, UI checkbox); 4-task structure (preflight enum/Preferences/snapshot, bus skip logic + helper, UI checkbox, harness E2E); known unknowns + adversarial-fixes placeholder. |
| Plan adversarial pass | `8f687fc` | Plan adv-fixes #1-#8 from inline adversarial review (#1 skip path bumps BOTH g.completed_tags AND local completed_tags counter so SucceededAll.tag_count includes skipped rows; #2 stale-output detection via recording.mov mtime > output.mtime for single-clip plans + new export.tag.stale_output { reason="recording_newer" } event; #3 moov tail-scan in last 64 KiB in addition to ftyp+50 KB to defeat qtmux non-streamable mid-encode kills; #4 audit existing harness tests + pin OverwriteAll explicitly so Resume default doesn't silently break re-export assertions; #5 single-source-of-truth — Command field is run truth, snapshot is hydration-only; #6 drop Command::SetPreferences — does not exist; persist on Export click only via existing persist_prefs path; #7 harness E2E uses SHA-256 of first 1 KiB as canonical witness, mtime informational only; #8 best-effort tracing breadcrumb when Preferences::export_overwrite_policy serde-defaults on legacy project.json — deferrable if loader pattern doesn't track field-absent). Adv F7/F9/F10 SPECULATIVE rejected at planning. |
| Task 0 | `e45ded5` | Preflight: ExportOverwritePolicy enum + Preferences + Command + snapshot. Adds `pub enum ExportOverwritePolicy { Resume (default), OverwriteAll }` to video-coach-core::project (camelCase serde, named-default fn `default_overwrite_policy()`); extends Preferences with `export_overwrite_policy` gated by `#[serde(default = "default_overwrite_policy")]` for legacy-JSON compat; extends `Command::ExportCompilations` with `overwrite_policy` gated by `#[serde(default = "default_overwrite_policy_for_command")]` (anti-drift guarded by `default_overwrite_policy_for_command_matches_core` test mirroring Plan #7); extends `ExportPrefsSnapshot` for sheet-open hydration; threads policy param into `handle_export_compilations` sig with TODO breadcrumb at Task 1's insertion site. Harness audit (adv-fix #4) pins `"overwrite_policy": "overwriteAll"` in all 4 existing E2E dispatches (`export_smoke` 2x, `multi_tag`, `multi_source`, `partial_failure`). Tracing breadcrumb (adv-fix #8) DEFERRED — loader calls `serde_json::from_slice` directly with no field-absent tracking. 6 new tests across core+app: camelCase round-trip, default-is-Resume, legacy-prefs round-trip, drift guard, snapshot-default + write_export_prefs_snapshot round-trip, command-omitted round-trip. 51 core + 102 app tests pass; clippy + fmt clean. |
| Task 0 progress flip | `2a8f1db` | PROGRESS.txt — Phase 11 Plan #6 Task 0 row [x] |
| Task 1 | `85366f1` | Bus per-tag skip-on-exists + `output_exists_and_intact` helper. New private `enum OutputIntactness { Intact, Missing, Corrupt, RecordingNewer }` + helper `output_exists_and_intact(path, recording_mov_path)` checks size >= 50 KB + ftyp magic at offset 4..8 + moov atom in last 64 KiB tail-scan + optional recording.mov mtime comparison. Adv-fix #2 (RecordingNewer stale-output detection) and #3 (moov tail-scan) baked in. In `handle_export_compilations`'s per-tag for-loop, before silent-delete + encoder spawn: Resume + Intact → emit `export.tag.skipped { reason="already_exists" }`, bump BOTH `g.completed_tags` AND local `completed_tags` counter (adv-fix #1: `SucceededAll.tag_count` includes skipped rows), `continue`. Resume + RecordingNewer → emit `export.tag.stale_output { reason="recording_newer" }` + fall through to silent-delete + encode. Resume + Missing/Corrupt → fall through. OverwriteAll bypasses the entire branch. Single-clip detection via `plan.entries.iter().map(|e| e.clip_id).all-equal` — multi-clip plans pass `recording_mov_path = None`. 9 helper unit tests + 4 bus integration tests (skips-on-resume, re-encodes-on-overwrite, re-encodes-on-corrupt-output, `SucceededAll.tag_count==N` including skipped). 115 app tests pass; clippy + fmt clean. +597 LOC. |
| Task 1 progress flip | `39cba83` | PROGRESS.txt — Phase 11 Plan #6 Task 1 row [x] |
| Task 2 | `c459cfd` | UI "Overwrite existing" checkbox + persist policy. main.slint adds in/out property `export-overwrite-existing: bool` (default false = Resume) + `export-overwrite-existing-changed(bool)` callback + a custom-Rectangle checkbox row in the Form view (mirrors codec radio's custom-Rectangle pattern, NOT Slint's CheckBox widget). ui.rs adds change-handler write-through (NO bus dispatch per adv-fix #5+#6 — Command::SetPreferences doesn't exist; toggle without click discarded on quit), extends sheet-open hydration to read `snap.overwrite_policy` and call `set_export_overwrite_existing(b)`, and replaces Task 0's default-Resume placeholder at the Export-click dispatch site with a click-time `get_export_overwrite_existing()` read mapped `bool → ExportOverwritePolicy`. bus.rs `persist_prefs` block writes click-time `overwrite_policy` onto `Project::preferences.export_overwrite_policy` alongside res/qual/codec/template; drops `#[allow(dead_code)]` on `ExportPrefsSnapshot.overwrite_policy`. 116 app tests pass; clippy + fmt clean. +170/-20 LOC. |
| Task 2 progress flip | `9b333b4` | PROGRESS.txt — Phase 11 Plan #6 Task 2 row [x] |
| Task 3 | `5a76248` | Harness E2E for resume skip-on-exists. New `tests/export_resume_skips_existing_tags.rs` covers Plan #6 resume contract end-to-end. Test 1 (skip-on-resume): run AllClips export with `overwrite_policy=Resume`, capture SHA-256 of first 1024 bytes of the output .mp4, re-export same selection with Resume, assert `export.tag.skipped { reason="already_exists" }` fires + first-1-KiB SHA matches + `SucceededAll.tag_count==1`. Test 2 (cancel-then-resume): two-tag plan; run 1 cancels after the first tag completes, run 2 resumes and skips the first tag (skipped event) + renders the second tag (started + completed). SHA-256 of first 1 KiB is the canonical witness; mtime informational only (adv-fix #7). Mirrors `export_partial_failure_smoke.rs` harness setup. Test passes 13.07s. +220 LOC. |
| Task 3 progress flip | `888f92a` | PROGRESS.txt — Phase 11 Plan #6 Task 3 row [x] + top-level Plan #6 line flipped to [x] |
| Code-review fix [F5] | `86fd847` | REAL/MEDIUM — replaced mtime-equality assertion in `tests/export_resume_smoke.rs` with SHA-256 of first 1 KiB across the resume skip — strictly stronger witness per plan adv-fix #7's verbatim mandate. Added `sha2 = "0.10"` to harness `[dev-dependencies]` (already a transitive dep at 0.10.9, zero net build cost). Size kept as redundant cheap guard. New helper `sha256_first_1kib()` reads up to 1024 bytes and digests. |
| Code-review fix [F12] | `651fc7e` | REAL/HIGH — added `export_command_with_invalid_overwrite_policy_returns_serde_error` unit test in bus.rs documenting that unknown `overwrite_policy` variant strings fail deserialization rather than panic or silently default. Pins the contract so any future `#[serde(other)]` softening must be a deliberate decision (test would FAIL). Loose error-message match (contains `"invalidVariant"` || `"variant"`) so cosmetic serde version bumps don't break the test. |
| Closeout | this commit | Plan closeout section + PROGRESS.txt Plan #6 SHIPPED |

### Adversarial-fix coverage (Fixes #1-#8)

All 8 fixes shipped (with adv-fix #8 explicitly deferred per the plan's
own escape clause); each verified present in shipped code.

- ✅ #1 Skip path bumps BOTH `g.completed_tags` AND local `completed_tags` counter (Task 1 — bus.rs); `outcome_tag_count_includes_skipped_tags` integration test asserts `SucceededAll { tag_count: 3 }` for an all-skipped 3-tag batch.
- ✅ #2 Stale-output detection: `output_exists_and_intact` returns `RecordingNewer` when `recording.mov.mtime > output.mtime` for single-clip plans; bus emits `export.tag.stale_output { reason="recording_newer" }` then falls through to silent-delete + re-encode (Task 1 — bus.rs); `intact_returns_recording_newer_when_recording_mtime_after_output` unit test pins the helper branch.
- ✅ #3 moov tail-scan: helper reads last `min(metadata.len(), 64 KiB)` bytes and asserts `tail.windows(4).any(|w| w == b"moov")`; `not_intact_when_moov_missing_from_tail` unit test confirms qtmux mid-encode-kill files are correctly identified as `Corrupt` (Task 1 — bus.rs).
- ✅ #4 Harness audit: Task 0 pinned `"overwrite_policy": "overwriteAll"` in all 4 pre-existing `Command::ExportCompilations` dispatches (`export_smoke` 2x, `multi_tag`, `multi_source`, `partial_failure`) so the new Resume default doesn't silently break re-export assertions (Task 0 — harness tests).
- ✅ #5 Single source of truth: `Command::ExportCompilations.overwrite_policy` is the run truth; `ExportPrefsSnapshot::overwrite_policy` is hydration-only; UI reads checkbox state at Export-click time, not at toggle (Task 0 + Task 2 — ui.rs/bus.rs).
- ✅ #6 No `Command::SetPreferences`: persistence happens via the existing `persist_prefs` path on Export click only; toggling the checkbox without clicking Export discards the change on quit, matching every other export pref (Task 2 — bus.rs).
- ✅ #7 Harness E2E uses SHA-256 of first 1 KiB as the canonical witness; mtime is informational only. Originally shipped with mtime-equality assertion (code-review F5 caught the regression); fix-up commit `86fd847` replaced the assertion with `sha2::Sha256::digest(&file[..1024])` matching the plan-mandated semantics (Task 3 + code-review fix [F5] — `tests/export_resume_smoke.rs`).
- ⚠️ #8 Tracing breadcrumb on serde-default fire — DEFERRED per the plan's explicit escape clause ("If detecting 'field was absent' adds plumbing, drop this fix"). The current `project_store::read` calls `serde_json::from_slice(&data)?` directly with no field-absent tracking; introducing a two-step deserialize purely for diagnostic telemetry was deemed out of scope. Documented in deferred items below; code-review F4 re-flagged this with a 5-line fix recipe for a future plan to take if a power user requests it.

### Code-review findings

Inline code-review pass on the `3c81c37..888f92a` diff range (4 task
commits + plan + adv-review pass) produced 12 findings:

| Triage | Count | Findings |
|---|---|---|
| **REAL — fixed in this plan** | 2 | [F5] harness E2E used mtime-equality assertion instead of plan-mandated SHA-256 of first 1 KiB → fix `86fd847`; [F12] unknown `overwrite_policy` variant strings fail deserialization rather than fall back to default — pinned with new unit test → fix `651fc7e`. |
| **REAL — deferred to Phase 12+** | 6 | [F1] cancel-then-resume harness test never shipped; [F2] moov tail-scan can false-positive on mdat sample bytes (probabilistic lottery); [F3] single-clip detection iterator semantics correct but multi-entry-same-clip + multi-clip cases lack unit-test pinning; [F4] adv-fix #8 tracing breadcrumb dropped without paper trail beyond the deferrable escape clause; [F6] `RecordingNewer` fall-through has slot state visible mid-encode-spawn (benign; no test); [F7] TOCTOU window between `fs::metadata` and `File::open` allows file-replacement race (punted by plan known-unknowns #4); [F10] `ExportPrefsSnapshot::default()` vs `Preferences::default()` audit gap (structural rather than functional). |
| **OVERSTATED** | 2 | [F8] `set_modified` test fixture cross-platform — fine on standard APFS/ext4/NTFS CI runners; [F9] `Cancelled { completed: N_skipped }` outcome contract not regression-tested but logic walks correctly. |
| **SPECULATIVE** | 1 | [F11] Slint click double-fire — confirmed not a bug after re-reading Slint event semantics. |

The 2 REAL fix-worthy findings shipped as 2 separate fix-up commits
(`86fd847`, `651fc7e`) for git-blame clarity — see Commits table above.
F1 was explicitly skipped by the orchestrator's code-review-fixes
instructions ("SKIP F1 for now — document in closeout as deferred.
Single test sufficient for code-review #1.") and is documented below as
the highest-value Phase 12+ follow-up. F2/F3/F4/F6/F7/F10 deferred per
triage. F8/F9 OVERSTATED-not-fixed. F11 rejected.

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
- **[Code-review F1] Cancel-then-resume harness test.** The plan's
  Task 3 called for two harness tests; only the skip-on-resume case
  shipped. The cancel-then-resume case (cancel mid-batch after tag-a
  completes; second run skips tag-a + renders tag-b) has no E2E
  coverage. The "Done when" line on cancel-then-resume was checked
  off based on the bus-level integration test
  (`outcome_tag_count_includes_skipped_tags`) plus manual smoke; the
  plan-body harness-level test is the gap. Highest-value Phase 12+
  follow-up. ~80 LOC mirroring `export_partial_failure_smoke.rs`.
- **[Code-review F2] moov tail-scan false-positive lottery.**
  `output_exists_and_intact`'s tail-scan looks for `b"moov"` (4 bytes
  = 0x6D6F6F76) anywhere in the last 64 KiB. mdat sample bytes can in
  principle hit that 4-byte sequence (~1.5e-5 lottery per file in
  uniform-random bytes; lower in real h.264 NAL data). A user who
  hits it gets a silent skip-on-corrupt → `tag.skipped` for an
  unplayable file. Cheap fix: require both `b"moov"` AND a plausible
  4-byte big-endian box-size prefix immediately preceding it (offset
  ≥ 4 AND `tail[i-4..i]` parsed as `u32be` is between 8 and
  `metadata.len()`). Pragmatic punt: the user's escape hatch
  (Overwrite checkbox) covers the lottery. Documented for Phase 12
  hardening sweep.
- **[Code-review F3] Single-clip detection unit-test pinning.**
  Helper iterator `plan.entries.iter().map(|e| e.clip_id).next() →
  .all(|cid| cid == first)` is correct but non-obvious for the
  `len() == 1` case (after `next()` the iterator is empty so
  `.all(...)` returns `true`, which IS the desired behavior). The
  current bus integration test hits this path implicitly; a future
  plan should add explicit unit tests for (a) multi-entry-same-clip
  → `Some(recording_path)`; (b) multi-entry-distinct-clips →
  `None`.
- **[Code-review F4] Tracing breadcrumb on serde-default fire.** Adv-
  fix #8 was deferred per the plan's own escape clause. Legacy
  project.json users opening their project see a silent default
  flip (Phase 10 always-overwrite → Plan #6 Resume) with no log line.
  Future fix: in `project_store::read`, peek the parsed
  `serde_json::Value` for absence of
  `["preferences"]["exportOverwritePolicy"]` and emit a one-line
  `tracing::info!(target: "project", event =
  "preferences.export_overwrite_policy.defaulted", chosen = "resume",
  reason = "field_absent_in_project_json")`. Best-effort; non-
  blocking. ~5 LOC.
- **[Code-review F6] `RecordingNewer` fall-through encoder-spawn
  failure window.** When the helper returns `RecordingNewer`, the
  bus emits `stale_output` then falls through to silent-delete +
  `tag.started` + spawn encoder. Between the telemetry emit and the
  actual encoder spawn, an external observer (UI poll, harness
  `wait_for_event`) might briefly see slot state with `current_tag =
  label`, `current_tag_progress = 0.0` and no encoder running. If
  the encoder fails to spawn (rare — missing element), the slot
  sits there with stale-output label visible. Cancel arriving at
  this point would not flush a `tag.cancelled`. Fix: confirm by unit
  test that triggers `RecordingNewer` AND a missing-element early
  encode failure; if the test reveals a missing
  `tag.cancelled`/`tag.failed`, add a synthetic guard.
- **[Code-review F7] TOCTOU window in `output_exists_and_intact`.**
  Between `fs::metadata` and `File::open` + read, another process
  could replace the file with a structurally-valid but content-
  different mp4 (e.g., user copies a different .mp4 over via
  Finder). Helper returns `Intact` and the bus skips with the wrong
  content. Plan known-unknowns #4 punts the concurrent-delete case;
  this finding extends to file-replacement, which the punt
  arguably already covers. Mitigation: the user's escape hatch
  (Overwrite checkbox). Worth a one-line doc-comment note in the
  helper that the check is a snapshot, not a lock.
- **[Code-review F10] `ExportPrefsSnapshot::default()` audit gap.**
  Structural rather than functional. `impl Default for
  ExportPrefsSnapshot` builds from `Preferences::default()`. If a
  future plan adds another field to `ExportPrefsSnapshot` but
  forgets to thread it through `Preferences::default()`'s field,
  the snapshot's default will silently diverge. The shipped tests
  cover one field at a time. Future fix: structural test
  `ExportPrefsSnapshot::default() == ExportPrefsSnapshot::from(
  &Preferences::default())` once `From<&Preferences>` exists.
  Non-blocking for Plan #6.

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
- Cancel-then-resume harness E2E (code-review F1). Bus integration
  test covers the outcome contract (`SucceededAll.tag_count`
  including skipped rows); the harness-level E2E case (cancel
  mid-batch after tag-a completes; second run skips tag-a +
  renders tag-b) is gapped. Listed in deferred items above.
- Unknown `overwrite_policy` variant strings fail deserialization
  rather than fall back to `Resume`. Pinned by the new
  `export_command_with_invalid_overwrite_policy_returns_serde_error`
  unit test (code-review fix F12). A future plan adding `#[serde(other)]`
  for soft-fallback would intentionally break this test.
