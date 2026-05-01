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

Adversarial review pass found 10 NET-NEW findings (no Phase 10 re-raise).
Triage: 5 REAL folded in verbatim, 3 OVERSTATED folded in trimmed,
0 SPECULATIVE rejected (the reviewer's own "Findings 11" rejection list
covers what was considered and dropped). Each fix below numbered like
Phase 10's plan.

### Fix #1 — Use cumulative `frames_pushed`, not per-entry `frame_index`, for tag progress (REAL, HIGH)

`export.rs:1306` resets `frame_idx` to 0 at the top of every entry
(`for frame_idx in 0..entry_frame_count`), while `total_frames` is the
sum across all entries (`export.rs:291-296`). So
`frame_index / total_frames` would tick forward, snap backward, tick
forward, snap backward at every entry boundary — visibly broken on
multi-entry tags (the common case). `ExportProgress` already carries
the cumulative atomic counter `frames_pushed` (`export.rs:1352-1355`),
which is monotonic across all entries.

**Fix**: in the bus closure, compute
`tag_p = (progress.frames_pushed as f64 / progress.total_frames.max(1) as f64) as f32`
clamped to `[0.0, 1.0]`. Drop `frame_index` and `current_entry_index`
from the calculation entirely (they remain useful for tracing). Add a
one-line code comment in `bus.rs` explaining why `frame_index` would be
wrong.

### Fix #2 — Throttle storage must be `Arc<Mutex<…>>`, not `Cell` / `RefCell` (REAL, HIGH)

`export.rs:149` types the callback as
`Box<dyn Fn(ExportProgress) + Send + Sync>`. `Cell` and `RefCell` are
both `!Sync`, so capturing them in a closure that needs to be `Sync`
fails to compile. The plan's `Cell`/`RefCell` option is incorrect.

**Fix**: throttle state is
```rust
let last = Arc::new(Mutex::new(
    (0.0_f32, Instant::now() - Duration::from_millis(1000)),
));
```
captured by clone into the closure. The closure locks `last`, decides
write vs skip, writes back, drops the guard before touching the slot
lock. Single mutex round trip per progress event; no nested locking.

### Fix #3 — Capture `i` and `total_tags` as locals; closure must NOT read `completed_tags` from the slot (REAL, MEDIUM)

If the closure reads `completed_tags` from the slot, a future refactor
that parallelises tag exports (or any straggler progress event firing
after `spawn_blocking` returns) creates a race where the closure
computes `batch_progress` using the next tag's `completed_tags` while
writing the current tag's `current_tag_progress`.

**Fix**: at the top of each tag iteration in the bus, capture the
loop index `i` and the batch size `total_tags` as plain `usize` locals
BEFORE constructing the closure. The closure then computes
`batch_p = (i as f32 + tag_p) / total_tags as f32` from captured
immutables only. The slot lock inside the closure is write-only,
removing the read-write conflation.

### Fix #4 — Snap to 100% after a successful tag, before incrementing `completed_tags` (REAL, MEDIUM)

The callback fires at `frame_idx % 30 == 0`. The very last frame of
the very last entry of a tag does NOT fire the callback unless
`(entry_frame_count - 1) % 30 == 0`. A 5-second entry (150 frames) at
30 fps last-fires at `frame_idx = 120` → `tag_p = 0.8`. The remaining
30 frames push without firing the callback; the slot stays at 0.8
until the bus advances. On a 5-tag batch this leaves
`batch_progress = (4 + 0.8) / 5 = 96%` at the moment the summary view
replaces the in-progress view. Users see the bar visibly stop short.

**Fix**: in the per-tag for-loop in `bus.rs`, after `spawn_blocking`
returns `Ok(Ok(_))` (the success arm), snap the slot to
`current_tag_progress = 1.0` and `batch_progress = (i + 1) as f32 / total_tags as f32`
BEFORE the existing `completed_tags += 1` increment. Cheap, no race
(we're between iterations and the closure for tag `i` is dropped when
`spawn_blocking` returns).

### Fix #5 — Throttle closure must recover from `Mutex` poison, not panic (REAL, MEDIUM)

Panic-on-poison is fine for the bus's own slot (already
`.expect("export_progress poisoned")`). But the throttle's NEW
`Arc<Mutex<(f32, Instant)>>` is best-effort state. If any future panic
inside the closure poisons it, every subsequent callback would also
panic, killing the `spawn_blocking` task and bypassing
`export.rs:317-320`'s stepped Paused → Ready → Null teardown.

