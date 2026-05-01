# Rust Rewrite — Phase 10: Export Sheet UI + Batch Compilation Export

> **For Claude:** Implement via the per-phase sub-agent pattern (per
> `feedback_phase_per_subagent.md`). Phase 9's lessons say small per-task
> agents (4-5 sub-agents, NOT 2 big ones) — Phase 8's 3-task prompts hit
> the watchdog twice; Phase 9's per-task split had zero timeouts. Match
> that here.

**Goal:** Click File → Export Compilations → tick tags → pick a folder
→ pick resolution/quality → Export. Each ticked tag writes one .mp4 to
the chosen folder, in sort_index order, sequentially. Each output is
the source video walked through the clip's `PlaybackSegment[]` plus
the webcam PiP plus the captured strokes — all rendered through
**`compose_tick`** so preview-vs-export hash parity is structurally
enforced (a Phase 9 down-payment that Phase 10 fully cashes in).

This phase also resolves the Phase 9 closeout's deferred items:
1. **Framerate alignment** — preview is pinned 30 fps; export pins
   here too so the N-frame parity test in Task 6 can land.
2. **Strokes in the export pipeline** — Phase 5's `compose.rs` passes
   `&[]` for strokes today; Phase 10 wires `visible_strokes(clip,
   record_time)` per frame.
3. **Source-volume + commentary-volume mix** — v1 has separate
   sliders; preview ships commentary-only (Phase 9). Phase 10 wires
   the audiomixer with both volumes for export. Optional sub-deliverable:
   wire the same audiomixer into `PreviewPipeline` so preview also
   honors the dual-volume preferences.

**Architecture:**

- Bus gains `Command::ExportCompilations { tags: Vec<String>,
  output_folder: String, resolution: Resolution, quality: Quality,
  project_name: String }` and `Command::CancelExport`. Single batch
  command (NOT per-tag) so progress events have stable totals; the
  bus task loops through tags sequentially, emitting `export.tag.
  started` / `export.tag.completed` / `export.tag.failed` per tag and
  `export.batch.completed` / `export.batch.failed` at the end. New
  `AppMode::Exporting` variant.

