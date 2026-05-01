# Rust Rewrite — Phase 11 Plan #2: Real Export Progress Percentage

Branch: `rust-rewrite`. Phase 11 is Polish + deferred items from Phase 10's
closeout. This plan replaces the indeterminate "Exporting <tag> (N of M)…"
spinner with a real 0..1 progress bar fed from the per-frame counter
already plumbed by Phase 10 fix #23.

---

## Goal (one paragraph)

Phase 10 ships an indeterminate spinner during batch export. `export.rs`
already emits an `ExportProgress { frames_pushed, frame_index,
total_frames, current_entry_index }` callback per fix #23, but the bus
task currently discards it via `Box::new(|_progress| {})` (bus.rs:2433).
Plan #2 wires that callback into a throttled writer on
`ExportProgressSlot`, aggregates per-tag progress into a batch-level 0..1,
and binds a Slint progress bar Rectangle to the slot. The 30 Hz UI poller
already in place hydrates the bar from the slot. No new threads, no new
channels — just a `Box::new` closure capturing an `Arc<Mutex<…>>` and a
small set of Slint property writes.

---

## What Phase 11 Plan #2 deliberately does NOT include

1. **GStreamer position-query 1 Hz signal source.** The scope mentions it
   as optional. Frame-counter progress is already monotonic per-tag (the
   driver pushes one frame per entry+freeze tick), and the freeze-segment
   case is already accounted for in `total_frames` (entry duration ×
   30 fps). Adding a separate position-query thread duplicates a signal
   we already have and introduces a second writer to the slot. Defer to
   a future plan only if mfh264enc cold-start or VT encoder back-pressure
   prove visually problematic during code review.
2. **ETA / time-remaining estimate.** Out of scope. The bar shows percent
   only — no smoothing, no ETA.
3. **Per-frame UI updates.** The 30 Hz UI poller stays at 30 Hz. The
   throttle on the writer side caps slot writes to ≤30 Hz so the poller
   sees at most one new value per tick.
4. **Across-tag smoothing.** A 5-tag batch's batch-level progress jumps
   in 5 segments of 0..0.2, 0.2..0.4, etc. We do NOT prorate by per-tag
   `total_frames` (some tags have one entry, others have ten) — every tag
   contributes 1/N to the batch regardless of length. Reasoning: simpler
   mental model, no need to know the sum-of-totals up-front, no surprise
   if a tag is skipped (`empty plan` path in bus.rs already does
   `continue`). If reviewer flags this as misleading, OK to revisit.