**Fix**: in the closure, use
`last.lock().unwrap_or_else(|e| e.into_inner())` so a malformed event
doesn't escalate to a driver-loop panic. Comment one line on why
poison-recovery is right here (versus the slot, which we DO panic on).

### Fix #6 — Throttle policy framing: callback fires ~1 Hz (`frame_idx % 30 == 0`), not 30 Hz (OVERSTATED, MEDIUM)

`export.rs:1353` wraps the callback in `if frame_idx % 30 == 0`. At
30 fps a 60-second tag fires the callback ~60 times; a 5-second entry
fires 5 events. The plan's "1800 callback invocations" / "30 Hz"
framing is wrong — there is no 30 Hz pile-up to debounce.

**Fix**: rewrite the "Throttle policy" section to:
- Acknowledge the ~1 Hz invocation cap from `frame_idx % 30 == 0`.
- Drop the "throttle to ≤30 Hz" claim and the "1800 invocations"
  arithmetic.
- Drop the 100 ms time floor — at ~1 Hz natural cadence the time
  floor never trips. The throttle is just a `(new_progress -
  last_progress).abs() >= 0.005` delta gate that prevents redundant
  slot writes when frames_pushed advances within the same 0.5%
  bucket. Keep the gate as a defence against future call-site
  changes (if `frame_idx % 30 == 0` is ever loosened to per-frame).
- Note: with ~1 Hz callback cadence and the 200 ms eased width
  animation, the bar moves in 200 ms eased segments separated by
  ~800 ms hold. Acceptable; documented for the code reviewer.

### Fix #7 — Compute the ratio in `f64`, cast to `f32` for storage (OVERSTATED, MEDIUM)

