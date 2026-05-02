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
are NOT re-raised. (Filled in by main session after the adversarial-
review pass; placeholder list below documents the structure.)

> _**To main session writing this plan**: run an adversarial-review
> pass before committing the plan, paste the fixes below, then commit.
> If you skip this and the section stays empty, the sub-agent should
> stop and ask the user._

(Fixes will be appended here under the orchestrator's
`PLAN_WRITTEN → ADV_REVIEWED → READY_FOR_TASK_0` transition.)

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

## Closeout

(Filled in at the `READY_FOR_CLOSEOUT` stage with the final SHA, CI
run id, and any deviation notes from the orchestrator's pass through.
PROGRESS.txt's "Plan #7: drag-reorder tag rows / custom filename
templates" line gets flipped to
`[x] … SHIPPED <date>. CI run <id> green on all 4 jobs.` at the same
time.)