5. **Cancel-during-rebar animation.** When the user clicks Cancel and
   the run terminates early, the bar will simply stop at wherever it was;
   the outcome view replaces the in-progress view a frame later. No
   special "drain to 100%" or "snap to 0%" animation.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; especially the per-task sections below.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`'s
   "Adversarial-review fixes baked in" section, in particular fix #34
   (ExportProgressSlotData enum/fields) and fix #23 (`frames_pushed`
   counter on `export.tag.completed`). Also read the "Locked-in scope"
   bullet 3 — that's the indeterminate-bar decision Plan #2 is reversing.
3. `crates/video-coach-media/src/export.rs:121-149` — `ExportProgress`
   struct + `on_progress` callback signature on `export_compilation()`.
   Also skim where the callback is invoked inside the per-frame push loop
   (`grep -n on_progress crates/video-coach-media/src/export.rs`).
4. `crates/video-coach-app/src/frame_sink.rs:166-218` — `ExportRunOutcome`
   enum and `ExportProgressSlotData` struct; this plan extends the latter
   with two `f32` fields.
5. `crates/video-coach-app/src/bus.rs:2336-2436` — the per-tag `for`-loop
   inside the spawned export task; `Box::new(|_progress| {})` is at
   line 2433 of the current file (search if the line number drifts).
6. `crates/video-coach-app/ui/main.slint:1270-1327` — current InProgress
   view block; this plan replaces the static "(N of M)" Text with a
   progress-bar Rectangle.
7. `crates/video-coach-app/src/ui.rs:283-379` — the 30 Hz Slint Timer's
   `export_progress_for_timer.lock()` block; this plan adds two more
   tuple-elements for the new progress fields and two more
   `w.set_export_…` setter calls.

---

## Adversarial-review fixes baked in

(Filled in by stage `ADV_REVIEWED` after the adv-plan-review sub-agent
runs. Triage: REAL → fold in; SPECULATIVE → reject + log rationale here;
OVERSTATED → fold in trimmed + log.)

---

## Slot shape

Extend `ExportProgressSlotData` (in `frame_sink.rs`) with two new fields:

```rust
pub struct ExportProgressSlotData {
    pub outcome: ExportRunOutcome,
    pub current_tag: Option<String>,
    pub completed_tags: usize,
    pub total_tags: usize,
    /// 0..1 progress of the currently-rendering tag. Set whenever
    /// `outcome == InProgress`; clamped to [0.0, 1.0]. Reset to 0.0
    /// at the top of each tag iteration, before the per-frame push
    /// loop starts. Held at its last value through terminal-state
    /// transitions so a snapshot at completion isn't visually weird,
    /// but the UI ignores this field outside `InProgress`.
    pub current_tag_progress: f32,
    /// 0..1 progress of the entire batch. Computed in the throttle
    /// writer as `(completed_tags as f32 + current_tag_progress) /
    /// total_tags as f32`. Same lifecycle notes as
    /// `current_tag_progress`.
    pub batch_progress: f32,
}
```

The bus is the sole writer for both fields; the UI's 30 Hz poller is the
sole reader. Lock duration stays short (a small struct, no I/O).

## Throttle policy

The bus's `on_progress` closure is invoked once per video frame pushed
(typically 30 Hz × 1..M entries × 1..N tags). Two cases pile up:

1. **Many fast frames.** A 60-second tag at 30 fps = 1800 callback
   invocations. Updating Slint at that rate is wasteful — the 30 Hz UI
   poller can only display 30 distinct values per second.
2. **Encoder back-pressure / mfh264enc cold-start.** Some encoders take
   5-10 seconds to push the first frame (Phase 10 fix surfaced this).
   During that window the bar must not appear frozen — the closure
   doesn't fire AT ALL until the first frame is pushed.

Throttle policy in the closure:

- Maintain `(last_progress: f32, last_write: Instant)` captured by the
  closure (`Cell`/`RefCell` since the closure is `Fn`, not `FnMut`; or
  use `AtomicU32` for `last_progress` bits + `Mutex<Instant>` for time —
  pick the simpler one when implementing). Update slot only if BOTH:
  - `(new_progress - last_progress).abs() >= 0.005` (≈0.5%), OR
  - `last_write.elapsed() >= Duration::from_millis(100)` (10 Hz floor).
- The OR (not AND) ensures the bar still ticks every 100 ms even when
  progress is finely incrementing (so the eye sees motion), and also
  jumps immediately on big deltas (so freeze-segment skips don't get
  buffered).

The mfh264enc cold-start case is NOT solved by the throttle — it's
solved by Task 0 below initialising `current_tag_progress = 0.0` at the
top of each tag iteration BEFORE the closure runs. The bar shows 0% for
the first 5-10 seconds of cold-start; the (N of M) tag-counter and the
tag name still update so the user knows the batch is alive.

## Aggregation policy (per-tag → batch)

`current_tag_progress` is `progress.frame_index / progress.total_frames`
(both `u64`; cast carefully — see fix #1 in the adv-review section if
flagged). `batch_progress` is `(completed_tags + current_tag_progress) /
total_tags` (both as `f32`). Computed inside the closure under the slot
lock so the two fields are written atomically. `completed_tags` and
`total_tags` are read from the slot itself — the closure already needs
the lock to write the new fields, so reading them is free.

Edge cases:

- `total_frames == 0` (degenerate plan, shouldn't happen since bus skips
  empty plans, but defensive): set `current_tag_progress = 0.0`.
- `total_tags == 0` (also shouldn't happen — early-exit in bus.rs at
  step 1 catches `selections.is_empty()`): closure isn't invoked because
  the export loop doesn't run.
- `frame_index > total_frames` (rounding error): clamp to 1.0. Slint's
  Rectangle width math already handles ≥100% gracefully if we clamp.

## Slint UI shape

Replace the static "{completed_tags+1} of {total_tags}" Text in the
InProgress view with a horizontal progress bar:

```slint
in property <float> export-current-tag-progress: 0.0;  // 0..1
in property <float> export-batch-progress: 0.0;        // 0..1