- New `crates/video-coach-media/src/export.rs`: `export_compilation(
  plan, source_paths, recording_paths, output_path, resolution,
  quality, source_volume, commentary_volume, cancel_signal) ->
  Result<(), ExportError>`. Multi-input GStreamer pipeline:
  - One `filesrc → decodebin → videoconvert → RGBA appsink` per
    source video referenced by the plan (deduped by source_index).
  - One `filesrc → decodebin → videoconvert → RGBA appsink` per
    clip's recording.mov.
  - One `filesrc → decodebin → audioconvert → audioresample →
    volume(name="source_vol")` per source video (audio chain — NOT
    used by Phase 9 preview which is commentary-only).
  - One audio chain per recording (audio sink → volume(name=
    "commentary_vol")).
  - All audio chains feed an `audiomixer` element.
  - Output: `appsrc → videoconvert → encoder → h264parse → qtmux
    → filesink` (mirrors Phase 5's compose.rs output chain).
  - **30 Hz output driver** (per Phase 9 fix #17 — preview pinned
    30 fps; export must agree for hash parity). The driver walks
    `plan.entries`: for each entry, walks segments, computes
    `record_time` per output frame, calls `compose_tick(...)`, pushes
    to appsrc with monotonically-increasing PTS.
  - Strokes per frame: `visible_strokes(clip, record_time)` — first
    real consumer of the strokes parameter that's been threaded
    through `compose_tick` since Phase 9.

- UI: a Slint `ExportSheet` component. Modal-ish (full-window
  overlay). Tag list (with all-clips synthetic row prepended), output-
  folder chooser, resolution/quality pickers, Export button, progress
  view. Dispatched via File → Export Compilations menu item.

- Visual parity: Task 6 lands the **full N-frame** preview-vs-export
  hash equality test. Build the same Clip + same source/webcam
  fixtures, run preview pipeline through to N frames captured into a
  Vec<Frame>, run export pipeline through the same N frames captured
  before encode. Hash equal byte-for-byte (or per-pixel within ±2 if
  tolerance is needed).

**Locked-in scope (do not expand):**

1. **Sequential per-tag export** — VideoToolbox saturates on a single
   export; parallelism just adds queue contention without speed-up.
   Mirrors v1's design.
2. **Output codec**: H.264 (matches Phase 5's compose.rs encoder
   pick). HEVC variant noted in design doc for Phase 11; Phase 10
   ships H.264 only.
3. **Progress UI**: indeterminate bar + "Exporting <tag> (N of M)…"
   text. Real progress percentage requires hooking GStreamer's
   position query at 1 Hz; possible but optional in Phase 10. v1
   shipped indeterminate; we match.
4. **No retry / no resume** — export failure surfaces an error,
   removes any partial output, returns to the sheet form. User
   re-clicks Export.
5. **No file-open after export** — v1 has "Reveal in Finder";
   Phase 10 ships a path label + "Reveal in Finder" button on macOS
   only (Linux/Windows show the path label).
6. **Cancel does its best.** GStreamer pipelines don't have an
   instantaneous abort; Cancel sets a flag, the driver checks before
   each frame push, transitions to Null when the flag flips. The
   partial .mp4 is deleted on cancel. Mid-tag cancel kills the
   current tag and skips remaining tags.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; the "Adversarial fixes baked in" section
   below is non-negotiable.
2. `docs/plans/2026-04-28-rust-rewrite-design.md` — architecture
   (Phase 10 entry: line 215 — "Export sheet UI: modal, tag list,
   resolution/quality, batch export").
3. `docs/plans/2026-04-30-rust-rewrite-phase-9-clip-preview.md` —
   especially the **closeout** (Phase 10 prerequisites listed there)
   and fixes #14 (stepped teardown), #17 (30 fps pinned driver),
   #20 (webcam EOS handling), #23 (source decoder seek policy),
   #24 (`compose_tick` is THE entry point), #25 (no per-call
   canonicalize), #26 (frames_pushed counter pattern).
4. `PROGRESS.txt` — Phase 9 SHIPPED 2026-05-01; Phase 10 starts here.
5. v1 reference (port faithfully, NOT verbatim — Rust API differs):
   - `App/Export/ExportSheet.swift` — UI shape (form fields, tag
     row format, sequential run loop, summary view, error alert).
6. Current code:
   - `crates/video-coach-core/src/compilation_plan.rs` — `Project::
     compilation_plan_for(tag, source_durations)` and `Project::
     all_clips_compilation_plan(source_durations)`. Already shipped.
   - `crates/video-coach-core/src/tag_aggregation.rs` —
     `aggregate(project) -> Vec<TagSummary>`. Already shipped.
   - `crates/video-coach-core/src/export_settings.rs` — `bitrate(
     resolution, quality)` and `pixel_size(resolution)`. Already
     shipped.
   - `crates/video-coach-core/src/project.rs` — `Resolution`,
     `Quality`, `Preferences { last_export_resolution,
     last_export_quality, preview_source_volume,
     preview_commentary_volume }`. Already shipped.
   - `crates/video-coach-core/src/timeline.rs` — `playback_segments`,
     `source_time_at`. Already shipped.
   - `crates/video-coach-core/src/stroke_replay.rs` —
     `visible_strokes(clip, t)`. Already shipped.
   - `crates/video-coach-compositor/src/lib.rs` — `compose_tick(
     compositor, source, webcam, strokes)`. Phase 10's export driver
     calls this every frame.
   - `crates/video-coach-media/src/compose.rs` — `compose_two_files`
     is the closest existing analog (single source + single webcam
     → single output .mov). Phase 10's `export.rs` extends this to
     N source videos × M clips × strokes-per-frame, plus the
     audiomixer. Reuse its `build_input_chain` helper.
   - `crates/video-coach-media/src/preview_pipeline.rs` — pattern
     for the 30 Hz driver thread, segment walking, freeze-frame
     pre-decode, `source_time_at` seeks. Phase 10's export driver
     mirrors this minus the FrameSink (export pushes to appsrc).
   - `crates/video-coach-media/src/recording.rs::Recording::stop` —
     pattern for stepped Paused → Ready → Null teardown with state
     waits. Export pipeline's drop/cancel paths must mirror it.
   - `crates/video-coach-app/src/bus.rs` — handler shape, AppMode,
     `is_busy`, `write_recording_state`. Phase 10 extends `is_busy`
     to cover `Exporting`.
   - `crates/video-coach-app/src/frame_sink.rs` — slot pattern for
     UI ↔ bus communication. Phase 10 adds an `ExportProgressSlot`.
   - `crates/video-coach-app/ui/main.slint` — Phase 9's clip sidebar
     + transport bar; Phase 10 adds an export-sheet overlay layered
     on top when active.
   - `crates/video-coach-harness/tests/preview_clip_smoke.rs` —
     pattern for the new `export_smoke.rs` E2E test.

---

## Adversarial-review fixes baked in

The main session ran two adversarial-review passes on this plan; the
fixes are **non-negotiable**. Sub-agent: every one must be present in
shipped code.

> _**To main session writing this plan**: run an adversarial-review
> pass before committing the plan, paste the fixes below, then commit.
> If you skip this and the section stays empty, the sub-agent should
> stop and ask the user._

**1. Event-name namespacing.** Phase 8/9 lesson: the harness's
`wait_for_event` matches by event NAME only, NOT by target. Every
Phase 10 event must have a unique name across the whole codebase.
Suggested namespace:
- `export.batch.started`, `export.batch.completed`,
  `export.batch.failed`, `export.batch.cancelled`.
- `export.tag.started`, `export.tag.completed`, `export.tag.failed`,
  `export.tag.skipped` (e.g. empty plan).
- `export.frame_progress` — emitted every ~1s with `tag`,
  `frame_index`, `total_frames`. Optional; add only if Task 4's
  progress UI needs it.

NEVER reuse `recording.*`, `clip_preview.*`, `clip_recording.*`,
`preview.*`. Add `"export.lifecycle"` to `FORWARDED_TARGETS`; emit
every export event under that target.

**2. Sub-agent prompt sizing (Phase 9 lesson).** Phase 9's per-task
split (Tasks 0 / 1 / 2 / 3+4 / main session) had zero watchdog
timeouts. Phase 8's 3-task prompts hit the watchdog twice. Match
Phase 9's pattern:
- Agent 1: Task 0 (preflight — bus shapes, AppMode::Exporting,
  ExportProgressSlot, FORWARDED_TARGETS).
- Agent 2: Task 1 (export pipeline — biggest single task; deserves
  its own agent).
- Agent 3: Task 2 (bus wiring — pure orchestration, can verify
  against the smoke test from Task 1).
- Agent 4: Task 3 (UI sheet — self-contained Slint work).
- Main session: Tasks 4 + 5 + 6 (harness E2E + parity + closeout).

After every agent: verify locally + push + check CI green BEFORE
dispatching the next.

**3. `compose_tick` is THE entry point — do NOT fork.** Phase 9
shipped `compose_tick(compositor, source, webcam, strokes)` as the
canonical "one tick of preview/export work" function. Phase 10's
export driver MUST call it per frame, NOT call `compositor.compose`
directly. The Phase 9 parity test (`parity_smoke`) locks this down
for Phase 9; Phase 10 extends to N-frame parity (Task 5).

If you find yourself wanting to add an `export_compose` variant for
"performance reasons" or "feature differences", STOP. Funnel any
new behavior through `compose_tick`'s parameters. Phase 10's
encode-side perf optimizations (caching wgpu pipeline rebuild — see
Phase 9 closeout) belong inside `Compositor`, not as a forked path.

**4. Output framerate pinned 30/1 — but driver is encoder-throttled,
NOT wall-clock-pinned.** Phase 9's preview pins driver pace to 30 Hz
*wall-clock* because the user is watching it. For export, we want to
encode AS FAST AS the encoder accepts (often 1-3× realtime on Apple
Silicon, 0.3× on lavapipe). The output framerate is still 30/1, but
the driver pumps frames as fast as appsrc back-pressure allows —
NOT `std::thread::sleep(33ms)` between ticks.

Concretely:
- Input appsinks (source + recording) use `sync=false` (NOT preview's
  `sync=true`). Decoders run as fast as they can.
- Driver loop: pull source frame at deterministic source-time per
  fix #6, pull webcam frame at deterministic record-time, compose,
  push to appsrc. No sleep. The push blocks until appsrc has room
  (back-pressure from encoder).
- Output PTS increments by `1/30 s = 33,333,333 ns` per pushed
  frame regardless of how long compose+encode took.
- A 60 fps source produces a 30 fps output (driver only pulls every
  other source frame deterministically).
- A 24 fps source produces a 30 fps output (some frames repeat in
  the output; driver computes source_time_at(record_time) and
  fetches the corresponding frame).

The encoder's negotiated framerate is 30/1; downstream qtmux
records that as the output framerate.

Why this matters for the parity test (Task 5): both preview and
export must produce *the same composed frame for the same record_
time*. Preview's wall-clock-paced sync=true decode races against
deterministic frame fetching. Per fix #21 below, the parity test
calls a deterministic per-record-time helper, NOT the live preview
pipeline.

**5. Strokes per frame via `visible_strokes(clip, record_time)`.**
The driver knows which entry it's on (and therefore the Clip) plus
the `record_time` within that entry. Call `visible_strokes(&clip,
record_time)` once per frame; pass the resulting `&[VisibleStroke]`
to `compose_tick`. The cost is O(events) per frame which is fine —
typical clips have <100 events.

DO NOT pre-compute strokes-per-frame upfront and stash them. (a)
memory cost; (b) `visible_strokes` already iterates events linearly
so caching adds complexity for no gain.

**6. Source decoder seek policy — same as preview (Phase 9 fix #23).**
The export driver walks segments per entry. Source decoder seeks
ONLY on:
- (a) Entering a new entry's first segment (seek to `entry.
  segments[0].source_start` for that entry's source_index).
- (b) Entering a `Play` segment after a `Freeze` segment within an
  entry.

In steady-state Play (within a Play segment), no per-tick re-seeks.
During Freeze, the driver uses the pre-decoded frozen frame and
ignores the source appsink slot.

**7. Pre-decoded freeze frames per entry — same as preview (Phase 9
fix #6 + #11).** For each `Freeze` segment in each entry, pre-decode
one source frame at `prev_play.source_start +
prev_play.out_duration` (per fix #11). Run pre-decodes in
`spawn_blocking`. Stash as `HashMap<(usize entry_index, usize
segment_index), Frame>`. The export pipeline `open()` blocks the bus
task; bus must wrap it in `spawn_blocking`.

**8. Phase 10 ships RECORDING AUDIO ONLY — no source/commentary
audiomixer.** GStreamer's `audiomixer` aggregates audio sample
timestamps; it has no awareness of the appsrc's video PTS clock.
With per-source independent decoders that play their full real-time
audio, the output .mp4 will have audio that drifts vs the encoder-
throttled video timeline. v1 used AVMutableComposition which
compose-edits audio per-clip-segment; GStreamer in Rust has no
direct equivalent without gst-editing-services (heavyweight) or
per-segment seek+valve gating (complex). 

The simpler path: each entry in the compilation plays the
recording.mov's audio (commentary), no mix. Per entry:
- Recording audio chain: `decodebin's audio pad → audioconvert →
  audioresample → aacenc → qtmux's audio sink-pad.`
- Source audio: not built. (Decodebin's audio pad → fakesink to
  avoid stall, mirrors `compose.rs::build_input_chain`.)

The recording audio is already temporally aligned with the clip's
record_time (Phase 8 captured them together at t0). Cross-entry
boundaries: the recording chain seeks at each entry transition to
that entry's clip's recording.mov starting at 0 (or builds a fresh
recording chain per entry; pick whichever GStreamer handles more
cleanly).

This matches Phase 9 preview's "commentary-only" decision.

Source-volume + commentary-volume MIX is explicitly DEFERRED to
Phase 11 (gst-editing-services migration or per-segment seek+valve
implementation). The deferred items section at the bottom of this
plan documents this.

**9. AppMode::Exporting + Clone, not Copy.** Phase 9 dropped Copy
on AppMode. Adding `Exporting` with no payload (state details ride
on `ExportProgressSlot`) keeps Clone semantics. `is_busy` covers
all non-Scanning modes (Phase 9 already generalized this). For
ExportCompilations specifically:
- If mode is Recording / RecordingStarting → reply with
  `reason="already_recording"`.
- If mode is PreviewClip → reply with `reason="close_preview_first"`.
  The user must explicitly close the preview before exporting (no
  auto-close, mirrors Phase 9 fix #22's "close-then-reopen" UX).
- If mode is Exporting → reply with `reason="already_exporting"`.
- Otherwise (Scanning) → proceed.

The reason strings flow into the `export.batch.failed` event so
the UI's progress slot can display the precise refusal cause.

**10. Cancel mechanism is a polled `Arc<AtomicBool>`.** GStreamer
has no true mid-pipeline abort. `Command::CancelExport` flips a
shared flag; the export driver checks before each frame push and on
entry-boundary transitions. When the flag is set:
- Stop pushing new frames.
- Send EOS to appsrc so qtmux flushes the moov atom — wait, no:
  on cancel we want to DELETE the partial output. Skip the EOS;
  transition pipeline directly to Null (per Phase 8/9 stepped-
  teardown pattern).
- Delete the partial .mp4 file from disk.
- Skip remaining tags in the batch.
- Emit `export.batch.cancelled` with `tags_completed: usize` so
  the UI knows how many tags finished before cancel.

The atomic poll is cheap (~2 ns); per-frame check is fine even at
30 fps × multi-minute exports.

**11. `last_export_resolution` + `last_export_quality` persisted on
Export click, NOT on Done.** Match v1 (ExportSheet line 377-379):
the user almost certainly wants the same settings on retry if the
export fails. Persist before kicking off the run; if persistence
fails, surface and fail closed (don't start the export with
project.json out of sync).

**12. Filename sanitization.** APFS forbids `/` and `:` in
filenames; tag strings can contain either (e.g. "12:30" timestamp
tag). Sanitize via simple substitution: `/` → `-`, `:` → `-`. Mirror
v1's `sanitizeFilename` in ExportSheet.swift line 540.

**Output filename format**: `<tag-sanitized> - <project-name-
sanitized>.mp4`. The "all-clips" synthetic row sanitizes to literal
`all-clips`.

**13. Refuse-to-overwrite vs. delete-first.** v1 deletes silently
(ExportSheet line 428: `try? FileManager.default.removeItem`). For
v2, also delete silently — the user explicitly chose the output
folder + clicked Export, so a same-name file from a prior run is a
re-export, not surprise data loss. (If the user wants both, they
rename the project or change the output folder.)

**14. Stepped teardown on every drop path** (Phase 8/9 lesson).
`ExportPipeline::stop(self)` mirrors `Recording::stop` (NOT relying
on Drop alone): EOS → Paused → Ready → Null with state-waits at
each level. Drop is the panic-path safety net. Cancel skips the
EOS but uses the same stepped state walk.

**15. ONE shared `Arc<Compositor>` for the bus task, reused across
exports.** Phase 9 fix #21 already establishes this for preview;
Phase 10 reuses the same Arc. Wgpu init is non-trivial; sharing
saves ~50-200 ms per export start.

**16. Path resolution: no per-call canonicalize (Phase 9 fix #25).**
The project folder is canonicalized once at OpenProject. Export
paths derive from it: `source_paths[i] = project_folder.join(
project.source_videos[i].relative_path)`, `recording_paths[clip_id]
= project_store::recordings_dir(project_folder).join(clip
.recording_filename)`. NO further `.canonicalize()`.

Output folder: take the user-supplied path verbatim (the file
dialog returns absolute). Validate it exists and is writable; create
it if missing (same as v1 ExportSheet line 385).

**17. `ExportProgressSlot` mirrors `RecordingStateSlot` shape.**
`Arc<Mutex<ExportProgressSlotData>>` carrying `is_active: bool,
total_tags: usize, completed_tags: usize, current_tag: Option<String>,
current_tag_progress: f32 (0..1, optional), errored: Option<String>`.
Bus writes; UI's 30 Hz timer reads. UI converts to display strings.

**18. UI uses Slint's `Dialog` overlay pattern, NOT a separate
window.** v1 uses a SwiftUI sheet (modal-ish). Slint has no sheet
primitive that matches; the cleanest approach is a fullscreen
Rectangle overlay (background dimmed) with the form Card centered.
TouchArea on the dim layer captures clicks-outside; only the close
button + Cancel during run dismisses. Add visibility-gated by an
`in property <bool> export-sheet-visible` — toggled by File → Export
Compilations menu.

When the sheet is visible, key inputs to the rest of the app should
be ignored. Slint's FocusScope handles this if the sheet's outer
Rectangle steals focus on show.

**19. Per-source dedup for the GStreamer pipeline.** A compilation
plan can have multiple clips referencing the same `source_index`.
The export pipeline builds ONE source decoder per unique
source_index (NOT per clip). Each entry's segment-walk uses the
shared decoder. When transitioning between entries that share the
same source_index, the decoder seeks to the new entry's first
segment — no rebuild.

When entries cross source_index boundaries (multi-source projects,
rare in v1), the pipeline tears down the previous source decoder
chain and brings up the next one. v1 likely handled this with
AVMutableComposition's track concatenation; for GStreamer in Rust,
the simpler approach is **one decoder per source_index, all kept
alive in the pipeline; the driver picks which one's appsink slot
to read per entry.** Fully linked, just only one writes useful data
at any time. Memory cost: ~10-50 MB per decoder; tolerable.

**20. Two-stage entry transition.** Between consecutive entries the
driver must:
- (a) Seek the source decoder for the new entry's source_index to
  `entry.segments[0].source_start`.
- (b) Switch the active webcam decoder to the new entry's clip's
  `recordingFilename` recording. (Each clip has its own webcam
  decoder; same dedup applies if multiple entries reference the
  same clip — extremely unlikely but tolerated.)
- (c) Reset the pre-decoded freeze frames lookup to the new entry's
  `HashMap<usize segment_index, Frame>`.
- (d) Reset the per-entry `record_time` cursor to 0.
- (e) The output PTS continues monotonically from where the
  previous entry left off; do NOT reset it. (This is the whole
  point of `composition_start` in `CompilationEntry`.)

Document this transition explicitly in the driver code with
comments. Easy to get subtly wrong.

**21. N-frame parity test architecture (Task 5).** Mirror Phase 9's
single-frame `parity_smoke.rs` but for a real Clip:
- Construct a single hand-rolled `Clip` with Pause + Play + a
  stroke event so segments and strokes both exercise.
- Build minimal `CompilationPlan` with one entry.
- Run preview pipeline through a `CountingFrameSink` that captures
  every frame as `Vec<Frame>`. Stop at frame N.
- Run export pipeline (or just its driver loop, refactored to
  expose a hook) producing Vec<Frame> via the SAME `compose_tick`
  call. NOT going through encoder + decoder + readback — just the
  composed RGBA frames before encode. Otherwise H.264 lossy
  compression eliminates byte-equality.
- Both vectors must be byte-equal.

Refactor required: the export driver's per-tick "compose + push
to appsrc" loop must factor out the compose-only inner part so the
parity test can call it without GStreamer plumbing. Same shape as
the `compose_tick` extraction in Phase 9 — likely a `fn
compose_entry_frame(compositor, plan_entry, clip, frame_index,
source_frames_by_index, webcam_frame, frozen_frames) -> Frame`
helper exported from `export.rs`.

**22. Cancel during pre-decode.** Pre-decoding freeze frames is in
`spawn_blocking` and may take 100-800 ms per freeze on long-GOP
sources. If Cancel arrives during pre-decode, the pre-decode loop
must check the cancel flag and exit early. Same `Arc<AtomicBool>`
as the per-frame check.

**23. Frame counter on `export.tag.completed`.** Mirror Phase 9
fix #26: the export driver carries an `Arc<AtomicU64>` frame counter;
on `export.tag.completed` emit `frames_pushed` so the harness E2E
test can assert it's > 0 and roughly matches expected (≈ entry
durations × 30). Catches the entire class of "encoder pipeline ran
but produced no useful output" regressions.

**24. Sequential not concurrent across tags.** For the bus task: the
ExportCompilations handler loops tags one at a time, awaiting each
spawn_blocking. NEVER `join_all` over tags. Reasoning: hardware
encoders (vtenc_h264, mfh264enc) saturate on a single export; queue
contention on parallel runs makes total wall time worse, not better.
Plus the cancel flag works cleanly only if there's exactly one in-
flight export.

**25. Resolution::Source means "use the source's natural size,
matching the first source's pixel size".** v1 design: Source
resolution copies the first source's `naturalSize`. With multi-
source projects, that means later sources may need scaling — but
v1's note says "source videos are landscape-only" so all sources
are 16:9. For Phase 10 we keep the same constraint: all sources
must be 16:9 and the first source's natural size is the output
size.

`pixel_size(Resolution::Source)` returns the special sentinel value
in `export_settings.rs`; check that and substitute the first
source's `(width, height)` resolved via `Discoverer` (or stash on
SourceRef during AddSourceVideo? — easier to just probe at export
time). This is a small Phase 1+ concern; either is fine.

**26. Empty-plan handling per fix in v1.** A ticked tag with zero
matching clips emits `export.tag.skipped` with reason="empty_plan"
and proceeds to the next tag. Don't crash; don't delete the output
folder; just skip and continue. v1 ExportSheet line 420.

**27. Multi-source decoder state — Pause-inactive / Play-active.**
"All decoders kept alive in one pipeline, only one writes useful
data" is NOT a valid GStreamer state — inactive `sync=false`
appsinks free-run and exhaust memory; `sync=true` appsinks back-
pressure decodebin's multiqueue and stall the GStreamer task
scheduler. Phase 10 implementation:
- Build all source decoder chains in the pipeline (one per unique
  source_index in the plan).
- Set the pipeline state to PAUSED initially. All chains are
  paused.
- Set the *active* chain (the one for the current entry's source_
  index) to PLAYING via `Element::set_state(Playing)` on the
  filesrc/decodebin/videoconvert/appsink. Inactive chains stay
  PAUSED.
- On entry boundary if source_index changes: PAUSED on old, PLAYING
  on new + seek to new entry's first segment source_start.

For most projects there's only ONE source_index, so this is a no-
op (the single chain is always Playing). For multi-source
projects, the cross-entry pause/seek/play sequence costs ~50-200ms
per transition — acceptable.

Webcam (recording.mov) chains: same pattern. One per unique clip
in the plan (typically all entries are unique clips, so N chains
for an N-entry plan). Active chain Playing, others Paused. Switch
on entry boundary.

**28. Compositor-output-size + videoscale stage — appsrc caps NOT
pinned to target resolution.** `Compositor::compose` outputs at
SOURCE size (it copies source.width / source.height to the render
target). Pinning the appsrc capsfilter to `pixel_size(resolution)`
breaks negotiation when source isn't already that size. Pipeline
shape:
```
appsrc(caps=source-w×source-h, RGBA, 30/1)
  → videoconvert
  → videoscale
  → capsfilter(caps=target-w×target-h, NV12, 30/1)  // resolution applied here
  → encoder
  → h264parse → qtmux → filesink
```
The videoscale handles aspect-preserving downscale; videoconvert
handles RGBA→NV12. Pin appsrc caps to the *source*'s actual width
and height + 30/1 framerate. Pin the post-scale capsfilter to
target dimensions. The driver doesn't need to know the target
size; it just pushes source-sized RGBA buffers.

For Phase 10's "all sources are 16:9" constraint, aspect ratio
matches automatically; videoscale just downscales linearly.

**29. `Resolution::Source` requires probing the first source's
dimensions at export time.** `pixel_size(Resolution::Source)`
returns the sentinel value `1920×1080` (not the source's actual
size — the comment in export_settings.rs says the export pipeline
overrides). Task 1 must:
- For `resolution == Resolution::Source`: probe the first
  `source_paths` entry via `gstreamer_pbutils::Discoverer` to get
  natural width × height. Use those for the post-scale capsfilter.
- For `R1080` / `R720`: use `pixel_size(resolution)` directly.

Probing adds ~50-200ms to export start; acceptable. Cache the
probed value across tags within one batch (it doesn't change).

**30. Cancel during pre-decode — flag-check between freezes, NOT
mid-decode.** `decode_one_frame_at` (the per-Freeze decoder) is one
synchronous `set_state(Paused) → state(timeout=5s) → seek →
state(timeout=5s) → pull_preroll` sequence. The 5s state-wait can't
be aborted mid-call without leaking a half-built pipeline. Cancel
discipline:
- The pre-decode loop iterates over (entry, freeze_segment)
  pairs.
- Check `cancel.load(Acquire)` at the top of each iteration.
- If set: drop any half-built pre-decode pipeline (its Drop runs
  the safety teardown), return `Err(ExportError::Cancelled)`.
- Mid-iteration cancel waits up to ~5s for the in-flight
  decode_one_frame_at to complete before returning. Acceptable;
  document explicitly.

**31. Filename sanitization — Windows + reserved names.** v1 was
macOS-only. Phase 10's CI matrix includes Windows. Sanitize:
- Replace `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|` with `-`.
- Trim leading/trailing whitespace + dots.
- If the result (case-insensitive) matches a Windows reserved
  name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`),
  prefix with `_` (e.g. `con` → `_con`).
- If the result is empty after sanitization, fall back to
  `untitled`.

Add unit tests in `crates/video-coach-app/src/bus.rs` (or
wherever the helper lands).

**32. Slint sheet focus discipline + Escape + click-outside.**
The plan's Task 3 originally said "FocusScope handles this if the
sheet's outer Rectangle steals focus on show" — Slint's FocusScope
does NOT auto-steal focus on visibility change. Explicit:
- Sheet's outer Rectangle contains a `FocusScope` named
  `sheet-focus-scope`.
- When `export-sheet-visible` becomes true, call
  `sheet-focus-scope.focus()` (Slint exposes this on FocusScope).
  Either via a Slint `changed` callback or explicitly from ui.rs
  in the on-File-menu-Export handler.
- The existing top-level `keyscope` FocusScope's key handler gates
  ALL existing shortcuts (Space / R / Esc / arrow keys) on
  `!root.export-sheet-visible`. Without the gate, pressing R while
  the sheet is open starts a clip recording.
- Sheet's FocusScope handles Escape: dispatches
  `export-close-clicked()` (which sets visible=false + clears
  state).
- Click-outside (TouchArea on the dim layer): closes the sheet
  ONLY if `!export-active && !exporting-error-displayed` —
  otherwise no-op. Standard sheet UX: can't accidentally dismiss
  a running export.

**33. Typed `TagSelection` enum in `Command::ExportCompilations`,
NOT `Vec<String>`.** The `__all-clips__` magic string would collide
with a real user tag (current schema: `Tag = String`, no
restrictions on contents). Replace:
```rust
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TagSelection {
    AllClips,
    Tag { name: String },
}

// In Command:
ExportCompilations {
    selections: Vec<TagSelection>,
    ...
}
```
The bus dispatches on the variant, not a string. UI sends the
appropriate variant per row (the synthetic "all-clips" row →
`AllClips`; a real tag row → `Tag { name: "..." }`).

**34. ExportProgressSlotData distinguishes success-summary from
error-state.** Per the reviewer's nit: a 5-tag batch where tags
1-3 succeed and tag 4 fails should NOT show "Wrote 3 file(s)" as
if the run completed. Slot shape:
```rust
pub enum ExportRunOutcome {
    None,                                      // never run
    InProgress,                                // batch active
    SucceededAll { folder: PathBuf, tag_count: usize },
    PartialFailure { folder: PathBuf, completed: usize, failed_tag: String, error: String },
    Cancelled { folder: PathBuf, completed: usize },
}

pub struct ExportProgressSlotData {
    pub outcome: ExportRunOutcome,
    pub current_tag: Option<String>,           // populated when InProgress
    pub completed_tags: usize,                 // running count, also for InProgress
    pub total_tags: usize,                     // total in batch
}
```
The UI's three-state form/progress/summary view becomes a four-
state via the outcome enum. `SucceededAll` shows the green summary
+ Reveal. `PartialFailure` shows a red error with the failed tag
name + Done button (user can re-open File→Export to retry).
`Cancelled` shows a neutral "cancelled, N tags written" + Done.

---

## Tasks (~7 total — split across 4-5 sub-agent dispatches per fix #2)

### Task 0: Preflight — bus shapes + AppMode::Exporting + ExportProgressSlot

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`.
- Modify: `crates/video-coach-app/src/event_layer.rs`.
- Modify: `crates/video-coach-app/src/frame_sink.rs`.
- Modify: `crates/video-coach-app/src/main.rs`.

**Add to `Command`** (per fix #33):
```rust
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TagSelection {
    AllClips,
    Tag { name: String },
}
```
Then:
- `ExportCompilations {
    selections: Vec<TagSelection>,
    output_folder: String,
    resolution: video_coach_core::project::Resolution,
    quality: video_coach_core::project::Quality,
    project_name: String,
  }`.
- `CancelExport`.

Stub handlers return "not yet implemented (phase 10 task 2)".

**`AppMode` gains `Exporting` variant** (no payload — state details
ride on `ExportProgressSlot`). Keep `Clone`, NOT `Copy`. Update
`is_busy` to return true for `Exporting` (per fix #9 + #22).

**`RecordingMode` mirror in frame_sink.rs gains `Exporting` variant.**
Update `bus::write_recording_state` to map `AppMode::Exporting` →
`RecordingMode::Exporting`.

**`FORWARDED_TARGETS` gains `"export.lifecycle"`** (per fix #1).

**`ExportProgressSlot` (per fix #17 + #34)**:
```rust
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub enum ExportRunOutcome {
    None,
    InProgress,
    SucceededAll { folder: PathBuf, tag_count: usize },
    PartialFailure { folder: PathBuf, completed: usize, failed_tag: String, error: String },
    Cancelled { folder: PathBuf, completed: usize },
}

impl Default for ExportRunOutcome {
    fn default() -> Self { Self::None }
}

#[derive(Debug, Clone, Default)]
pub struct ExportProgressSlotData {
    pub outcome: ExportRunOutcome,
    pub current_tag: Option<String>,            // populated when InProgress
    pub completed_tags: usize,                  // running count, also for InProgress
    pub total_tags: usize,                      // total in batch
}
pub type ExportProgressSlot = Arc<Mutex<ExportProgressSlotData>>;
pub fn new_export_progress() -> ExportProgressSlot { ... }
```

Thread the slot through `bus::spawn_on` and `ui::run` signatures.
Wire it in `main.rs`.

**Bus also gains `current_export_cancel: Option<Arc<AtomicBool>>`** —
held while an export is running, set to true by `CancelExport`,
checked by the driver in `export.rs`.

**Bus serde tests**: `export_compilations_serde_roundtrips`,
`cancel_export_serializes_to_bare_tag`, `app_mode_exporting_
serializes_with_snake_case`, `tag_selection_all_clips_serializes`,
`tag_selection_tag_with_name_serializes`,
`tag_selection_round_trips_through_command`.

**Filename sanitization helper** (per fix #31): write
`fn sanitize_filename(s: &str) -> String` in a small module
(probably `bus.rs` or a new `filename.rs`). Cover Windows reserved
names + illegal chars + empty-fallback. Add unit tests.

**Update PROGRESS.txt** with a Phase 10 section + Task 0 row marked
shipped + commit SHA.

---

### Task 1: Export pipeline — `crates/video-coach-media/src/export.rs`

**Files:**
- Create: `crates/video-coach-media/src/export.rs`.
- Modify: `crates/video-coach-media/src/lib.rs` (cfg-gate behind
  `media`).
- Create: `crates/video-coach-media/tests/export_smoke.rs`.

**API:**
```rust
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use video_coach_compositor::Compositor;
use video_coach_core::compilation_plan::CompilationPlan;
use video_coach_core::project::{Clip, Quality, Resolution};

pub struct ExportInputs {
    pub plan: CompilationPlan,
    pub clips_by_id: std::collections::HashMap<uuid::Uuid, Clip>,
    pub source_paths: std::collections::HashMap<usize, PathBuf>,
    pub recording_paths: std::collections::HashMap<uuid::Uuid, PathBuf>,
    pub source_durations: std::collections::HashMap<usize, f64>,
}

#[derive(Debug, thiserror::Error)]
pub enum ExportError { /* MissingElement, StateChange, Construction,
    Compositor, Cancelled, Io, ... */ }

pub fn export_compilation(
    inputs: ExportInputs,
    output_path: &Path,
    resolution: Resolution,
    quality: Quality,
    source_volume: f64,
    commentary_volume: f64,
    compositor: Arc<Compositor>,
    cancel: Arc<AtomicBool>,
    on_progress: Box<dyn Fn(ExportProgress) + Send + Sync>,
) -> Result<ExportSummary, ExportError>;

pub struct ExportProgress {
    pub frames_pushed: u64,
    pub frame_index: u64,
    pub total_frames: u64,
    pub current_entry_index: usize,
}

pub struct ExportSummary {
    pub frames_pushed: u64,
}
```

**Inside the function:**

1. **Probe first source's natural dimensions** (per fix #29) for
   `Resolution::Source`. For other resolutions use
   `pixel_size(resolution)`. Stash as `output_size`.
2. **Pre-decode freeze frames per entry** (per fix #7 + #30). Run
   inline; the bus task wraps the entire `export_compilation` call
   in `spawn_blocking`. Check cancel flag at each (entry,
   freeze_segment) iteration boundary.
3. Build per-source-index decoder chains, all with `appsink.sync=
   false` (per fix #4 — encoder-throttled driver, NOT wall-clock-
   paced). Reuse `compose.rs::build_input_chain` shape if the
   helper signature matches; otherwise inline. All chains start
   in PAUSED state per fix #27.
4. Build per-clip webcam decoder chains (one per unique clip in
   plan). Each chain includes the recording's audio path:
   `decodebin's audio → audioconvert → audioresample → aacenc`,
   linked to qtmux's audio sink-pad. Per fix #8: NO audiomixer,
   NO source-vol/commentary-vol mix in Phase 10. Recording audio
   only.
5. Build the output chain (per fix #28):
   ```
   appsrc(caps=source-w × source-h, RGBA, 30/1)
     → videoconvert
     → videoscale
     → capsfilter(caps=output-w × output-h, NV12, 30/1)
     → encoder(picked)
     → h264parse
     → qtmux
     → filesink
   ```
   Encoder bitrate from `bitrate(resolution, quality)`. The
   appsrc receives source-sized RGBA buffers; videoconvert +
   videoscale handle the output transform.
6. Set pipeline state to PLAYING. Audio chains begin streaming
   (paused chains stay quiet via fix #27's per-element state
   control).
7. Activate the first entry's source + clip chains:
   `source_chain[entry.source_index].set_state(Playing)`,
   `webcam_chain[entry.clip_id].set_state(Playing)`. Seek both
   to entry start. Other chains remain Paused.
8. **Driver loop**: per-entry, walk segments, compose each output
   frame, push to appsrc as fast as encoder accepts. NO wall-clock
   pacing. The encoder's back-pressure naturally throttles us.
   - Check cancel flag at the top of each loop iteration (per
     fix #10). On cancel: break out, skip EOS, transition Null,
     delete output, return `Cancelled`.
   - Compute `record_time` from the per-entry cursor (cumulative
     `frame_index_in_entry × 33,333,333 ns`).
   - Resolve segment via `source_time_at(clip, record_time)` +
     a segment walker (mirror `preview_pipeline.rs`'s segment
     resolver).
   - Pull source frame: for Play segments, fetch from active
     source chain's appsink slot; for Freeze segments, use cached
     pre-decoded frozen frame.
   - Pull webcam frame: latest in active webcam chain's appsink
     slot.
   - Compute `visible_strokes(&clip, record_time)` (per fix #5).
   - Call `compose_tick(&compositor, &source_frame, &webcam_frame,
     &strokes)` (per fix #3).
   - Push composed RGBA to appsrc with PTS =
     `composition_start_ns + frame_index_in_entry × 33_333_333_ns`
     and duration = `33_333_333_ns`. PTS is monotonic across
     entries.
   - Increment `frames_pushed`.
   - Emit `on_progress` callback every ~30 frames.
9. **Entry transitions** (per fix #20):
   - Pause the previous entry's source + webcam chains (per fix
     #27). If the next entry uses the same source_index, KEEP
     the source chain Playing and just seek; pause the previous
     webcam chain and play the next one.
   - Resolve `frozen_frames` lookup for the new entry.
   - Reset per-entry record_time cursor to 0. composition_start_ns
     advances by `prev_entry.recording_duration × 1e9`.
10. **End-of-batch**: send EOS to appsrc, wait for filesink EOS
    via bus message, transition to Null per fix #14 (stepped
    Paused → Ready → Null).
11. **Cancel path**: skip EOS, transition Null directly, delete
    output file, return `ExportError::Cancelled`.

**`compose_entry_frame` helper** (exported, for fix #21's parity
test):
```rust
pub fn compose_entry_frame(
    compositor: &Compositor,
    entry: &CompilationEntry,
    clip: &Clip,
    record_time: f64,
    source_frame: &Frame,
    webcam_frame: &Frame,
    frozen_frames: &HashMap<usize, Frame>,
) -> Result<Frame, ExportError>;
```
Pure function: resolves the segment for `record_time`, picks
source vs frozen frame, computes strokes, calls `compose_tick`.
The driver loop calls this; Task 5's parity test calls this too,
feeding hand-rolled inputs. NO GStreamer in this function.

**Smoke test** (`tests/export_smoke.rs`):
- Build a Clip + plan with 1 entry + Pause/Play + 1 stroke event.
- Call `export_compilation` against fixture source + recording.
- Assert: output .mp4 exists, file size > 50 KB, ffprobe duration
  ≈ clip.recording_duration ± 0.1s, video framerate is 30/1.
- Cancel test: spawn a thread that sets the cancel flag after
  100 ms, assert `export_compilation` returns `Err(ExportError::
  Cancelled)` and the output file is absent.

**Update PROGRESS.txt + commit.**

---

### Task 2: Bus wiring — `ExportCompilations` / `CancelExport` handlers

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`.

**`ExportCompilations` handler**:
1. Validate inputs (selections non-empty, output_folder non-empty,
   project_name non-empty after trim).
2. Refuse if `is_busy` per fix #9: emit `export.batch.failed`
   with the matching reason string (`already_recording`,
   `close_preview_first`, `already_exporting`). Reply ok=false +
   error.
3. Refuse if no project open: reply with `no_project_open`.
4. Resolve all paths from `current.0` (project) + folder per fix
   #16. Build `ExportInputs::source_paths` (deduplicate by
   source_index per fix #27 + #19), `recording_paths` (per clip).
5. **Persist `project.preferences.last_export_resolution` +
   `last_export_quality` per fix #11 — AFTER step 2's busy check
   and step 3's no-project check** (per the second-pass review's
   M9 fix). If persistence fails, emit `export.batch.failed` with
   `reason="persist_prefs_failed"` and abort BEFORE setting up the
   export.
6. Create output folder if missing (`std::fs::create_dir_all`).
6. Set `current_mode = AppMode::Exporting`. Build cancel flag.
   Stash `current_export_cancel = Some(flag.clone())`.
7. Update `ExportProgressSlot` with
   `outcome=InProgress, total_tags=selections.len(),
   completed_tags=0`.
8. Emit `export.batch.started` with `tag_count=selections.len()`,
   `output_folder`, `resolution`, `quality`.
9. **Sequential loop** per fix #24: for each `selection` in supplied
   order (UI sends them sorted; bus doesn't re-sort):
   - Resolve display label and plan via TagSelection (per fix #33):
     - `TagSelection::AllClips` → label `"all-clips"`, plan via
       `project.all_clips_compilation_plan(source_durations)`.
     - `TagSelection::Tag { name }` → label `name`, plan via
       `project.compilation_plan_for(&name, source_durations)`.
   - If plan is empty, emit `export.tag.skipped` with
     `reason="empty_plan"` per fix #26 and continue.
   - Sanitize filename per fix #31 (Windows-safe): apply
     `sanitize_filename` to both the label and the project_name.
     Build output path: `<output_folder>/<sanitized-label> -
     <sanitized-project-name>.mp4`.
   - Delete prior output file silently per fix #13.
   - Update slot (`current_tag = Some(tag.clone()), completed_tags=
     i`).
   - Emit `export.tag.started`.
   - Call `export_compilation(...)` in `spawn_blocking`. Pass the
     SHARED `Arc<Compositor>` per fix #15.
   - On success: emit `export.tag.completed` with `frames_pushed`
     per fix #23. Increment `completed_tags`.
   - On `ExportError::Cancelled`: break out of the loop. Emit
     `export.batch.cancelled` with `tags_completed=completed`.
   - On other error: emit `export.tag.failed` with `error`.
     Update slot (`last_error`); break the loop, emit `export.
     batch.failed`.
10. End-of-batch outcome write per fix #34:
    - All tags succeeded → `outcome = SucceededAll { folder,
      tag_count: completed }`. Emit `export.batch.completed`.
    - Cancel flag set → `outcome = Cancelled { folder,
      completed }`. Emit `export.batch.cancelled` with
      `tags_completed=completed`.
    - One tag failed → `outcome = PartialFailure { folder,
      completed, failed_tag, error }`. Emit `export.batch.failed`.
    - Clear `current_export_cancel`. Set `current_mode =
      AppMode::Scanning`. `write_recording_state(...)` to mirror
      the mode change (per Phase 9 pattern).

**`CancelExport` handler**:
1. Refuse if mode isn't `Exporting`.
2. `current_export_cancel.as_ref().map(|f| f.store(true,
   Release))`. The flag flip is the entire user-visible action;
   the driver picks it up next tick.
3. Reply ok=true. (The driver's `Cancelled` error rolls the slot/
   mode transitions; no further state mutation here.)

**Bus task gains**:
- `current_export_cancel: Option<Arc<AtomicBool>>`.
- `compositor: Arc<Compositor>` is already shared with preview;
  reuse it.

**Update PROGRESS.txt + commit.**

---

### Task 3: UI — Export sheet modal

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`.
- Modify: `crates/video-coach-app/src/ui.rs`.

**Slint additions:**
- New properties: `in property <[{tag: string, label: string,
  clip-count: int, duration: float}]> export-tag-rows: [];`,
  `in-out property <[string] selected-export-tags: [];`,
  `in-out property <string> export-output-folder: "";`,
  `in-out property <string> export-resolution: "1080";` (one of
  `"source"`, `"1080"`, `"720"`),
  `in-out property <string> export-quality: "medium";` (one of
  `"low"`, `"medium"`, `"high"`),
  `in-out property <string> export-project-name: "";`,
  `in property <bool> export-active: false;` (mode == "exporting"),
  `in property <int> export-total-tags: 0;`,
  `in property <int> export-completed-tags: 0;`,
  `in property <string> export-current-tag: "";`,
  `in property <string> export-error: "";`,
  `in property <string> export-summary-folder: "";`,
  `in property <int> export-summary-file-count: 0;`.

- New property `in-out property <bool> export-sheet-visible: false;`
  toggled by File → Export Compilations menu item (a new MenuItem)
  and the close button.

- New callbacks: `export-folder-pick-clicked()`,
  `export-tag-toggled(string)`, `export-select-all-clicked()`,
  `export-select-none-clicked()`, `export-resolution-changed(string)`,
  `export-quality-changed(string)`, `export-start-clicked()`,
  `export-cancel-clicked()`, `export-close-clicked()`,
  `export-reveal-clicked()`.

- The sheet itself is a fullscreen Rectangle overlay (background
  `#000000` at 50% opacity to dim the rest of the app), with a
  centered Card Rectangle containing the form. Visibility gated
  on `export-sheet-visible`. When visible, the underlying clip
  sidebar/transport are still rendered but unclickable (TouchArea
  on the dim layer absorbs clicks).

- **Focus discipline (per fix #32)**:
  - Sheet's outer Rectangle holds a named `sheet-focus-scope`
    FocusScope. `ui.rs` calls `.focus()` on it when the sheet
    becomes visible (handler on the File menu Export item, OR a
    Slint `changed` callback on `export-sheet-visible`).
  - Top-level `keyscope`'s key handler gates ALL existing shortcuts
    (Space, R, arrow keys) on `!root.export-sheet-visible`. Esc
    still propagates — it's the close-sheet shortcut.
  - Sheet `sheet-focus-scope` handles Esc → fires
    `export-close-clicked()`.
  - Click-outside (TouchArea on the dim layer) closes the sheet
    ONLY if the sheet's outcome state is Form, SucceededAll, or
    PartialFailure (NOT InProgress — can't accidentally dismiss
    a running export).

- **Four outcome states** (per fix #34, derived from
  `ExportProgressSlot.outcome`):
  - **Form** (`outcome == None`): project name, output folder,
    tag list, resolution/quality pickers, "Cancel" + "Export"
    buttons. Cancel here = close the sheet (no export in flight).
  - **Progress** (`outcome == InProgress`): "Exporting <tag>
    (N of M)…", indeterminate spinner, "Cancel" button. Cancel
    here = dispatches `Command::CancelExport`.
  - **Success summary** (`outcome == SucceededAll { folder,
    tag_count }`): "Wrote N file(s) to <folder>", "Reveal in
    Finder" button (per fix #N15 — see below), "Done" button.
  - **Error / partial** (`outcome == PartialFailure { folder,
    completed, failed_tag, error }` OR `Cancelled`): red error
    text with the failed tag's name + folder path + error
    message; "Done" button. User clicks Done, sheet returns to
    Form state for retry.

- **Reveal-in-Finder cross-platform** (per fix #N15):
  - macOS: `Command::new("open").arg(&folder).status()` (no `-R`
    flag — that reveals a file; for folders use plain `open`).
  - Windows: `Command::new("explorer").arg(&folder).status()`.
    For revealing a specific file (not used in Phase 10 since
    we batch-write multiple files): `explorer /select,<path>`.
  - Linux: `Command::new("xdg-open").arg(&folder).status()`.

  cfg-gated dispatch in `ui.rs::on_export_reveal_clicked`. If the
  command spawn fails (no xdg-open on minimal distros), log a
  warning + leave the path label visible for the user to copy.

**ui.rs additions:**
- New 30 Hz timer reads from `ExportProgressSlot` and updates
  Slint properties.
- Tag-list hydration: read from `ClipListSlot` + compute tags via
  `tag_aggregation::aggregate(project)` — wait, the bus task
  doesn't currently expose the live project to the UI directly.
  Either:
    - (a) Bus task writes a separate `TagListSlot` populated
      whenever clips change. Probably the cleanest. Add this in
      Task 0 or Task 2 — pick one and document.
    - (b) Compute tag aggregation in the UI from `ClipListSlot` —
      but `ClipSummary` doesn't carry tags. Would need to extend
      `ClipSummary` with `tags: Vec<String>`.
  - **Pick (b)**: extend `ClipSummary` with `tags: Vec<String>` in
    Task 0. Cheaper, keeps the bus simpler. Update Task 0's
    `write_clip_list` helper to populate tags.

- Callback handlers:
  - `export-start-clicked`: collect `selected-export-tags`,
    `export-output-folder`, etc., dispatch
    `Command::ExportCompilations`.
  - `export-cancel-clicked`: dispatch `Command::CancelExport`.
  - `export-folder-pick-clicked`: open `rfd::FileDialog::new()
    .pick_folder()`, write to `export-output-folder` property.
  - `export-tag-toggled(tag)`: toggle membership in
    `selected-export-tags`.
  - `export-reveal-clicked`: on macOS, spawn `open -R <folder>`;
    other platforms just no-op or open the folder.
  - `export-close-clicked`: set `export-sheet-visible = false`,
    reset summary state if the sheet is in summary state.

**File menu:**
Add `MenuItem { title: "Export Compilations…"; activated => {
root.export-sheet-visible = true; } }`. Disable when no project is
open (gated on a `project-open: bool` property — which the UI
already has via `project-title != "No project open"` but a clean
boolean is better).

**Update PROGRESS.txt + commit.**

---

### Task 4: Harness E2E — record + tag + export + verify

**Files:**
- Create: `crates/video-coach-harness/tests/export_smoke.rs`.

**Test flow:**
1. Open temp project + add a fixture source video.
2. Use `--fixture-recording-source` to record a 1.5s clip.
3. Skip clip-tagging — use the `TagSelection::AllClips` variant
   (per fix #33). This avoids needing a new `SetClipTags` bus
   command in Phase 10's scope.
4. Set the project's output preferences (`last_export_resolution =
   r720` for speed) by hand-writing project.json — or just use
   defaults.
5. Send `Command::ExportCompilations { selections:
   vec![TagSelection::AllClips], output_folder:
   tmp.path().to_string(), resolution: R720, quality: Low,
   project_name: "test".into() }`.
6. Wait for `export.batch.started` (timeout 5s).
7. Wait for `export.tag.started` with `selection_kind="all_clips"`.
8. Wait for `export.tag.completed` (timeout 60s — Windows
   mfh264enc cold-start can take 5-10s and lavapipe runs 0.3-0.5×
   realtime, so a 1.5s clip can take 5-15s of GPU work plus
   stepped teardown). Assert `frames_pushed >= 30` (a 1.5s clip
   at 30 fps produces ~45 frames; allow >= 30 for safety).
9. Wait for `export.batch.completed`.
10. Verify `<tmp>/all-clips - test.mp4` exists, size > 50 KB.
11. ffprobe-equivalent (use `gstreamer_pbutils::Discoverer`) to
    verify duration ≈ 1.5s and video framerate = 30/1.
12. Quit cleanly.

**Cancel test** (separate `#[test]`):
- Same setup through step 7.
- Sleep 100 ms (let the export start producing frames).
- Send `Command::CancelExport`. Assert reply ok=true.
- Wait for `export.batch.cancelled`. Assert `tags_completed=0`.
- Verify the output file is absent (deleted on cancel per fix #10).
- Quit.

**Update PROGRESS.txt + commit.**

---

### Task 5: Full N-frame parity via deterministic `compose_entry_frame`

**Files:**
- Create: `crates/video-coach-media/tests/parity_n_frames.rs`.

Per fix #21 (revised): the parity test does NOT compare preview's
live-decoded frames against export's. Preview's `appsink.sync=true`
real-time decode produces a *race* against the deterministic frame-
by-record-time path — same clip can produce different captured
frames at preview-tick N depending on decoder warmup, GPU clock
state, etc.

The right contract: **`compose_entry_frame` is deterministic given
the same inputs.** Both preview's driver and export's driver call
it. The parity test calls it twice over N record_times and asserts
the two output sequences match.

Test architecture:
1. `let compositor = Arc::new(Compositor::new_headless()?)`.
2. Build a hand-rolled `Clip` with Pause + Play + a stroke event.
3. Build a `CompilationPlan` with one entry referring to that
   clip.
4. Pre-decode fixture source frames at the segment-relevant
   source_times into a `HashMap<f64, Frame>` (test scaffold —
   doesn't need to live in production code).
5. Hand-roll a webcam Frame (solid color, fixed dimensions).
6. Resolve the entry's freeze-frame map per fix #11 logic.
7. **Path A**: loop record_time from 0 to N×33.3ms, call
   `compose_entry_frame(&compositor, &entry, &clip, record_time,
   &source_frame, &webcam_frame, &frozen_frames)`. Collect into
   `Vec<Frame>`.
8. **Path B**: same loop, same inputs. Collect into Vec<Frame>.
9. Assert `path_a == path_b` byte-for-byte for all N frames.

If byte-for-byte proves flaky (wgpu pipeline cache state across
back-to-back composes — Phase 9 closeout flagged this), downgrade
to ±2/channel tolerance per sampled pixel.

**N=30** (1 second of preview at 30 fps) is sufficient for catching
divergence regressions; longer runs hit diminishing returns. If
the future Phase 11 adds an end-to-end "render preview to file +
render export to file + bit-compare the two .mp4s" check, that's a
fundamentally different test and lives separately.

**This rework removes the architectural infeasibility flagged in
Phase 10's adversarial review** (preview's sync=true real-time
decode vs export's deterministic walk).

**Update PROGRESS.txt + commit.**

---

### Task 6: Closeout

- Run the full verification battery (build × 3 feature flavors,
  test × default + media, clippy × 2, fmt). Per Phase 9 lesson:
  ALWAYS `cargo build --workspace --features media` BEFORE
  `cargo test --workspace --features media` — cargo's incremental
  feature unification can leave a stale binary that fails harness
  tests.
- `git push` + verify CI green via `gh run list --branch rust-rewrite
  --limit 1` AND `gh run view <id> --json conclusion,status,jobs`.
- Append a closeout section at the bottom of THIS plan file:
  commits table, adversarial-fix verification, deferred items
  (HEVC encoder, real progress percentage, source-vol-mix in
  preview).
- Mark Phase 10 SHIPPED in PROGRESS.txt with the final CI run id.

---

## What Phase 10 deliberately does NOT include

- **HEVC output codec.** Phase 10 ships H.264 only (matches Phase 5's
  encoder pick). Phase 11's "polish + packaging" picks up HEVC +
  hardware encoder selection refinement.
- **Real progress percentage.** Indeterminate progress only; v1
  shipped indeterminate; we match. A future patch could query
  GStreamer position at 1 Hz and turn that into a 0..100% bar.
- **Resume failed exports.** Failure deletes the partial output
  and returns to the form. No mid-export checkpointing.
- **Drag-to-reorder tag rows in the export list.** Sorted
  alphabetically (after the "all-clips" pinned row); v1 same.
- **Custom output filename templates.** Filename format is fixed:
  `<tag-sanitized> - <project-name-sanitized>.mp4`. v1 same.
- **Source-volume + commentary-volume MIX entirely.** Phase 10
  ships RECORDING AUDIO ONLY in export (per fix #8). v1's dual-
  slider mix requires per-entry audio segment editing
  (gst-editing-services or seek+valve gating) which is its own
  scope. Phase 11 picks up the mix.

- **Per-frame compose caching during Freeze segments.** Within a
  Freeze segment, every output frame composes the same source +
  webcam (modulo strokes). The redundant GPU work is acceptable
  for Phase 10; Phase 11 follow-up could memoize per (Freeze
  segment, stroke set hash).

---

## Known performance risks (acceptable for Phase 10)

- **Per-frame compositor pipeline rebuild.** Phase 9 closeout flagged
  this; export at 30 fps × multi-minute compilations × wgpu pipeline
  rebuild + readback per frame is the slowest path in the codebase.
  On Apple Silicon 1080p export should run at 1-3× realtime; on
  lavapipe in CI it'll be 0.3-0.5× realtime. Acceptable; Phase 11
  optimizes.

- **Multi-source pipeline memory.** One source decoder per unique
  source_index, all kept alive (per fix #19) — memory cost ~10-50 MB
  per decoder. Tolerable; v1 had similar.

- **VBO churn for strokes** — Phase 9 closeout flagged; same Phase 11
  follow-up.

## Risks / unknowns (sub-agent may need to make calls)

1. **Slint modal-overlay pattern.** Slint has no built-in sheet/
   dialog/modal primitive that matches SwiftUI's `.sheet`. Building
   it as a fullscreen Rectangle overlay should work but
   focus-stealing may be fiddly. If the sub-agent runs into Slint-
   API friction, the alternative is a separate Slint window opened
   by File → Export Compilations — heavier but clean.
2. **(removed — audiomixer dropped from Phase 10 scope per fix #8.)**
3. **Per-element seek for entry transitions.** For multi-source
   compilations (rare), `pipeline.seek_simple` flushes ALL
   elements — including the previous source's chain that we don't
   want to flush. Phase 10 implementation must use per-element
   seeks via `Element::send_event(gstreamer::event::Seek::new(
   ...))` on the active source's filesrc/decodebin specifically.
   Single-source compilations (the common case) tolerate
   pipeline-level seek fine.
4. **Output PTS continuity across entries.** The plan calls for
   monotonic PTS = `composition_start + record_time` in
   nanoseconds. If the encoder rejects non-zero starting PTS, the
   alternative is to start each entry at PTS=0 of a new fragment
   and let qtmux merge — but qtmux concatenation is tricky.
   Monotonic PTS is the standard approach; should work.

---

## Done when

- All 7 tasks committed.
- CI matrix green on macOS / Linux / Windows + media-tests.
- New `export_smoke` integration test passing (export_compilation
  produces a valid .mp4 + cancel deletes the file).
- New `export_smoke` harness E2E passing (end-to-end record →
  export with frames_pushed > 30).
- New `parity_n_frames` test passing (preview/export hash equality).
- New `export.{batch,tag}.{started,completed,failed,cancelled,
  skipped}` events flow over the socket.
- File → Export Compilations opens the sheet; ticking tags + clicking
  Export writes .mp4 files; Cancel during run aborts cleanly.
- No regressions in Phase 1–9 tests.
- PROGRESS.txt reflects each task + the phase SHIPPED line + CI
  run id.
