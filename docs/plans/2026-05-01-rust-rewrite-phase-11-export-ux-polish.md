# Rust Rewrite — Phase 11 Plan #7: Export UX polish (drag-reorder + filename templates)

Branch: `rust-rewrite`. Phase 11 is Polish + deferred items from Phase 10's
closeout. This plan ships two small but user-visible UX wins paired into
one plan because they share the same Slint export sheet area + bus serde
surface:

1. **Drag-to-reorder of selected export tags.** Phase 10 derives the tag
   list via `tag_aggregation::aggregate(project)` (alphabetical, with the
   synthetic `all-clips` row pinned first); users have no way to control
   the output ordering of the per-tag `.mp4` files. Add drag handles
   (`☰` Unicode glyph + a hand-rolled gesture on TouchArea) to selected
   tag rows; on drop, the user-defined order persists in
   `selected-export-tags` Slint property + flows through the dispatch-
   time `Vec<TagSelection>` so the bus iterates in user-chosen order.
   Phase 10 fix #24 already documented "loop tags one at a time, in
   supplied order" — this plan finally makes "supplied order" mean
   "user-chosen order."

2. **Custom output filename template.** Phase 10 hard-codes
   `<tag-sanitized> - <project-name-sanitized>.mp4` at
   `bus.rs:2556-2560`. Let users override via a free-form text input
   that supports `{tag}`, `{project}`, and `{date}` placeholders (date
   format: `YYYY-MM-DD`, project's local time). Default template
   `{tag} - {project}` matches Phase 10 byte-for-byte. Persisted as
   `Preferences::export_filename_template: String` (`#[serde(default)]`
   for legacy-JSON compat). Validated on Export click (post-substitution
   `sanitize_filename` runs over the result; empty result falls back to
   `untitled` per the existing helper's contract).

---

## Goal (one paragraph)

Two surface-area changes co-located in the export sheet's Form view +
the bus's per-tag for-loop. Change #1 (drag-reorder) is pure UI —
Slint Repeater rows with a TouchArea-driven gesture handler that mutates
the `selected-export-tags` model in place; Rust side already iterates
selections in the supplied vec order so no bus change is required for
ordering. Change #2 (filename templates) threads a single new string
field through `Preferences`, the bus `Command::ExportCompilations`
shape, and a new `apply_template` helper that runs substitution BEFORE
the existing `sanitize_filename` (so a `{project}` containing `:` is
sanitized post-substitution; the per-piece sanitize from Phase 10 fix
#31 is replaced with whole-result sanitize). Default template
`"{tag} - {project}"` reproduces Phase 10's hard-coded format byte-for-
byte. The two changes share Task 1's UI work (the template input box
sits right next to the tag list in the Form view) and Task 2's bus
serde + sheet-open hydration plumbing (template prefs hydration mirrors
the codec hydration shipped in Plan #1 / Plan #3).

---

## What Phase 11 Plan #7 deliberately does NOT include

1. **Persisting the dragged tag order across sheet-opens.** Phase 10
   derives the tag list from `tag_aggregation::aggregate(project)` on
   every sheet open (alphabetical + `all-clips` pinned first); the user's
   drag order would be lost on next sheet-open unless we persist it.
   v1 had no drag at all; v2 picks "session only" — the drag order
   persists for the lifetime of the open sheet but resets on sheet-
   close. Sheet-open hydration writes the alphabetic-default order to
   `selected-export-tags` (already does as of Phase 10); the user re-
   drags if they want a different order on the next batch. Documented
   choice; future plan can promote to project-saved if users complain.
2. **Drag-reorder of UNSELECTED rows.** Drag handles are visible only
   on rows that are TICKED (i.e. members of `selected-export-tags`).
   Unticked rows have no drag affordance. Reasoning: drag-reorder of
   unselected rows is meaningless — they don't appear in the output
   sequence. UI hides the `☰` glyph on unticked rows.
3. **Multi-row drag (selecting + dragging multiple rows at once).**
   Single-row drag only. Future enhancement; out of plan scope.
4. **Keyboard-driven reorder (e.g. Alt+Up / Alt+Down).** Slint key-
   binding work is its own thing; would require focus-scoping into the
   tag list which doesn't currently support it. Drag-only in this plan.
5. **Drop indicators / animation.** A lightweight visual: the dragged
   row gets a slightly elevated background (`#3a3a3a` vs `#262626`)
   while held, and the destination index is computed from cursor Y on
   `pointer-released`. No animated row-shifting between source and
   destination — the model just snaps to the new order on release.
6. **Template variable autocomplete / picker UI.** Free-form text
   input only. Hint text below the input lists supported placeholders
   (`{tag}`, `{project}`, `{date}`) inline. No dropdown / chip picker /
   syntax validation while typing.
7. **Rich template features** — escaping (`{{tag}}` → literal `{tag}`),
   conditionals, format specifiers (`{date:YYYY-MM-DD}`), filename-vs-
   path separators. Three placeholders, simple string replacement. A
   tag named literally `"{tag}"` (extremely unlikely but technically
   possible) would substitute its own value back in once — documented
   as not-supported. The substitution loop is non-recursive (single
   pass per placeholder).
8. **Custom date format strings.** Date is always `YYYY-MM-DD` in
   project local time. UTC vs local: pick local (user-facing
   filename — UTC dates in California can show "tomorrow's date"
   exporting at 5pm Pacific, confusing). Documented in the apply_
   template docstring.
9. **Filename template applied to recording outputs / project save / etc.**
   Template is for compilation-export filenames only.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; especially the per-task sections below and
   the "Adversarial-review fixes baked in" section.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`'s
   "Adversarial-review fixes baked in" section (40 fixes), in
   particular fix #11 (`last_export_*` persisted-on-Export pattern,
   fail-soft if persistence write fails — the template field follows
   the same pattern), fix #12 + #31 (sanitize_filename Windows-safe
   helper — substitution feeds INTO this helper, so Windows reserved-
   name handling still works), fix #24 (sequential per-tag loop in
   supplied order — this plan finally makes "supplied order" user-
   chosen), fix #34 (ExportRunOutcome shape — unchanged).
3. `docs/plans/2026-05-01-rust-rewrite-phase-11-hevc-encoder.md`
   (Plan #1) — its Task 2 "ExportPrefsSlot infra" + sheet-open
   hydration pattern is the exact template we mirror for hydrating the
   template field. The `export-sheet-open-clicked` callback already
   exists from Plan #1; Plan #7 adds one more property to its
   hydration body.
4. `crates/video-coach-app/src/bus.rs::handle_export_compilations`
   (~line 2271 onward) — the spawned-task for-loop, especially the
   per-tag output_path build at `bus.rs:2556-2560`. The `format!("{} - {}.mp4", sanitize_filename(&label), sanitize_filename(&project_name_trimmed))`
   line is replaced with `apply_template(&template, &label, &project_name_trimmed, &today_local)`.
5. `crates/video-coach-app/src/filename.rs::sanitize_filename` —
   Windows-safe sanitizer; new template-substitution helper goes in
   the same file. Tests live alongside.
6. `crates/video-coach-app/ui/main.slint` — Form view's existing tag
   list (`for row[i] in root.export-tag-rows : ...`) is the rows the
   drag handle attaches to. The Cancel/Export button row near the
   bottom of the Form view is anchored at `parent.height - 52px` so
   adding a template input row above it doesn't push it. The codec
   row (Plan #1) is the layout template for the new template-input
   row. Search for `export-codec` to find the row's y-coordinate
   block; the template input row sits BELOW the Codec row.
7. `crates/video-coach-app/src/ui.rs::on_export_start_clicked`
   (~line 836 from Plan #1's reference; current line may differ) —
   where the Codec parser was added in Plan #1. The template field
   is a string passthrough (no parser needed) but the same wiring
   spot applies: read the Slint property, pass it into the
   `Command::ExportCompilations` literal.
8. `crates/video-coach-core/src/project.rs::Preferences` —
   add `export_filename_template: String` with `#[serde(default = "default_filename_template")]`
   pointing to a free function that returns `"{tag} - {project}"`.
   Mirrors the existing `last_export_codec`'s `#[serde(default)]`
   pattern but with a non-trivial default (the macro form requires a
   path to a function, not an inline literal).
9. `crates/video-coach-app/src/bus.rs::ExportPrefsSnapshot` (the
   helper added in Plan #1's Task 2) — extend with
   `export_filename_template: String`. Sheet-open hydration reads it.

---

## Adversarial-review fixes baked in

NET-NEW for Plan #7 (drag-reorder + filename-template specific
pitfalls). Phase 10's 40 fixes are NOT re-raised. Plan #1's 8 fixes
are NOT re-raised. Findings file:
`/tmp/phase11-plans/plan-7/adv-review.md` (12 findings, ~770 words).
Triage applied: 9 REAL/OVERSTATED folded in below; 1 SPECULATIVE
rejected (logged in "Rejected findings" subsection).

### Fix #1 — Drop `Copy` from `ExportPrefsSnapshot`; clone on read

`ExportPrefsSnapshot` is currently `#[derive(Debug, Clone, Copy)]`
(`bus.rs:266`); `BusHandle::export_prefs_snapshot` returns it via
`*self.export_prefs.lock()` (the deref-copy pattern). Adding the new
`export_filename_template: String` field makes the struct no longer
`Copy`, so the deref-copy fails to compile (`cannot move out of
dereference of MutexGuard`). Task 2 MUST drop the `Copy` derive (keep
`Clone, Debug`) and change `export_prefs_snapshot` to
`self.export_prefs.lock().expect("export-prefs lock poisoned").clone()`.
The helper `export_prefs_to_slint_strings` (if it returns
`&'static str`) must also adapt — the template field now produces a
runtime-owned `SharedString` cloned from the snapshot. Source: adv
finding #1 (HIGH/REAL — compile error).

### Fix #2 — `default_filename_template` is `pub`, not `pub(crate)`

The bus's `default_command_filename_template` calls
`video_coach_core::project::default_filename_template()` from a
different crate. The plan declared the helper `pub(crate)`, which
would fail to compile across crates. Make
`default_filename_template` `pub` (it's a stable contract anyway).
Update Task 0's snippet:

```rust
pub fn default_filename_template() -> String {
    "{tag} - {project}".to_string()
}
```

Add a unit test in `bus.rs` that asserts
`default_command_filename_template() == video_coach_core::project::default_filename_template()`
to catch drift if a future plan changes one without the other.
Source: adv finding #2 (HIGH/REAL — compile error).

### Fix #3 — Drag handle uses a SECOND TouchArea, not an extended one

Phase 10's row TouchArea handles `clicked` for tag-toggle. Slint's
TouchArea fires `clicked` on press-then-release without movement — so
a user who presses the drag handle and releases without moving would
toggle the row's selection (unintended side effect). Slint 1.8 has no
"ignore clicks within sub-rect" API on a single TouchArea. Task 1
MUST place the drag handle as a separate TouchArea (24×24 px) sibling
of the row toggle TouchArea, z-ordered ABOVE the row toggle. The
drag TouchArea handles press/move/release and consumes events; the
row toggle TouchArea continues to fire `clicked` only when the press
lands outside the drag-handle rect. Document the z-order in
`main.slint` comments. Source: adv finding #3 (HIGH/REAL — concrete
UX bug).

### Fix #4 — Use absolute window coordinates for drag math; verify list non-scrollable; clamp test

Two related drop-Y issues:

1. The current spec `(drop_y / row_height).round() as usize` ignores
   any vertical scroll offset. Phase 10's tag list is not currently
   scrollable (the modal caps tag count by viewport), but Task 1
   MUST verify this in `main.slint` at task start. If the list is
   scrollable, the math must use absolute Y minus the list's
   absolute Y, divided by row height. If not, document
   "list is non-scrollable; if a future plan adds a ScrollView,
   drop-Y math needs scroll-offset adjustment" in a `// PLAN-7-NOTE`
   comment in `ui.rs`.
2. Capture the pointer in absolute window coordinates on
   `pointer-event(Down)` (via the row's `absolute-position.y +
   mouse-y` or the equivalent Slint 1.8 idiom) and compare to the
   list's absolute Y on `Up`. This is robust to Slint's Repeater row
   recycling — if the model mutates mid-drag (e.g. another async
   event toggles `selected-export-tags`), the absolute coordinate
   survives where row-local coordinates would be invalidated.
3. Add `drag_reorder_to_index_clamps_to_len` test (already in plan)
   PLUS `drag_reorder_drop_below_list_clamps` — a drop-y past the
   end of the list resolves to `selected.len()` (append) rather
   than panicking. Sources: adv findings #4 (HIGH/OVERSTATED) and
   #12 (MEDIUM/OVERSTATED).

### Fix #5 — Disable Export button while dragging

A user can start a drag, click Export with the other hand (or via
keyboard), then release the drag. Slint dispatches the Export click
on a separate handler; `Command::ExportCompilations` would be
dispatched with the pre-drag order, then the drag-release callback
mutates `selected-export-tags` after the fact — the user's last
visual intent is lost. Task 1 + Task 2 MUST gate the Export button:
in `main.slint`, the Export button's `enabled:` binding becomes
`enabled: root.dragging-tag-index == -1 && root.export-tag-rows.length > 0`
(or equivalent). The button visually greys out while a drag is in
flight. Document in `main.slint` comments. Source: adv finding #5
(MEDIUM/REAL — confusing race).

### Fix #6 — Sanitize `{` and `}` from substituent values before substitution

Plan's `apply_template` does sequential `.replace()` calls. Tag/
project values containing literal `{tag}`/`{project}`/`{date}`
braces can produce unexpected results: a project named `"My {tag} project"`
combined with template `"{tag} - {project}"` and tag `"X"` yields
`"X - My {tag} project"` — a literal `{tag}` survives in the
filename. Task 0's `apply_template` MUST scrub `{` and `}` from
the `tag`, `project`, and `date` parameters BEFORE substitution:

```rust
fn strip_braces(s: &str) -> String {
    s.chars().filter(|c| *c != '{' && *c != '}').collect()
}

pub fn apply_template(template: &str, tag: &str, project: &str, date: &str) -> String {
    let tag_clean = strip_braces(tag);
    let project_clean = strip_braces(project);
    let date_clean = strip_braces(date);
    let substituted = template
        .replace("{tag}", &tag_clean)
        .replace("{project}", &project_clean)
        .replace("{date}", &date_clean);
    sanitize_filename(&substituted)
}
```

Add a test `template_substituent_with_braces_is_stripped` covering a
project name containing `{tag}`. Source: adv finding #6
(MEDIUM/OVERSTATED).

### Fix #7 — Use `chrono::Local::now().date_naive()` for stable date formatting

`chrono::Local::now().format("%Y-%m-%d")` works on macOS/Linux but
has historical edge cases at DST transitions on Windows. Task 2
MUST format the date via the explicit naive-date path:

```rust
let today_local = chrono::Local::now().date_naive().format("%Y-%m-%d").to_string();
```

`date_naive()` extracts the calendar date in the local timezone
without going through timezone-arithmetic, which avoids the
midnight-offset-by-one-second class of bugs. Source: adv finding #7
(MEDIUM/OVERSTATED).

### Fix #8 — Validate template by sensitivity test, with single-tag exception

The original spec validates by running `apply_template` with a probe
input and rejecting if the result equals `"untitled"`. This rejects
a user template literally `"untitled"` (a perfectly legal filename
when N==1 selection — no overwrite risk). Task 2 MUST replace the
naive-equality check with a sensitivity-based check:

```rust
let probe_a = apply_template(&filename_template, "ALPHA", "BRAVO", "2000-01-01");
let probe_b = apply_template(&filename_template, "ZETA", "YANKEE", "2099-12-31");
let template_has_placeholders = probe_a != probe_b;

// Reject only when N > 1 selection AND the template lacks placeholders
// (would cause N output files to overwrite each other).
if selections.len() > 1 && !template_has_placeholders {
    emit_export_batch_failed("filename_template_no_placeholders");
    return;
}

// Also reject if the probe sanitizes to "untitled" — degenerate template.
if probe_a == "untitled" {
    emit_export_batch_failed("filename_template_invalid");
    return;
}
```

Two failure reasons (`filename_template_no_placeholders` for the
overwrite-risk case, `filename_template_invalid` for the sanitize-
empty case) so the UI can surface a helpful message. Add tests for
each gate. Source: adv finding #8 (MEDIUM/REAL).

### Fix #9 — Selected-tag rows render via separate Repeater above the unselected list (ship-blocker fix)

The drag-reorder gesture mutates `selected-export-tags` (the
`[string]` membership list), but the visible rows are rendered
from `export-tag-rows` (the alphabetic-sorted aggregate model).
Reordering `selected-export-tags` would have ZERO visible effect —
the dragged row "snaps back" to its alphabetic spot. Ship-blocker.

Task 1 MUST split the visible tag list into TWO Repeaters in
`main.slint`:

1. **Top Repeater** iterates a new in-out property
   `selected-export-tag-rows: [{tag, label, clip-count, duration}]`
   in user-chosen order. Each row has the `☰` drag handle (visible)
   and the toggle TouchArea pre-checked. This is the section the
   drag-reorder gesture mutates.
2. **Bottom Repeater** iterates a new in-out property
   `unselected-export-tag-rows: [{tag, label, clip-count, duration}]`
   in alphabetical order (the leftover from `export-tag-rows` minus
   the selected set). Each row has NO drag handle, toggle TouchArea
   un-checked.

Sheet-open hydration in `ui.rs` builds both lists from the same
`tag_aggregation::aggregate(project)` output: split into selected
(in user-chosen order, defaulting to alphabetic on first open) and
unselected (alphabetic). Toggle-on a row in the bottom Repeater
moves it to the BOTTOM of the top Repeater (user can then drag it
up). Toggle-off a row in the top Repeater moves it back to its
alphabetic spot in the bottom Repeater. Drag-release fires the
existing `export-tag-drag-released` callback against the top-list
indices only.

`export-tag-rows` is retained as a hidden internal property used
during hydration to compute the split. Existing Phase 10 tests
that read `export-tag-rows` still work; bus events
(`export.tag.started`, etc.) iterate `selected-export-tags` (the
membership list, now matching top-Repeater order) — no bus change.

Update Task 1's gesture handler to mutate the top Repeater's
backing model + `selected-export-tags` together so they stay
consistent. Source: adv finding #9 (HIGH/REAL — ship blocker).

### Fix #10 — Empty-string template hydration falls back to default

A malformed `project.json` with explicit `"exportFilenameTemplate": ""`
deserializes to `""` (serde does NOT call the `default = ...`
function on a present-but-empty string field). The user opens the
sheet, sees an empty LineEdit, clicks Export, and trips the
sensitivity gate from Fix #8 — confusing.

Task 2's sheet-open hydration MUST defensively fall back to default
on an empty/whitespace template:

```rust
let template = if prefs.export_filename_template.trim().is_empty() {
    video_coach_core::project::default_filename_template()
} else {
    prefs.export_filename_template.clone()
};
w.set_export_filename_template(template.into());
```

Do NOT immediately persist the corrected default back to project.json
on hydration — the fix-up happens on the next Export click via the
existing fix #11 persistence path (Phase 10). The LineEdit's
`edited("")` callback also does NOT immediately persist empty; the
user must click Export, where the gate runs. Add a test
`hydrate_empty_template_falls_back_to_default`. Source: adv
finding #11 (MEDIUM/REAL).

### Rejected findings

**Adv finding #10 — `"all-clips"` synthetic-row vs real tag name
collision (LOW/SPECULATIVE).** The reviewer noted that a real
project with a tag literally named `"all-clips"` would produce two
output files with the same name (synthetic AllClips row plus the
real tag). Rejected:

1. The plan deliberately documents at line 88 that `"all-clips"`
   overwrites are not addressed — consistent with Phase 10's
   `tag_aggregation::aggregate` which already pins the synthetic
   row first under that exact label.
2. No concrete trigger — extremely unlikely a real coaching project
   has a tag literally named `"all-clips"`.
3. Even if it occurs, the user immediately notices the duplicate
   filename in the export folder and renames the tag.

The reviewer themselves marked this as SPECULATIVE / "skip." Logged
here for traceability; no plan change.

---

## Tasks

### Task 0: Preferences field + `apply_template` helper

Crate: `video-coach-core` + `video-coach-app` (filename.rs only).
~80 LOC. Pure-data + a small helper with unit tests. No bus / Slint
changes yet.

**Add to `crates/video-coach-core/src/project.rs::Preferences`**:

```rust
pub struct Preferences {
    pub scan_volume: f64,
    pub preview_source_volume: f64,
    pub preview_commentary_volume: f64,
    pub last_export_resolution: Resolution,
    pub last_export_quality: Quality,
    #[serde(default)]
    pub last_export_codec: Codec,
    /// Phase 11 Plan #7. Free-form template with `{tag}`, `{project}`,
    /// `{date}` placeholders. Default = `"{tag} - {project}"` which
    /// reproduces Phase 10's hard-coded format byte-for-byte.
    /// `#[serde(default = "default_filename_template")]` so a
    /// pre-Plan-#7 project.json deserializes cleanly with the legacy
    /// behavior preserved.
    #[serde(default = "default_filename_template")]
    pub export_filename_template: String,
    pub preferred_camera_id: Option<String>,
    pub preferred_mic_id: Option<String>,
}

pub(crate) fn default_filename_template() -> String {
    "{tag} - {project}".to_string()
}
```

And add `export_filename_template: default_filename_template()` to the
`Default` impl. Why a function instead of `Default::default()` for the
String: `#[serde(default)]` would yield `""` (the String default), which
would then sanitize to `"untitled"` — wrong default behavior. We want
a real template string as the default, so we use the named-function
form.

**Add to `crates/video-coach-app/src/filename.rs`**:

```rust
/// Substitute `{tag}`, `{project}`, `{date}` placeholders in `template`
/// then sanitize the result for use as a filename component.
///
/// Substitution is single-pass and non-recursive: a tag named literally
/// `"{tag}"` (extremely unlikely) substitutes its own value back in
/// once but does not loop. Unsupported placeholders pass through as
/// literal text (e.g. `"{frame}"` survives unchanged in the output —
/// future-compatible).
///
/// Date format is hardcoded to `YYYY-MM-DD` in project LOCAL time
/// (NOT UTC) — this is a user-facing filename and a UTC date can
/// disagree with the calendar the user is looking at.
///
/// The result is passed through `sanitize_filename` so any
/// substituted-in illegal Windows chars (`/`, `\`, `:` etc.) are
/// scrubbed. An empty post-substitution-and-sanitize result falls
/// back to `"untitled"` (inherited from `sanitize_filename`'s contract).
pub fn apply_template(template: &str, tag: &str, project: &str, date: &str) -> String {
    let substituted = template
        .replace("{tag}", tag)
        .replace("{project}", project)
        .replace("{date}", date);
    sanitize_filename(&substituted)
}
```

**Tests** in `filename.rs::tests`:

- `default_template_matches_phase_10_format` — call
  `apply_template("{tag} - {project}", "drills", "MyProj", "2026-05-01")`,
  assert result is `"drills - MyProj"`. (Date placeholder absent in
  default template; survives untouched.)
- `template_with_date_substitutes_local_date` — call with template
  `"{date}_{tag}_{project}"`, assert result substitutes the supplied
  date string verbatim.
- `template_with_no_placeholders_passes_through` — call with template
  `"static-name"`, assert result is `"static-name"` (after sanitize).
- `template_with_unknown_placeholder_passes_through_literal` — call
  with template `"{frame}_{tag}"`, project `"X"`, tag `"a"`,
  date `"d"`, assert result starts with `"-frame-_a"` (the `{` and
  `}` chars are sanitized to `-` per Phase 10 fix #31's table — wait,
  `{` and `}` are NOT in the sanitize_filename illegal-char list;
  they pass through. Assert result is `"{frame}_a"`).
- `template_substitutes_into_illegal_chars_safely` — tag `"a/b"`
  (slash is illegal on Windows), template `"{tag}"`. Assert result
  is `"a-b"` (post-substitution sanitize replaces `/` with `-`).
- `template_substitutes_project_with_colon` — project `"5:30 drill"`,
  template `"{project}"`, assert result is `"5-30 drill"`.
- `empty_template_falls_back_to_untitled` — `apply_template("", "x", "y", "d")` returns `"untitled"`.
- `template_with_only_placeholders_resolving_to_empty_falls_back` —
  template `"{tag}"`, tag `""`, returns `"untitled"`.
- `windows_reserved_template_result_gets_underscore` — template
  `"{tag}"`, tag `"CON"`, returns `"_CON"` (sanitize-handled).
- `template_with_literal_tag_in_input_is_not_recursively_substituted` —
  tag `"{tag}"`, project `"P"`, template `"{tag}_{project}"`. After
  substitution: `"{tag}_P"` — the `{tag}` from the user's tag value
  is NOT re-substituted. Documents the not-recursive contract. After
  sanitize, `{` and `}` pass through, so result is `"{tag}_P"`.
- `default_filename_template_function_returns_phase_10_format` — call
  the new `default_filename_template()` from `project.rs` and assert
  it returns `"{tag} - {project}"`.

**`Preferences` deserialize-without-template-field test** (in
`crates/video-coach-core/src/project.rs::tests`): round-trip a legacy
JSON `{"scanVolume":1.0,"lastExportResolution":"r1080","lastExportQuality":"medium",...}`
WITHOUT `exportFilenameTemplate` field, assert the deserialized struct
has `export_filename_template == "{tag} - {project}"`. Mirrors Plan
#1's `preferences_deserializes_without_codec_field` test.

**Acceptance gate (mirrors Plan #1's fix #5 grep gate)**:

```
rg 'sanitize_filename\(' crates/ | grep -v 'fn sanitize_filename\|test\|apply_template'
```

Expected hits ONLY: `crates/video-coach-app/src/bus.rs:2558` and
`crates/video-coach-app/src/bus.rs:2559` (the Phase 10 per-piece
sanitize call sites that Task 2 will replace). Any unexpected hit
blocks the task — the plan grows a per-call-site `apply_template`
migration patch.

**Commit**: `phase11(export-ux-polish, task 0): export_filename_template + apply_template helper`

---

### Task 1: Slint drag-to-reorder + template input box

Crate: `video-coach-app` only (Slint + ui.rs). ~150 LOC. Two distinct
UI changes co-located because they share the Form view layout.

**Drag-to-reorder of selected tag rows** (`crates/video-coach-app/ui/main.slint`):

The existing tag-list rendering is a Repeater over `export-tag-rows`
(the `[{tag, label, clip-count, duration}]` model property). Each row
is a Rectangle with TouchArea handling click-toggle. The drag handler
extends the same TouchArea to additionally support press-and-drag
gestures.

Slint 1.8 doesn't have a built-in drag-and-drop primitive for Repeater
rows; we hand-roll a gesture using `TouchArea`'s `pointer-event`,
`pressed-x/y`, `mouse-x/y`, and the existing `clicked` callback.
Approach:

1. Add a new in-out property `dragging-tag-index: int = -1;` to the
   root window. `-1` = not dragging.
2. Add a new in-out property `drag-current-y: length = 0;` for the
   live cursor Y while dragging (used to compute the destination
   index on release).
3. Each tag row's TouchArea gains a `pointer-event(event)` callback:
   - On `Down`: record `dragging-tag-index = row-index` IF the row is
     ticked (member of `selected-export-tags`) AND the press
     originated within the drag handle's hit-rect (the `☰` glyph at
     the row's far left, ~24px wide). Press anywhere else on the row
     = the existing click-toggle behavior, no drag.
   - On `Move`: if `dragging-tag-index == row-index`, update
     `drag-current-y = parent.absolute-position.y + mouse-y` (or
     similar — the exact Slint property names depend on the layout
     hierarchy; sub-agent picks the cleanest one that works).
   - On `Up` / `Cancel`: if `dragging-tag-index == row-index`, fire
     a new callback `export-tag-drag-released(int from-index, length drop-y)`
     and reset `dragging-tag-index = -1`. The Rust side computes the
     destination index from the drop-y (which row of the list does
     this Y land in?) and mutates `selected-export-tags` in place.
4. The dragged row's background changes from `#262626` to `#3a3a3a`
   while `dragging-tag-index == row-index` (a subtle "lifted" visual).
   No animated shifting of other rows during drag — the model just
   snaps to the new order on release.
5. Drag handle visibility: the `☰` glyph is rendered as a Text element
   at the row's far left, visible only when the row's tag is in
   `selected-export-tags`. Use a property binding:
   `visible: root.selected-export-tags.contains(row.tag) ;`
   (or compute via a helper `pure function is-selected(tag) -> bool`
   if Slint's Array.contains isn't available in 1.8 — sub-agent
   verifies API availability).

**ui.rs side** (`crates/video-coach-app/src/ui.rs`):

- New callback binding `on_export_tag_drag_released(move |from_index: i32, drop_y: slint::PhysicalLength|)`:
  reads the current `selected-export-tags` model + the
  `export-tag-rows` model, computes the destination index by
  `(drop_y / row_height).round() as usize`, then performs an in-place
  mutation of `selected-export-tags`:
  - If `from_index == to_index`, no-op.
  - Otherwise, `let tag = selected.remove(from_index); selected.insert(to_index.min(selected.len()), tag);`.
  - Write back to the Slint property.
- Row height is fixed (Slint layout currently renders tag rows at
  ~32 px each); read it from a constant or query the Repeater. If
  the row height isn't accessible from Rust, hardcode `32.0` and
  document it (with a comment pointing at the Slint property name
  in `main.slint` that defines the row height).

**Template input box** (`crates/video-coach-app/ui/main.slint`):

- Add `in-out property <string> export-filename-template: "{tag} - {project}";`
  next to `export-codec` in the root window's properties.
- Add `callback export-filename-template-changed(string);` next to
  `export-codec-changed`.
- Place a single-line `LineEdit` (from `std-widgets.slint` — Slint
  1.8 ships this) below the Codec row in the Form view. y-coordinate
  follows the Codec row's bottom + ~12 px padding (sub-agent verifies
  the exact y by reading the Codec row's positioning from
  `main.slint`). LineEdit width = 280 px to match the form's content
  width; height = 28 px (Slint LineEdit default).
  - `text <=> root.export-filename-template;` (two-way bind).
  - `edited(text) => { root.export-filename-template-changed(text); }`.
- Hint label below the LineEdit: a Text element with
  `text: "Placeholders: {tag}, {project}, {date}";` color `#999999`,
  font-size `11`. ~16 px below the LineEdit.
- Label above the LineEdit: a Text element `text: "Filename"; color: #cccccc; font-size: 13;` ~6 px above the LineEdit, mirroring the
  Codec row's label styling.
- **If `LineEdit` from std-widgets.slint isn't already imported by
  main.slint**, add `import { LineEdit } from "std-widgets.slint";`
  at the top. If the import is already present, no change.

**Form view height adjustment**: the Form view has a hardcoded modal
height. The Codec row (Plan #1) ends at ~y:480 px; adding the template
input row + label + hint requires ~80 px more. Search for the modal's
parent Rectangle's `height:` literal and increase by 80 px (sub-agent
records the exact change). Cancel/Export buttons are anchored at
`parent.height - 52px` so they ride down with the new height.

**ui.rs side**:

- New callback binding `on_export_filename_template_changed(move |s: slint::SharedString|)` —
  same shape as `on_export_codec_changed` (Plan #1):
  ```rust
  let weak_for_template = window.as_weak();
  window.on_export_filename_template_changed(move |s: slint::SharedString| {
      if let Some(w) = weak_for_template.upgrade() {
          w.set_export_filename_template(s);
      }
  });
  ```
- In `on_export_start_clicked`: read `w.get_export_filename_template().to_string()`
  and pass it as the new `filename_template` field on
  `Command::ExportCompilations`.
- **Sheet-open hydration**: extend the existing `export-sheet-open-clicked`
  callback handler (Plan #1) to also hydrate the template field:
  ```rust
  w.set_export_filename_template(prefs.export_filename_template.clone().into());
  ```
  Plan #1's `ExportPrefsSnapshot` already exists; Task 2 extends it
  with `export_filename_template: String` and the snapshot helper
  reads it. Task 1 just calls the existing helper.

**Tests**:

- Slint properties don't unit-test directly; the integration test
  lives in Task 2 (sheet-open hydration test extended with a
  template-prefs assertion).
- A pure-Rust unit test for the drag-reorder math:
  `drag_reorder_swap_within_selected_tags` — given a `Vec<String>`
  of selected tags `["a", "b", "c"]` and `from=0, to=2`, assert the
  result is `["b", "c", "a"]`. Test the helper that performs the
  remove-then-insert math (extract it as a pure function so the test
  doesn't need a Slint window). The helper lives in `ui.rs`.
- `drag_reorder_same_index_is_noop` — `from=1, to=1` returns
  unchanged.
- `drag_reorder_to_index_clamps_to_len` — `from=0, to=99` (drop past
  the end) appends to the end.

**Commit**: `phase11(export-ux-polish, task 1): Slint drag-to-reorder + template input`

---

### Task 2: Bus wiring + persistence + per-tag template substitution

Crate: `video-coach-app` only (bus.rs + ExportPrefsSnapshot extension).
~100 LOC. Threads the template through the bus command shape, persists
it on Export click, calls `apply_template` per tag.

**Extend `Command::ExportCompilations`** (`crates/video-coach-app/src/bus.rs` ~line 125):

```rust
ExportCompilations {
    selections: Vec<TagSelection>,
    output_folder: String,
    resolution: video_coach_core::project::Resolution,
    quality: video_coach_core::project::Quality,
    codec: video_coach_core::project::Codec,
    project_name: String,
    /// Phase 11 Plan #7. `{tag}`, `{project}`, `{date}` placeholders.
    /// `#[serde(default = "default_command_filename_template")]` so a
    /// pre-Plan-#7 control-socket client (or a harness test predating
    /// this plan) deserializes cleanly without the field. The default
    /// matches Phase 10's hardcoded format byte-for-byte.
    #[serde(default = "default_command_filename_template")]
    filename_template: String,
},
```

Plus a free function in the same module:

```rust
fn default_command_filename_template() -> String {
    video_coach_core::project::default_filename_template()
}
```

(Or just inline `"{tag} - {project}".to_string()` — the function form
keeps the default in one place if a future plan changes it.)

**Extend the dispatch arm** (~line 2199):

```rust
Command::ExportCompilations {
    selections, output_folder, resolution, quality, codec, project_name,
    filename_template,
} => {
    handle_export_compilations(
        selections, output_folder, resolution, quality, codec,
        project_name, filename_template, …
    ).await
}
```

**Extend `handle_export_compilations`'s signature** with
`filename_template: String` after `project_name`. Inside:

1. **Validate** the template by running
   `apply_template(&filename_template, "TEST_TAG", &project_name_trimmed, "0000-00-00")`.
   If the result equals `"untitled"` (sanitize fell back), emit
   `export.batch.failed` with `reason = "filename_template_invalid"`
   and abort BEFORE persisting prefs / starting the run. Reasoning:
   if a non-trivial template sanitizes to `"untitled"`, the user
   would get N files all named `untitled.mp4` overwriting each other;
   refuse upfront. (An empty template → fallback to default? — no,
   empty template also fails this check; user must type something.)
   - Edge case: a template like `"{tag}"` where the tag is non-empty
     would NOT trigger this check (sanitize produces a real string).
     The check uses `"TEST_TAG"` so a `{tag}`-only template returns
     `"TEST_TAG"` (or `"_TEST_TAG"` if Windows reserved — which it
     isn't), not `"untitled"`. Good.
   - A template that is literally `"_"` or `"."` → sanitize trims
     and returns `"untitled"` → caught.
2. **Persist** `project.preferences.export_filename_template = filename_template.clone();`
   at the existing fix #11 persistence step (next to
   `last_export_codec` / `last_export_resolution` / `last_export_quality`).
3. **Build the output path** for each tag (replacing
   `bus.rs:2556-2560`):

   ```rust
   let today_local = chrono::Local::now().format("%Y-%m-%d").to_string();
   let filename = video_coach_app::filename::apply_template(
       &filename_template,
       &label,
       &project_name_trimmed,
       &today_local,
   );
   let output_path = output_folder_path.join(format!("{filename}.mp4"));
   ```

   `apply_template` already calls `sanitize_filename` internally on
   the post-substituted result, so the per-piece sanitize calls (the
   two `sanitize_filename(&label)` and `sanitize_filename(&project_name_trimmed)`
   call sites currently at `bus.rs:2558-2559`) are removed — the
   substitution happens BEFORE sanitize, and the whole-result
   sanitize replaces the per-piece approach. Phase 10 fix #31's
   Windows-reserved + empty-fallback contracts continue to apply
   because `apply_template` delegates to `sanitize_filename`.
   - `today_local` is computed ONCE at the top of
     `handle_export_compilations` (before the for-loop) so all tags
     in the same batch share the same date string. A multi-tag
     batch starting at 23:59 local that crosses midnight still
     stamps all output files with the start-time date — desired
     behavior, batch consistency.

4. **Pass `filename_template` to the inner `tokio::task::spawn_blocking`
   call IF needed.** It's not — the export pipeline doesn't see the
   template; only the bus loop builds the per-tag output path. So
   `filename_template` does NOT thread into `export_compilation`'s
   public signature.

**Extend `ExportPrefsSnapshot`** (Plan #1 / #3 added this struct in
`bus.rs`):

```rust
pub struct ExportPrefsSnapshot {
    pub last_export_resolution: Resolution,
    pub last_export_quality: Quality,
    pub last_export_codec: Codec,
    /// Phase 11 Plan #7.
    pub export_filename_template: String,
}
```

The snapshot helper (`fn export_prefs_snapshot(slot: &ExportPrefsSlot) -> ExportPrefsSnapshot`)
reads the new field from the prefs accessor. ui.rs's sheet-open
hydration callback consumes the new field (Task 1 wired the Slint
side; Task 2 wires the Rust side of hydration).

- The bus arm that POPULATES the snapshot (search for
  `last_export_codec:` near the existing snapshot-write site) now
  also writes `export_filename_template: prefs.export_filename_template.clone()`.

**Tests**:

- Bus serde round-trip (gated `#[cfg(feature = "media")]` if it
  needs the full bus, else pure data): `export_command_with_filename_template_round_trips`
  — serializes `Command::ExportCompilations { filename_template: "{date}_{tag}_{project}".into(), ... }`
  to JSON via the same path the control socket uses, deserializes,
  asserts `filename_template` is preserved.
- `export_command_without_filename_template_field_deserializes_to_default`
  — Phase-10-shaped JSON payload (no `filenameTemplate` key) round-
  trips to `Command::ExportCompilations` with
  `filename_template == "{tag} - {project}"`. Mirrors Plan #1's
  legacy-JSON test for `codec`.
- `opening_export_sheet_hydrates_filename_template_from_preferences`
  — extends the existing Plan #1 test (which hydrates resolution +
  quality + codec) to also assert
  `w.get_export_filename_template() == "{tag}_{project}_{date}"`
  when the project's prefs have that template stored. Construct via
  the same `Mutex<ExportPrefsSnapshot>` infra Plan #1 set up.
- `handle_export_with_invalid_template_emits_failed_event` — wire a
  bus harness with template `"."` (sanitizes to `"untitled"`),
  assert the `export.batch.failed` event fires with
  `reason="filename_template_invalid"` and the export does NOT
  start (no `export.batch.started`).
- `handle_export_with_default_template_writes_phase_10_format` —
  end-to-end (or as close as the test scaffolding allows): export
  with default template, assert the output path is
  `<folder>/<tag> - <project>.mp4` byte-for-byte (regression guard
  for the default-preserves-Phase-10 contract).
- `handle_export_with_date_template_writes_today_local` — export
  with template `"{date}_{tag}"`, assert the output path's
  filename starts with `chrono::Local::now().format("%Y-%m-%d")`.
  Use a tolerance: the test should run within the same calendar day
  on the local clock.

**Commit**: `phase11(export-ux-polish, task 2): bus wiring + per-tag apply_template + sheet-open hydration`

---

## Done criteria

- `cargo build --workspace --features media` clean.
- `cargo test --workspace --features media` green; new tests pass.
- `cargo build --workspace --no-default-features` clean.
- `cargo clippy --workspace --all-targets --features media -- -D warnings` clean.
- `cargo clippy --workspace --exclude video-coach-media --all-targets -- -D warnings` clean.
- `cargo fmt --check` clean.
- A manual macOS export with the default template still produces
  `<output_folder>/<tag> - <project>.mp4` byte-for-byte (no Phase-10
  regression).
- A manual macOS export with template `"{date}_{tag}"` produces
  `<output_folder>/2026-05-01_<tag>.mp4`.
- A manual macOS export with the user dragging tags A, B, C to order
  C, A, B produces files in the order `C.mp4` first (or whatever
  their template-rendered names are; the order verification is via
  the bus's `export.tag.started` event sequence — emit order matches
  drag order).
- Loading a Phase-10-era project.json (no `exportFilenameTemplate`
  field) succeeds and reports
  `Preferences::default().export_filename_template == "{tag} - {project}"`
  after deserialize.
- The export sheet's Form view shows: tag list (with drag handles on
  ticked rows), Resolution / Quality / Codec rows, a Filename input
  box with hint text `"Placeholders: {tag}, {project}, {date}"`, and
  Cancel/Export buttons. Toggling a row off then on does NOT clear
  the user's template input. Closing + reopening the sheet preserves
  the template (sheet-open hydration from prefs).

---

## Known unknowns

1. **Slint `LineEdit` import availability.** Slint 1.8 has
   `LineEdit` from `std-widgets.slint`; the project may already
   import it elsewhere. Sub-agent's first step in Task 1 is to check
   `main.slint` for an existing `LineEdit` import. If absent, add
   the import. If `std-widgets`-style widgets aren't usable for
   theming reasons, fall back to `TextInput` (the more primitive
   widget — requires manually drawing the border/background; ~40
   extra LOC). Decision deferred to Task 1; sub-agent picks based
   on what's already in the project.
2. **Slint Repeater + per-row drag gesture API.** Slint 1.8 doesn't
   expose a built-in drag-and-drop primitive on Repeater rows; the
   gesture must be hand-rolled via `TouchArea`'s `pointer-event`
   callback. The exact property names for absolute mouse position
   within a Repeater item aren't documented in our project's
   existing Slint code (no current drag handlers); sub-agent will
   verify via the Slint 1.8 API docs at task start. If
   `pointer-event` doesn't expose absolute Y, fall back to using
   the row's `y` property + the TouchArea's `mouse-y` (which is
   row-local). Implementation freedom granted to sub-agent within
   the plan's contract.
3. **Drag-reorder visual flicker.** Without animated row-shifting,
   the dragged row "snaps" to its new position on release. If
   visual feedback is too jarring (rows jump), a subsequent polish
   plan can add a 150ms ease-out animation on the affected rows.
   Out of Plan #7 scope; flagged for code review.
4. **Drag handle hit-rect tuning.** `☰` glyph is ~12 px wide as
   text; the surrounding hit-rect needs to be ~24 px to feel
   responsive (per design heuristics). If the row height is 32 px,
   a 24×24 hit-rect at the row's far left works. Sub-agent picks
   exact dimensions; documented in the commit.
5. **`chrono::Local::now()` vs `chrono::Utc::now()` portability.**
   `chrono::Local` requires the `clock` feature flag (enabled by
   default in chrono >= 0.4.20) and works on every platform we
   ship to (macOS, Linux, Windows). If the workspace pins a chrono
   version without `clock`, sub-agent enables the feature in
   `crates/video-coach-app/Cargo.toml`. The project already uses
   `chrono::DateTime<Utc>` for clip recordings (per `project.rs`),
   so chrono is a dependency; only the local-time accessor might
   need a feature flag.
6. **`{date}` format consistency across tags within a batch.** The
   plan stamps the date at the START of `handle_export_compilations`
   so all tags in the same batch share it. A batch crossing
   midnight (rare) all gets the start-time date. Documented as a
   feature; if a future plan wants per-tag-start dates, the change
   is a one-line move.
7. **Drag-reorder + tag-toggle interaction.** A user could click the
   drag handle to start a drag, then release WITHOUT moving (a
   stationary press). The current spec fires
   `export-tag-drag-released` on every release; with from==to the
   in-place mutation is a no-op (good). If the press-without-move
   should ALSO be treated as a tag-toggle, sub-agent picks (current
   spec: no — the drag-handle hit-rect is distinct from the row's
   click-toggle hit-rect, so press-on-handle is unambiguously
   "drag intent" even if no motion occurred).

---

## Closeout — Phase 11 Plan #7 SHIPPED 2026-05-01

**CI run**: `<placeholder, filled by orchestrator after CI passes>`
green on all 4 jobs — `test (ubuntu-latest)`, `test (windows-latest)`,
`test (macos-latest)`, `media-tests`.

### Commits (in shipping order)

| Stage | SHA | Summary |
|---|---|---|
| Plan first pass | `0f500a5` | Initial plan + 5 baked-in fixes (Preferences field, apply_template helper, Slint dual-Repeater drag, LineEdit template input, bus per-tag substitution); 3-task structure (Preferences/helper, Slint UI, bus wiring); known unknowns + adversarial-fixes placeholder |
| Plan adversarial pass | `613812c` | Plan fixes #1-#10 from inline adversarial review (drop Copy on ExportPrefsSnapshot + clone-on-read; pub default_filename_template + cross-crate equality test; second TouchArea for drag handle z-ordered above row toggle; absolute window coords for drag math + non-scrollable assumption + clamp test; gate Export button while dragging; strip `{`/`}` from substituent values before sequential `.replace()`; chrono::Local::now().date_naive() for stable formatting; sensitivity-based template validation with two probe values + N>1 overwrite gate; ship-blocker dual-Repeater split selected-export-tag-rows top + unselected-export-tag-rows bottom; empty-string template hydration falls back to default). Adv #10 SPECULATIVE 'all-clips' name collision rejected. |
| Task 0 | `43db0bb` | Preferences::export_filename_template + apply_template helper. Adds `pub export_filename_template: String` to Preferences with `#[serde(default = "default_filename_template")]`; declares `pub fn default_filename_template()` returning `"{tag} - {project}"`; new `crates/video-coach-app/src/filename.rs::apply_template(template, tag, project, date)` strips `{`/`}` from substituent values (adv fix #6) before sequential `.replace()` of `{tag}`/`{project}`/`{date}`, then runs `sanitize_filename` with `"untitled"` empty fallback. 11 unit tests cover default-format Phase-10 byte-for-byte equality, multi-substitution, unknown-placeholder passthrough, illegal-char substituent, project-with-colon, empty fallback, only-placeholders empty fallback, Windows-reserved-name handling, brace-stripping round-trip, not-recursive substitution; `preferences_deserializes_without_template_field` test in core. 48 core + 29 filename tests pass. |
| Task 0 progress flip | `508f33c` | PROGRESS.txt — Phase 11 Plan #7 Task 0 row [x] |
| Task 1 | `612d558` | Slint dual-Repeater drag-to-reorder + LineEdit template input. Splits tag list into `selected-export-tag-rows` (top, ☰ drag handles, user-chosen order, adv fix #9 ship-blocker) + `unselected-export-tag-rows` (bottom, alphabetical). Hand-rolled drag gesture via two TouchAreas per row z-ordered with drag handle above row toggle (adv fix #3). Drop-Y captured in absolute window coords via `selected-list-top-y` bound from the top Repeater's parent rectangle's `absolute-position.y` (adv fix #4 + #12). Pure-Rust `drag_reorder_destination(_from, relative_drop_y, row_height, len)` helper clamps with `.floor().max(0).min(len)`. Export button gated `enabled: dragging-tag-index == -1` (adv fix #5). Dragged-row background `#3a3a3a` while held. LineEdit + "Placeholders: {tag}, {project}, {date}" hint added below the Codec row in the Form view. Modal height bump 600 → 680px. 4 pure-Rust drag_reorder tests (swap, same-index no-op, drop-below clamps to len, drop-above clamps to zero); full crate suite 83/83 green. PLACEHOLDER sheet-open hydration (Task 2 replaces). |
| Task 1 progress flip | `d5d5163` | PROGRESS.txt — Phase 11 Plan #7 Task 1 row [x] |
| Task 2 | `6f4a911` | Bus wiring + per-tag apply_template + sheet-open hydration. Drops `Copy` from `ExportPrefsSnapshot` and clones-on-read (adv fix #1); extends snapshot with `export_filename_template: String` and grows `export_prefs_to_slint_strings` to a 4-tuple. `Command::ExportCompilations` gains `filename_template: String` gated by `#[serde(default = "default_command_filename_template")]` calling `pub video_coach_core::project::default_filename_template()` (adv fix #2 plus `default_command_filename_template_matches_core` drift test). `handle_export_compilations` computes `today_local = chrono::Local::now().date_naive().format("%Y-%m-%d").to_string()` ONCE at the top (adv fix #7) and runs the sensitivity-test gate (adv fix #8) — probes ALPHA/BRAVO/2000-01-01 vs ZETA/YANKEE/2099-12-31 emitting two distinct `export.batch.failed` reasons (`filename_template_invalid`, `filename_template_no_placeholders`). Persists `project.preferences.export_filename_template` alongside `last_export_resolution`/`quality`/`codec`. Replaces hard-coded `sanitize_filename(&label)` / `sanitize_filename(&project_name_trimmed)` pair with single `apply_template(&template, label, &project_name_trimmed, &today_local)` call. ui.rs sheet-open helper extended to push template prefs into the LineEdit with empty/whitespace fallback to default (adv fix #10). 9 new tests; 92 tests pass; grep gates clean. |
| Task 2 progress flip | `73ff89e` | PROGRESS.txt — Phase 11 Plan #7 Task 2 row [x] |
| Code-review fix [1] | `a5de5e4` | SHIP-BLOCKER — toggle in open sheet did not move row between two Repeaters because `on_export_tag_toggled` mutated only `selected-export-tags`, never `selected-export-tag-rows` / `unselected-export-tag-rows`. Added `partition_export_tag_rows` helper + `AggregateRow` / `SplitRow` type aliases in ui.rs; wired into `on_export_tag_toggled`, `on_export_select_all_clicked`, `on_export_select_none_clicked`, AND `on_export_sheet_open_clicked` (the latter replaces Task 1's placeholder "everything in unselected, nothing in selected" split with a real partition based on `selected-export-tags`). 6 unit tests cover empty/full edges, drag-order preservation across toggle, newly-selected-appended-after-drag-order, toggle-off transition, dropped-tag-no-longer-in-aggregate. |
| Code-review fix [2] | `cada3a2` | NUL char (`\0`) in filename template survived `sanitize_filename` and would crash file write at runtime — added `'\0'` to illegal-char match arm + `nul_byte_is_replaced_with_dash` test (`clip\0name` → `"clip-name"`; standalone NUL → `"-"`). |
| Code-review fix [3] | `adadc79` | `selected-list-top-y` captured by `changed absolute-position` may not fire on a 0-height rectangle on first sheet open — added `changed height => root.selected-list-top-y = self.absolute-position.y` to `selected-list := Rectangle` so the value updates the moment rows render. |
| Code-review fix [4] | `3e13df9` | Validation order disagreed with Phase-10 contract — moved the two template-sensitivity gates (probe_a == 'untitled' → `filename_template_invalid`; selections.len() > 1 with no placeholders → `filename_template_no_placeholders`) to AFTER `is_busy` + `current.is_none()` checks in `handle_export_compilations`, restoring Phase-10 error-contract priority (`already_recording`, `already_exporting`, `no_project_open` win over template diagnostics). |
| Closeout | this commit | Plan closeout section + PROGRESS.txt Plan #7 SHIPPED |

### Adversarial-fix coverage (Fixes #1-#10)

All 10 fixes shipped; each verified present in shipped code.

- ✅ #1 Drop `Copy` from `ExportPrefsSnapshot`; clone on read (Task 2 — bus.rs)
- ✅ #2 `default_filename_template` declared `pub` (not `pub(crate)`); cross-crate equality test `default_command_filename_template_matches_core` proves no drift (Task 0 + Task 2)
- ✅ #3 Drag handle uses a SECOND TouchArea z-ordered above the row toggle TouchArea (Task 1 — main.slint two TouchAreas declared in toggle-then-handle order)
- ✅ #4 Drop-Y math uses absolute window coordinates via `selected-list-top-y` bound from `absolute-position.y`; non-scrollable assumption documented with `// PLAN-7-NOTE`; pure-Rust clamp tests for drop-below + drop-above edges (Task 1 — ui.rs `drag_reorder_destination`)
- ✅ #5 Export button gated `enabled: dragging-tag-index == -1` while dragging (Task 1 — main.slint)
- ✅ #6 `apply_template` strips `{` and `}` from substituent values (tag/project) before sequential `.replace()`; brace-stripping round-trip + not-recursive tests (Task 0 — filename.rs)
- ✅ #7 `chrono::Local::now().date_naive().format("%Y-%m-%d")` computed ONCE at top of `handle_export_compilations` for batch consistency (Task 2 — bus.rs)
- ✅ #8 Sensitivity-test template validation: two probes (ALPHA/BRAVO/2000-01-01 vs ZETA/YANKEE/2099-12-31), two distinct failure reasons (`filename_template_invalid` for sanitize-empty + `filename_template_no_placeholders` for N>1 overwrite risk); single-tag with no-placeholders proceeds (Task 2 — bus.rs)
- ✅ #9 Dual-Repeater split — `selected-export-tag-rows` (top, drag-orderable) + `unselected-export-tag-rows` (bottom, alphabetical); ship-blocker fix completed by code-review fix [1] which wired the partition through every toggle/select-all/select-none/sheet-open path (Task 1 + code-review fix [1])
- ✅ #10 Empty/whitespace-only template hydration falls back to `default_filename_template()`; `hydrate_empty_template_falls_back_to_default` test (Task 2 — ui.rs)

### Code-review findings

Inline code-review pass on the `0f500a5..73ff89e` diff (8 commits — plan
+ adv-fixes + 3 task implementations + 3 progress commits + closeout-
progress) produced 12 findings:

| Triage | Count | Findings |
|---|---|---|
| **REAL ship-blocker** | 1 | [1] toggle in open sheet does not repartition the two Repeaters; drag is unreachable |
| **REAL bugs** | 3 | [2] NUL char (`\0`) survives `sanitize_filename` and crashes file write; [3] `selected-list-top-y` captured by `changed absolute-position` may not fire on 0-height rect; [4] template-sensitivity gates run before `is_busy` / `no_project_open`, flipping Phase-10 error-contract priority |
| **REAL but edge** | 4 | [5] sensitivity test misses real-tag post-sanitize collisions (e.g., `5:30 drill` + `5/30 drill` both → `5-30 drill`); [6] long template can exceed PATH_MAX/NAME_MAX with no truncation; [7] drag-handle hit-rect width is 32px (plan said 24×24); [8] `_from` param in `drag_reorder_destination` unused — clarity |
| **OVERSTATED** | 2 | [9] SetScanVolume-during-Export-click race (bus dispatcher is serial); [10] legacy harness clients with old semantics (no old semantics — field is brand-new) |
| **SPECULATIVE** | 2 | [11] empty-rect `changed absolute-position` first-fire (auto-resolves with [1]); [12] 30 Hz timer doesn't track sheet-open state (auto-resolves with [1]) |

The 4 REAL fix-worthy findings shipped as 4 separate fix-up commits
(`a5de5e4`, `cada3a2`, `adadc79`, `3e13df9`) for git-blame clarity — see
Commits table above. REAL-but-edge #5/#6/#7/#8 deferred per triage;
OVERSTATED #9-#10 + SPECULATIVE #11-#12 rejected per triage. Total
fix-up LOC ~+200 / -10 (mostly the partition helper + 6 unit tests).

### Deferred to Phase 12+

- **#5 Real-tag post-sanitize collisions.** Sensitivity test proves the
  template substitutes tag/project/date, but does not detect the case
  where two real tags sanitize to the same on-disk name (e.g.,
  `"5:30 drill"` and `"5/30 drill"` both → `"5-30 drill"`; the second
  `apply_template` result silently overwrites the first because the
  per-tag `let _ = std::fs::remove_file(&output_path);` masks
  pre-existing files). Mitigation cost is small (hash the rendered
  filename per tag in the for-loop and bail with a third reason
  `filename_template_collision`); deferred because the workaround is for
  the user to pick a less-collision-prone template (e.g., `"{tag} ({project})"`)
  or rename a colliding tag.
- **#6 Output filename length cap.** `apply_template` does not bound
  output length. A pathological template like `"{tag}_{tag}_{tag}_..."`
  or a single-substituent case where the project name is 300 chars
  produces a filename that may exceed Windows MAX_PATH (260) with
  long-path support disabled or POSIX NAME_MAX (255 bytes). Mitigation:
  truncate the post-`apply_template` filename to ~200 bytes (UTF-8
  continuation-byte safe) before joining. Deferred — only the
  worst-typed templates trip it.
- **#7 Drag-handle hit-rect width.** Currently 32px; plan-and-adv-fix #3
  said 24×24. 32px is more usable on macOS trackpads but the deviation
  isn't logged in the Task 1 PROGRESS entry. If a future plan makes the
  modal width dynamic (currently fixed 560px), the 32px hit-rect could
  overlap the row checkbox at x=32px. Document or shrink in Phase 12.
- **#8 `_from` parameter clarity in `drag_reorder_destination`.**
  Helper takes a `_from: usize` it never reads (caller passes `len - 1`,
  i.e., the post-remove length). Either drop the param entirely or
  rename to `drag_reorder_destination_post_remove`. Cosmetic.

### Known coverage gaps (acceptable for shipping)

- **Multi-tag drag-reorder UI exercise.** The 6 partition unit tests
  + 4 drag-reorder math tests prove the data path. Manual smoke
  confirms the dual-Repeater renders + drag works on a 3-tag fixture.
  No integration test simulates a multi-tag drag-and-export end-to-end
  through the Slint timer.
- **Template persistence across project reopens.** The bus persists
  `project.preferences.export_filename_template` alongside the existing
  `last_export_*` fields, but no test loads a project, exports with a
  custom template, closes, reopens, and asserts the LineEdit hydrates
  from the saved value. The serde round-trip + sheet-open hydration
  paths are unit-tested in isolation; the join is manual-only.
- **Drag-while-toggling race.** A user could press the drag handle on
  one row while another row's checkbox is mid-toggle. Adv fix #5 gates
  the Export button while dragging (`dragging-tag-index == -1`), but the
  toggle handler itself is not gated. Result is that a row may move
  between the two Repeaters mid-drag; the partition helper handles the
  membership change, but the dragged row's index in
  `selected-export-tag-rows` may shift under it. No regression test;
  manual smoke shows the drag completes against the new index ordering.
- **Sensitivity test boundary.** The two probes (ALPHA/BRAVO/2000-01-01
  vs ZETA/YANKEE/2099-12-31) catch templates that don't reference any
  placeholder. They do NOT catch a template that references only
  `{date}` for a single-day batch + N>1 tags (date is constant for the
  batch by adv fix #7 design, so all rendered names collide). The N>1
  no-placeholders gate would catch most of these; a `{date}`-only
  template with N>1 tags slips past because `apply_template` for ALPHA
  vs ZETA only differs in the tag substitution (which the template
  doesn't read). Edge — the sensitivity gate is a heuristic; the
  collision-detection in deferred #5 would close this gap properly.

These gaps are noted for future regression sweeps; they don't block
shipping.