`f32` has 23-bit mantissa; `frames_pushed as f32` and
`total_frames as f32` start losing integer precision past 2^24 ≈
16.7M frames. At 30 fps that's ~155 hours per tag — far beyond any
realistic export. The practical impact is narrow but the plan's
placeholder ("cast carefully — see fix #1 in adv-review section if
flagged") should resolve to a concrete spec.

**Fix**: compute the ratio in `f64` and cast the result to `f32`:
```rust
let p = (frames_pushed as f64 / total_frames.max(1) as f64) as f32;
```
`.max(1)` defensively avoids div-by-zero (already covered by the
`total_frames == 0` clause; spell both in one line).

### Fix #8 — Per-arm `(current_tag_progress, batch_progress)` defaults in `ui.rs` (OVERSTATED, LOW)

The plan said "default to 0.0 in all other arms" without spelling out
which 5 arms. No shipped UI bug today (Plan #2 only displays the bar
in the `InProgress` view), but the slot is read by the timer
unconditionally and a future plan reusing these fields elsewhere
silently inherits whatever default we picked.

**Fix**: spell the per-arm defaults in `ui.rs` in Task 1:
- `None` → `(0.0, 0.0)`
- `InProgress` → `(g.current_tag_progress, g.batch_progress)`
- `SucceededAll` → `(1.0, 1.0)` (export ran to completion)
- `PartialFailure` → `(g.current_tag_progress, g.batch_progress)`
  (pass-through so a future "the bar froze HERE when it failed"
  affordance has the right value)
- `Cancelled` → `(g.current_tag_progress, g.batch_progress)`
  (same reasoning)

### Fix #9 — Slint `.round()` method form, not free `round(…)` function (REAL, LOW)

Slint's `round` exists in some compilation modes as a free function
on `float` expressions; in others it requires `.round()` method-call
form. If the project's pinned Slint version doesn't accept
`round(expr)`, Task 1 fails at the compile step.

**Fix**: in Task 1, write `(root.export-batch-progress * 100).round()`
using method-call form. This is portable across recent Slint versions.
If even this fails on the project's pinned version, fall back to
`Math.round(...)` and surface the deviation.

### Rejected findings

The reviewer pre-rejected three speculative items in their own
"Findings 11 (REJECTED — speculative)" subsection:
- "Slint property-write order non-atomic vs. UI repaint" — Slint
  batches property writes into a single re-render frame; no torn
  frames possible.
- "AtomicU32 + bit-cast f32" alternative throttle storage — the
  `Mutex<(f32, Instant)>` approach in Fix #2 is simpler and lock
  contention is negligible at ~1 Hz.
- "Cancel-during-rebar leaving the bar at >0%" — Plan #2 explicitly
  accepts this in non-goal #5; not a bug.

No additional rejections this pass.

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

(Reframed per Fix #6.) `export.rs:1353` wraps the callback in
`if frame_idx % 30 == 0 { on_progress(...) }`, so the closure fires
~1 Hz at 30 fps — once per second of *entry* duration. There is no
30 Hz pile-up to debounce. The throttle's actual job is:

1. **Defence-in-depth against future call-site changes.** If a future
   refactor loosens `frame_idx % 30 == 0` to per-frame, we don't want
   to start writing the slot 30× per second.
2. **De-dupe within a slow tag.** If `frames_pushed` advances within
   the same 0.5% bucket between two callbacks (rare, but possible on
   very long tags where 30 frames < 0.5% of `total_frames`), skip the
   slot write to keep the lock free.

Throttle state in the closure:

```rust
let last = Arc::new(Mutex::new(
    (0.0_f32, Instant::now() - Duration::from_millis(1000)),
));
```

(Fix #2 — `Cell` / `RefCell` are `!Sync`; `Box<dyn Fn + Send + Sync>`
requires `Sync`.) Captured by clone into the closure. The closure
locks `last` with `unwrap_or_else(|e| e.into_inner())` (Fix #5: poison
recovery), reads the previous value, decides write vs skip, writes
back, drops the guard.

Update gate (single condition, not two):

- `(new_progress - last_progress).abs() >= 0.005` (≈0.5% delta).

The time floor from the original plan is dropped (Fix #6) — at the
real ~1 Hz callback cadence it never trips. The bar moves in 200 ms
eased segments separated by ~800 ms hold (per the 200 ms tween + 1 Hz
update); documented for the code reviewer.

Encoder cold-start (mfh264enc 5-10 s with no frames pushed) is NOT
solved by the throttle — it's solved by Task 0 initialising
`current_tag_progress = 0.0` at the top of each tag iteration BEFORE
the closure runs. The bar shows 0% during cold-start; the (N of M)
tag-counter and the tag name still update so the user knows the batch
is alive.

## Aggregation policy (per-tag → batch)

(Per Fix #1 + Fix #3 + Fix #7.) `current_tag_progress` is computed
from the cumulative `frames_pushed` counter, NOT the per-entry
`frame_index`:

```rust
// In bus.rs's on_progress closure:
let tag_p = (progress.frames_pushed as f64
    / progress.total_frames.max(1) as f64) as f32;
let tag_p = tag_p.clamp(0.0, 1.0);
```

`f64`-divide-then-cast (Fix #7) avoids precision loss at the 2^24
mantissa boundary. `.max(1)` defensively handles `total_frames == 0`
in one line. Why not `frame_index`: `frame_idx` resets to 0 at the top
of every entry (`export.rs:1306`), while `total_frames` is the sum
across entries (`export.rs:291-296`); using `frame_index / total_frames`
would tick forward, snap backward, tick forward at every entry
boundary — visibly broken on multi-entry tags.

`batch_progress` is computed using captured-local `i` (the tag loop
index) and `total_tags`, NOT read from the slot (Fix #3):

```rust
let batch_p = ((i as f32 + tag_p) / total_tags as f32).clamp(0.0, 1.0);
```

`i` and `total_tags` are captured by the closure as plain `usize`
locals at the top of each tag iteration BEFORE the closure is
constructed. This makes the slot lock inside the closure write-only
and removes the read-write race that would surface under any future
refactor that drops the `.await` on `spawn_blocking` (e.g.
parallelising tags).

Edge cases:

- `total_frames == 0` (degenerate plan, shouldn't happen since bus
  skips empty plans, but defensive): `.max(1)` in the f64-divide
  yields `tag_p = 0.0`.
- `total_tags == 0` (also shouldn't happen — early-exit in bus.rs at
  step 1 catches `selections.is_empty()`): closure isn't invoked
  because the export loop doesn't run. (The closure still divides by
  `total_tags as f32`; if it ever WAS zero we'd get a NaN, but the
  closure can't fire in that case.)
- `frames_pushed > total_frames` (rounding error): the
  `.clamp(0.0, 1.0)` on `tag_p` and `batch_p` covers it. Slint's
  Rectangle width math already handles ≥100% gracefully if we clamp.

**Last-frame snap** (Fix #4): the callback fires at
`frame_idx % 30 == 0`, so the very last frame of a tag often does NOT
fire the callback. After `spawn_blocking` returns `Ok(Ok(_))` in the
bus's per-tag for-loop, snap the slot to
`current_tag_progress = 1.0` and
`batch_progress = (i + 1) as f32 / total_tags as f32`
BEFORE the existing `completed_tags += 1` increment. No race: we're
between iterations, the closure for tag `i` is dropped when
`spawn_blocking` returns.

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
        // Use `.round()` method form, not free `round(...)` (Fix #9).
        text: (root.export-completed-tags + 1) + " of "
            + root.export-total-tags + " — "
            + (root.export-batch-progress * 100).round() + "%";
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
   - **Capture `i` and `total_tags` as plain `usize` locals** BEFORE
     constructing the closure (Fix #3). The closure must NOT read
     `completed_tags` from the slot — only write into it.
   - **Throttle state** (Fix #2): outside the closure, build
     ```rust
     let last_progress = Arc::new(Mutex::new(
         (0.0_f32, Instant::now() - Duration::from_millis(1000)),
     ));
     ```
     and clone it into the closure. (`Cell` / `RefCell` are `!Sync`
     and would not satisfy the `Box<dyn Fn + Send + Sync>` bound on
     `on_progress`.)
   - **Replace `Box::new(|_progress| {})`** with a real closure that:
     1. Computes `tag_p = (progress.frames_pushed as f64 /
        progress.total_frames.max(1) as f64) as f32`, clamped to
        `[0.0, 1.0]` (Fix #1 — use cumulative `frames_pushed`, NOT
        per-entry `frame_index`; Fix #7 — `f64` divide, then cast).
        Add a one-line comment: "// frames_pushed is monotonic across
        entries; frame_index resets per entry (export.rs:1306) and
        would tick backward at boundaries."
     2. Computes `batch_p = ((i as f32 + tag_p) / total_tags as f32)
        .clamp(0.0, 1.0)` from captured locals.
     3. Locks the throttle mutex with
        `last_progress.lock().unwrap_or_else(|e| e.into_inner())`
        (Fix #5 — poison-recover instead of panic; comment one line on
        why we recover here vs panic on the slot).
     4. If `(batch_p - last_p).abs() < 0.005` AND a sentinel hasn't
        been forced, drop the throttle guard and return — no slot
        write. Otherwise update the throttle tuple to `(batch_p, now)`.
        (Fix #6 — single delta gate, no time floor.)
     5. Drop the throttle guard, then lock the slot with
        `.expect("export_progress poisoned")` (panic preserved for the
        slot itself), write `current_tag_progress = tag_p` and
        `batch_progress = batch_p`, drop the slot guard. Two locks
        acquired in series, never nested.
   - **Snap to 100% on tag success** (Fix #4): in the bus's per-tag
     for-loop, after the `spawn_blocking` await returns `Ok(Ok(_))`
     and BEFORE the existing `completed_tags += 1` increment, lock
     the slot once and write
     `g.current_tag_progress = 1.0;`
     `g.batch_progress = ((i + 1) as f32 / total_tags as f32).min(1.0);`
     so the bar visually reaches the segment boundary even when the
     last entry's frame count isn't a multiple of 30.
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
   counter Text with the new "(N of M) — XX%" Text using
   `(root.export-batch-progress * 100).round()` (Fix #9 — method-call
   form, NOT free `round(...)`; if the project's pinned Slint version
   rejects even the method form, fall back to `Math.round(...)` and
   surface the deviation). Add the progress-bar Rectangle after it.
   Move the Cancel button down by ~20px so the bar has clearance. Test
   by eyeballing: the card is 540px tall, header at y=20, "Exporting
   … " at y=60, "(N of M) — XX%" at y=96, bar at y=128, Cancel at
   y=parent.height-60. Already fits.
3. **`ui.rs`**: extend the `let (outcome_kind, export_active, total_tags,
   completed_tags, current_tag, summary_folder, summary_file_count,
   error_text, failed_tag, cancelled_completed) = { ... }` 10-tuple
   with two more `f32` elements: `current_tag_progress` and
   `batch_progress`. Per Fix #8, spell the per-arm defaults explicitly:
   - `None` → `(0.0, 0.0)`
   - `InProgress` → `(g.current_tag_progress, g.batch_progress)`
   - `SucceededAll` → `(1.0, 1.0)` (export ran to completion)
   - `PartialFailure` → `(g.current_tag_progress, g.batch_progress)`
     (pass-through so a future affordance has the right value)
   - `Cancelled` → `(g.current_tag_progress, g.batch_progress)`
     (pass-through, same reasoning)

   Add `w.set_export_current_tag_progress(...)` and
   `w.set_export_batch_progress(...)` calls in the property-write
   block after the existing setters.
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