if root.export-outcome-kind == "in_progress": Rectangle {
    // ... existing structure ...

    // Tag name + counter line stays.
    Text {
        text: "Exporting " + root.export-current-tag + "…";
        // ...
    }
    Text {
        text: (root.export-completed-tags + 1) + " of "
            + root.export-total-tags + " — "
            + round(root.export-batch-progress * 100) + "%";
        // ...
    }

    // NEW: progress bar.
    Rectangle {
        x: 80px;
        y: 130px;
        width: parent.width - 160px;
        height: 8px;
        background: #303030;
        border-radius: 4px;

        Rectangle {
            x: 0;
            y: 0;
            width: parent.width * root.export-batch-progress;
            height: parent.height;
            background: #4a90e2;  // matches Done button blue
            border-radius: 4px;
            animate width { duration: 200ms; easing: ease-out; }
        }
    }

    // Cancel button position drops down by ~20px to clear the bar.
}
```

The 200 ms ease-out on `width` smooths the every-100ms slot writes into
visually continuous motion. Slint's `animate` property targets a single
property change, so each slot update kicks off a new 200 ms tween — by
the time the next update lands, the previous tween is mostly finished
(100 ms throttle floor + 200 ms tween = overlapping), giving a
continuously-flowing bar rather than a stairstep.

We display the BATCH percentage (not the tag percentage) because the
batch number is the one users care about (it's the "how long until I'm
done" answer). The current-tag-progress field is exposed in case a
future plan wants a secondary thinner bar; for Plan #2 it's plumbed but
not displayed.

---

## Tasks (3 total — fits in 3 sub-agent dispatches well under 700 LOC each)

### Task 0: Preflight — `ExportProgressSlotData` fields + bus throttled writer

Touches: `crates/video-coach-app/src/frame_sink.rs`,
`crates/video-coach-app/src/bus.rs`. ~80-120 LOC.

1. **Extend `ExportProgressSlotData`** in `frame_sink.rs` with
   `pub current_tag_progress: f32` and `pub batch_progress: f32`. Update
   `Default` derivation (already `Default`-derived, so the new `f32`s
   default to 0.0 — verify this).
2. **Update doc-comment** on `ExportProgressSlotData` to mention the new
   fields and link them back to this plan / fix #23 lineage.
3. **In `bus.rs`'s spawned export task** (the `tokio::spawn(async move
   { ... 'outer for ... })` block starting at the current line 2340):
   - At the top of each tag iteration (where `g.current_tag` and
     `g.completed_tags` are written, currently around line 2396-2402),
     also reset `g.current_tag_progress = 0.0` and recompute
     `g.batch_progress = i as f32 / total_tags as f32`. (Use `i`, the
     loop index, not `completed_tags`, because `completed_tags` only
     ticks AFTER a tag finishes. `i` is the index of the tag about to
     start, which equals the count of tags fully done before this one.)
   - Replace `Box::new(|_progress| {})` with a real closure capturing
     `Arc::clone(&export_progress_for_task)` (already in scope) plus
     local state for throttling.
   - The closure: takes `progress: ExportProgress`, computes
     `tag_p = (frame_index / total_frames).clamp(0.0, 1.0)` (handle
     `total_frames == 0` → 0.0), reads `completed_tags + total_tags`
     from the slot under the lock, computes
     `batch_p = (completed_tags + tag_p) / total_tags`, applies throttle
     (delta ≥ 0.005 OR last_write ≥ 100 ms), writes both fields under
     the same lock guard if not throttled.
   - Throttle state: simplest implementation is `let last = Arc::new
     (Mutex::new((0.0_f32, Instant::now() - Duration::from_millis
     (1000))))` outside the closure, captured by clone — the closure
     locks `last`, reads, decides, writes back, drops. The slot lock is
     acquired AFTER the throttle decision so we don't hold both locks at
     once. (Order matters for deadlock avoidance — see fix #X in
     adv-review section if reviewer raises it.)
4. **Verification**: scoped build + clippy + fmt of `video-coach-app`.
   No new tests — the throttling logic is too time-dependent for a unit
   test; the harness E2E (Phase 10's preview_clip_smoke and export
   smoke) implicitly exercise it.

Commit: `phase11(real-progress-pct, task 0): wire on_progress callback
to ExportProgressSlot with throttled writer`.

### Task 1: Slint progress bar + ui.rs hydration

Touches: `crates/video-coach-app/ui/main.slint`,
`crates/video-coach-app/src/ui.rs`. ~80-120 LOC.

1. **`main.slint`**: add two new in properties
   `export-current-tag-progress: float` and `export-batch-progress:
   float`, both default 0.0. Place them in the existing block of
   `in property <…> export-…` declarations near line 128.
2. **InProgress view block** (line 1270-1327): replace the "(N of M)"
   counter Text with the new "(N of M) — XX%" Text (using
   `round(root.export-batch-progress * 100)`) and add the progress-bar
   Rectangle after it. Move the Cancel button down by ~20px so the bar
   has clearance. Test by eyeballing: the card is 540px tall, header at
   y=20, "Exporting … " at y=60, "(N of M) — XX%" at y=96, bar at
   y=128, Cancel at y=parent.height-60. Already fits.
3. **`ui.rs`**: extend the `let (outcome_kind, export_active, total_tags,
   completed_tags, current_tag, summary_folder, summary_file_count,
   error_text, failed_tag, cancelled_completed) = { ... }` 10-tuple with
   two more `f32` elements: `current_tag_progress` and `batch_progress`.
   Read them from the slot inside the `InProgress` arm; default to 0.0
   in all other arms. Add `w.set_export_current_tag_progress(...)` and
   `w.set_export_batch_progress(...)` calls in the property-write block
   after the existing setters.
4. **Verification**: scoped build of `video-coach-app` (compiles Slint),
   clippy, fmt. Run the app once locally if convenient — no automated
   visual test.

Commit: `phase11(real-progress-pct, task 1): UI progress bar bound to
batch_progress slot field`.

### Task 2: Closeout

Touches: this plan file (closeout section), `PROGRESS.txt` (Phase 11
progress block update). ~30 LOC.

1. **Append a closeout section** to the bottom of this plan file
   (after the Tasks section and any adv-review fixes section), shape:
   ```
   ## Closeout
   
   Plan #2 SHIPPED <date>. CI run id: <placeholder, filled by orchestrator>.
   
   What landed:
   - ExportProgressSlotData carries current_tag_progress + batch_progress.
   - Bus's spawned export task wires on_progress through a throttled
     writer (10 Hz floor, 0.5% delta).
   - Slint InProgress view shows a 200ms-eased horizontal progress bar
     bound to batch_progress + a "XX%" counter.
   
   Deferred to future plans (intentional):
   - GStreamer position-query 1 Hz secondary signal — frame-counter
     proved sufficient.
   - ETA estimate — out of scope.
   - Across-tag smoothing weighted by per-tag total_frames — current
     equal-weight aggregation is the simpler mental model.
   ```
2. **Update PROGRESS.txt** Phase 11 progress block: change Plan #2's
   status line to a SHIPPED line with the run id placeholder. (The
   orchestrator's `CLOSEOUT_COMMITTED` → `CI_PENDING` → `CI_DONE` →
   `DONE` flow will replace the placeholder with the real run id in a
   final small commit after CI passes.)
3. **Verification**: full workspace verification battery (bus task only
   touches comments + this file's text; no code changes, but the
   battery is the gate before push):
   ```
   cargo build --workspace --features media
   cargo test --workspace --features media
   cargo build --workspace
   cargo test --workspace
   cargo build --workspace --no-default-features
   cargo clippy --workspace --all-targets --features media -- -D warnings
   cargo clippy --workspace --exclude video-coach-media --all-targets -- -D warnings
   cargo fmt --check
   ```

Commit: `phase11(real-progress-pct, task 2): closeout — Plan #2 SHIPPED`.

(The orchestrator handles PROGRESS.txt `[ ]` → `[x]` flips per task in
SEPARATE commits as `docs: PROGRESS.txt — task N done <SHA>`.)

---

## Files-touched summary

| File | Task | Reason |
|---|---|---|
| `crates/video-coach-app/src/frame_sink.rs` | 0 | Add 2 `f32` fields to `ExportProgressSlotData`. |
| `crates/video-coach-app/src/bus.rs` | 0 | Replace `Box::new(\|_\| {})` with throttled writer; reset progress per tag. |
| `crates/video-coach-app/ui/main.slint` | 1 | Add 2 `in property <float>`; add progress-bar Rectangle in InProgress view. |
| `crates/video-coach-app/src/ui.rs` | 1 | Hydrate 2 new Slint properties from slot. |
| `docs/plans/2026-05-01-rust-rewrite-phase-11-real-progress-pct.md` | 2 | Closeout section. |
| `PROGRESS.txt` | 2 | Phase 11 Plan #2 → SHIPPED line. |

Total LOC budget: ~150-300, well under the 700-per-task hard cap.
