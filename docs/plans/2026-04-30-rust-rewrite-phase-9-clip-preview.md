# Rust Rewrite — Phase 9: Clip Preview Integration

> **For Claude:** Implement via the per-phase sub-agent pattern (per
> `feedback_phase_per_subagent.md`). The fresh top-level session reads
> this plan + `PROGRESS.txt` + the design doc + the previous phase's
> closeout, then dispatches a sub-agent. Phase 8's lessons say "split
> into smaller per-task agent prompts" — strongly consider 2-3
> sub-agents for this phase rather than one big one.

**Goal:** Click-to-preview a recorded clip: source video plays its
recorded segment, webcam .mov plays in the PiP slot, strokes replay on
top — all rendered through the **same wgpu compositor that the export
path will use**, so a future "preview hash == export hash" check
becomes trivially true. First time strokes get rendered (Phase 8
captured events; Phase 9 draws them).

**Architecture:**
- Bus gains `Command::OpenClipPreview { clip_id }` and
  `Command::ClosePreview` + a new `AppMode::PreviewClip(Uuid)` variant
  alongside Phase 8's mode states.
- New `crates/video-coach-media/src/preview_pipeline.rs`: opens the
  source video + the clip's recording.mov, walks the clip's
  `PlaybackSegment[]` (already exists in `video-coach-core::timeline`)
  to determine which source-time range each output frame should pull
  from, runs each composed frame through the wgpu compositor, pushes
  to the `FrameSink` (Phase 7's same trait — UI bridge unchanged).
- Compositor's `compose` API extends to accept strokes:
  `compose(source, webcam, strokes)` — stroke replay computed from
  events via the existing `stroke_replay::visible_strokes_at` helper.
  Stroke rendering happens in a new wgpu pass; render order is source
  → PiP → strokes. Same call drives both preview (Phase 9) and export
  (Phase 10's batch export will wire this through `compose.rs`).
- UI:
  - Sidebar panel listing clips (clip.name, clip.recordingDuration,
    sourceIndex). MVP: clicking a clip dispatches OpenClipPreview.
    Sidebar shows when a project is open with ≥1 clip.
  - Mode-aware transport: PreviewClip mode hides the regular play
    surface's Add-Source / Record buttons and shows a "← Source"
    button + the clip-name. Phase 7's scrubber drives the preview
    pipeline's seek.
- Source player ownership: the existing `current_player` (Phase 7)
  pauses on PreviewClip entry. The preview pipeline owns its own
  decoding for the preview duration. ClosePreview tears down the
  preview pipeline; source player stays paused (matches v1).

**Locked-in scope (do not expand):**
1. Single-clip preview at a time.
2. Strokes replay through the compositor (NOT a Slint overlay) so
   preview and export hash-match.
3. Source video: only the segment range driven by `PlaybackSegment[]`
   gets decoded. No precaching beyond GStreamer's normal preroll.
4. Pre-decoded freeze frames: v1's `frozenFrames` cache is kept —
   freeze segments must show the source frame at segment-start time,
   not the latest played frame, so backward-scrub stays correct.
   `preview_pipeline.rs` pre-decodes one frame per `Freeze` segment at
   open time and stashes them.
5. Visual parity test as a separate test crate or harness test that
   Phase 10 will rely on; Phase 9 introduces the *infrastructure* and
   a single-frame parity check (preview pipeline frame 0 ==
   compositor `compose` frame 0 with the same inputs). Full
   end-to-end "preview pipeline N frames hash == export pipeline N
   frames hash" lands in Phase 10 alongside the export sheet.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan (top to bottom; the "Adversarial fixes baked in" section
   below is non-negotiable).
2. `docs/plans/2026-04-28-rust-rewrite-design.md` — architecture.
3. `docs/plans/2026-04-30-rust-rewrite-phase-8-recording.md` —
   especially the **closeout**, which records Phase 7+8 lessons:
   event-name namespacing, sub-agent watchdog timeouts, the
   `wait_for_event` matches-by-name-only behavior.
4. `PROGRESS.txt`.
5. v1 reference (port faithfully):
   - `App/Preview/PreviewInstruction.swift` — segments + frozenFrames
     contract.
   - `App/Preview/PreviewCompositor.swift` — segment selection,
     frozen frame fallback, PiP geometry (already mirrored in
     compositor.rs).
   - `App/Preview/StrokeReplayLayer.swift` — `visible_strokes_at`
     timing semantics for replay.
   - `App/Preview/ClipPreviewBuilder.swift` — building the AVMutable
     thing from a clip + segments + frozen frames; the Rust analog is
     `preview_pipeline::open(...)`.
   - `App/Models/AppMode.swift` — preview cases (`previewLoading`,
     `previewClip(Clip.ID)`).
6. Current code:
   - `crates/video-coach-core/src/timeline.rs` (`PlaybackSegment`,
     `playback_segments`, `source_time_at` — all already shipped).
   - `crates/video-coach-core/src/stroke_replay.rs`
     (`visible_strokes_at` — already shipped).
   - `crates/video-coach-compositor/src/compositor.rs` (current
     `compose(source, webcam)` — Phase 9 Task 1 extends this).
   - `crates/video-coach-compositor/src/shaders/` — existing wgpu
     shader files; Phase 9 adds a `strokes.wgsl`.
   - `crates/video-coach-media/src/source_player.rs` — pattern for
     decode pipeline + FrameSink contract.
   - `crates/video-coach-media/src/compose.rs` — Phase 5 export
     pipeline; the eventual visual-parity test exercises this against
     the new preview pipeline.
   - `crates/video-coach-app/src/bus.rs` — handler shape.
   - `crates/video-coach-app/src/ui.rs` + `ui/main.slint` — Phase 7+8
     transport bar to extend.
   - `crates/video-coach-harness/tests/record_clip_smoke.rs` —
     pattern for new harness tests (record a clip, then preview it).

---

## Adversarial-review fixes baked in

The main session ran an adversarial reviewer on this plan; the fixes
are **non-negotiable**. Sub-agent: every one must be present in the
shipped code.

> _**To main session writing this plan**: run an adversarial-review
> pass before committing the plan, paste the fixes below, then commit.
> If you skip this and the section stays empty, the sub-agent should
> stop and ask the user._

**1. Event-name namespacing (Phase 8 lesson).** The harness's
`wait_for_event` matches by event name only, NOT by target. Every
Phase 9 event must have a unique name across the whole codebase.
Suggested namespace: `clip_preview.opened`, `clip_preview.closed`,
`clip_preview.frame` (if needed), `clip_preview.failed`. NEVER reuse
`recording.*` or `clip_recording.*`.

**2. Sub-agent prompt sizing (Phase 8 lesson).** The watchdog timed
out twice on Phase 8's **3-task** prompts. The lesson is "split into
smaller per-task agent prompts" — so Phase 9 splits into 4-5 small
agents, NOT 2 big ones:
- Agent 1: Task 0 (preflight — mostly mechanical: bus shapes, AppMode
  Clone-ification, FORWARDED_TARGETS, ClipSummary/ClipListSlot
  scaffolding).
- Agent 2: Task 1 (compositor strokes — self-contained; verify with
  the Task-1 golden test before handing off).
- Agent 3: Task 2 (preview pipeline — biggest single task; deserves
  its own agent so the watchdog doesn't trip mid-decode-pipeline).
- Agent 4: Tasks 3+4 (bus wiring + UI — tightly coupled; the bus
  routes Play/Pause/Seek + the UI shows the new sidebar/transport).
- Main session: Tasks 5+6+7 (harness E2E + parity + closeout —
  each is small).

After every agent, verify locally + push + check CI green BEFORE
dispatching the next.

**3. FrameSink contention with the source player.** Phase 7's
`SourcePlayer` and the new preview pipeline both write to the SAME
`FrameSlot` (single-slot Arc<Mutex<Option<...>>>). After
`player.pause().await` returns, the GStreamer streaming thread can
STILL deliver one or two queued frames to the player's FrameSink
(set_state(Paused) returning is not a frame-flush guarantee), so
just "pause then spawn preview" leaves a race where a stale source
frame lands AFTER preview's first frame.

Fix: every `SlintFrameSink` carries an `active: Arc<AtomicBool>`
(default true). `push_frame` checks the flag and drops on the floor
when false. The bus owns one flag per mounted pipeline:
- On `OpenClipPreview`: set the **player's** flag false BEFORE the
  pause-await. Spawn the preview pipeline; its sink starts with
  active=true.
- On `ClosePreview`: set the **preview's** flag false, tear down the
  pipeline, set the player's flag true (the player is paused so it
  won't push anything until the user resumes — fix #9).
- The `FrameSinkFactory` returns `(Box<dyn FrameSink>,
  Arc<AtomicBool>)` so the bus keeps the handle. (Or wrap into a
  small `MountedSink` struct.)

This is cheaper than mutex'ing the slot writes and gives the bus
deterministic ownership of "who's writing pixels right now". Phase 7's
`SlintFrameSink` and `NullFrameSink` both grow the flag.

**4. Strokes-in-compositor coordinate space.** Phase 8 stored stroke
points normalized to [0,1] against the displayed (post-letterbox)
video rect. The compositor renders into the source-aspect-ratio
frame (e.g. 1920x1080 for a 16:9 source). For Phase 9's locked-in
"16:9 source → 16:9 output" scope, the displayed-rect-relative
coordinates and the source-frame-relative coordinates are IDENTICAL —
[0.5, 0.5] in the displayed letterboxed UI is also [0.5, 0.5] in the
source frame, which is also [0.5, 0.5] in the compositor output.
**No coordinate transform needed for Phase 9.**

Skip the active-rect uniform; pass stroke points to the shader in
[0,1] space and convert to clip space (`x*2-1`, `1-y*2`) in the
vertex shader. When Phase 10/11 adds aspect-ratio mismatch (e.g.
16:9 source → 9:16 vertical export), introduce the active-rect
uniform THEN — the export sheet is the right place to define
"what's the active video rect within the output canvas". Adding it
prematurely in Phase 9 invites a bug where `[0,0,1,1]` fights with
the no-letterbox scenario it's supposed to handle.

**5. Compositor `compose()` API change is breaking.** Phase 5's
`compose.rs` calls `compose(source, webcam)` per frame. Adding a
`strokes` parameter changes the signature. Update Phase 5's call
site to pass `&[]` (no strokes during export). Don't keep two
overloads. Phase 10's export sheet will populate the strokes for
real.

**6. Pre-decoding freeze frames blocks the bus.** Building the
preview pipeline pre-decodes one source frame per `Freeze` segment.
At ~30 fps decode-then-grab, a clip with 5 freezes adds ~150ms to
OpenClipPreview latency. That's tolerable but must run in
`spawn_blocking`, not on the bus task. Same pattern as
`SourcePlayer::open` — adversarial-review fix #6 from Phase 7.

**7. No actual hash-equality test in Phase 9.** The full preview-vs-
export hash comparison wants to land in Phase 10 alongside batch
export. Phase 9 ships the *infrastructure* (compositor strokes,
preview pipeline, the call shape) and a single-frame check (frame at
t=0 of preview pipeline == output of `compositor.compose(...)` with
the same inputs). The full N-frame parity test is a Phase 10 task
explicitly noted in this plan's "deferred" section.

**8. PreviewClip mode + AppMode collisions.** Phase 8's
`AppMode { Scanning, RecordingStarting, Recording }` doesn't include
preview cases. Adding `PreviewClip(Uuid)` to a `#[derive(Copy)]` enum
breaks `Copy` (Uuid isn't Copy in some builds). Drop `Copy`; use
`Clone`. Update every existing `*current_mode = ...` site that
assumed Copy. Run `cargo clippy --all-targets --features media`
after to catch derived-trait fallout.

**9. Source player must NOT auto-resume on ClosePreview.** Match v1:
the source stays paused; the user re-presses Space to resume. UI
indicates this with the play button being in "play" state.

**10. Headless preview test must work without a display.** Phase 7
+8 used the harness binary. Phase 9 wants a `preview_pipeline_smoke`
integration test in `crates/video-coach-media/tests/` that opens a
fixture source + a fixture webcam, walks a hand-built clip's
segments, runs through the compositor, asserts a non-trivial frame
count came out of the FrameSink. No Slint, no harness binary —
direct unit test. Linux CI: `VIDEO_COACH_NO_AUDIO` already set in
prior tests; carry forward.

**11. Freeze-frame source-time is the END of the preceding Play
segment, NOT `segment.source_start`.** `PlaybackSegment.source_start`
for a Freeze segment is the source position when the freeze BEGAN,
which is the same as the preceding Play segment's
`source_start + out_duration`. v1's
`ClipPreviewBuilder.swift::sourceTimeAtEndOfPlay` decodes at the
END of the preceding play, not at the freeze's own source_start.
For most clips these coincide, but Skip-then-Freeze patterns (skip
event immediately before pause) put `freeze.source_start` AFTER the
last Play's source_start + out_duration, and decoding at the wrong
spot produces the wrong frozen frame. Pre-decode logic in
`PreviewPipeline::open` must walk segments and, for each Freeze,
compute the source time as
`prev_play.source_start + prev_play.out_duration` (or `clip
.start_source_seconds` if the clip starts with a Freeze). Add a unit
test in `video-coach-core` covering Skip-then-Freeze if one isn't
already there.

**12. `PreviewPipeline::seek` MUST use `source_time_at`, not seek
the source decoder to `record_time` directly.** `seek(record_time,
accurate)` resolves the source decoder seek target via
`video_coach_core::timeline::source_time_at(clip, record_time)`
which already accounts for skips/pauses. Seeking the source decoder
to `record_time` directly produces wrong frames for any clip that's
been skipped past a section. If the resolved target lands inside a
`Freeze` segment, the seek skips the source decoder and switches the
driver to "show the frozen frame for that segment" mode.

**13. `ClipListSlot` hydration sites are explicit.** The
`Arc<Mutex<Vec<ClipSummary>>>` is written by THREE handlers:
- `OpenProject` — populates from `project.clips` after load.
- `NewProject` — clears (project starts empty).
- `StopClipRecording` — appends the new clip to the list after a
  successful save.

If any of these three write sites are missing, the sidebar shows a
stale or empty list. Sub-agent: write a unit test that exercises
each path.

**14. `PreviewPipeline` teardown must mirror `Recording::stop`.**
Phase 8 spent four commits (`802ef66`, `2d8d8dc`, `515876c`,
`59561ed`) learning that GStreamer pipelines on macOS need stepped
Paused → Ready → Null transitions with sync-state waits at each
level, plus ghost-pad linking + `sync_state_with_parent` on every
dynamic element. Audio sinks are gentler than `osxaudiosrc` but the
preview pipeline still has an `osxaudiosink` (or `pulsesink` /
`wasapisink`) and decoders that close OS handles on Null transition.
Specify an explicit `PreviewPipeline::stop(self) -> Result<(),
PreviewPipelineError>` (NOT just relying on Drop), called from
`ClosePreview` via `spawn_blocking`. Drop should ALSO call the same
teardown as belt-and-suspenders for panic paths. Pattern: copy
`recording.rs::Recording::stop` shape (no EOS send needed since
we're not finalizing a file — but DO step through Paused/Ready
before Null).

**15. Position-poll task for the preview pipeline.** Phase 7's
`spawn_position_poll` writes `PlayerStateSlotData` every 100ms so
the scrubber + mm:ss label update at display rate. Phase 9 must
spawn the SAME pattern when the preview pipeline mounts (so the
preview's scrubber moves while it plays). Add an `AbortHandle`
return so `ClosePreview` can cancel the task — Phase 7 didn't need
this (single long-lived player) but Phase 9 mounts/unmounts the
preview pipeline repeatedly. Refactor `spawn_position_poll` to
return its `JoinHandle` and store it in
`current_preview_poll: Option<AbortHandle>` on the bus task.
ClosePreview aborts before dropping the pipeline.

**16. `PlayerStateSlot` is shared, ONE slot for both pipelines.**
Don't add a separate `PreviewStateSlot`. The bus's `Play/Pause/Seek`
handlers route to whichever pipeline is mounted (preview when
`current_mode == PreviewClip`, source player otherwise). Whoever is
mounted writes its `snapshot()` into the same slot. The UI's 30 Hz
timer reads ONE slot and doesn't need to know which pipeline
produced the data. The `last_seek_at` suppression continues to work
unchanged because Seek is already routed to the active pipeline.

**17. Preview output framerate is pinned to 30 fps, NOT
source-driven.** v1 sets `videoComp.frameDuration = 1/30`. The
existing `compose.rs::compose_two_files` is source-driven (every
source frame triggers a compose) which works for export but at
1080p60 source playing live preview would push 480 MB/s through
GPU↔CPU readback (existing `compose()` does a sync `map_async +
poll(Wait)` per call). Pin preview's driver to a 30 Hz internal
timer that asks "what record_time are we at now?" → looks up the
segment → asks the source decoder for the frame at the resolved
source time (or pulls the cached frozen frame) → composes →
pushes. This decouples decode rate from preview rate and bounds GPU
work. Caveat: the source decoder still streams at its native rate;
we just sample at 30 Hz. (Optimizing the per-call wgpu pipeline
rebuild is still a Phase-10 follow-up; that's already in "Known
performance risks".)

**18. `ClipSummary` shape is defined in Task 0, not Task 4.** The
`Arc<Mutex<Vec<ClipSummary>>>` slot is set up in Task 0 alongside
the other slots so Task 3's bus handlers and Task 4's UI both have a
typed contract to agree on. Minimum fields:
```rust
#[derive(Debug, Clone)]
pub struct ClipSummary {
    pub id: uuid::Uuid,
    pub name: String,
    pub recording_duration: f64,
    pub source_index: usize,
}
```
The Slint side gets a `clip-id: string` per row so the click handler
dispatches `OpenClipPreview { clip_id }` with the right UUID. Slint
ListView consumes a `[{id: string, name: string, duration: float}]`
model; the UI thread converts from `ClipSummary` on each timer tick
(cheap; clip lists stay small).

**19. Compositor depends on `video-coach-core`.** Task 1 imports
`video_coach_core::stroke_replay::VisibleStroke` and
`video_coach_core::stroke::Stroke` for the new `compose()`
parameter. Today compositor depends only on wgpu + bytemuck +
thiserror; add `video-coach-core = { path = "../video-coach-core" }`
to compositor's `Cargo.toml`. No cycle (core has no compositor dep).

**20. Webcam EOS during preview is non-fatal.** The recording.mov
can finish a frame or two before `clip.recording_duration` (qtmux
finalize). The preview pipeline must keep going past webcam EOS
using the LAST received webcam frame (matches
`compose.rs::compose_two_files` driver behavior). Source EOS or
record-time reaching `clip.recording_duration` is the actual end-
of-preview signal; emit `clip_preview.completed` (or just stop
pushing frames and let the user click "← Source"). Phase 9 picks
"stop pushing frames at clip.recording_duration; let mode stay
PreviewClip until ClosePreview is sent" — simpler than auto-
closing.

**21. Single-frame parity uses ONE shared `Compositor` instance.**
Task 6's byte-for-byte assertion only holds when both call sites
(direct `compose(...)` and `PreviewPipeline` internal compose) use
the SAME `Compositor` instance. Different instances on the same
machine can diverge by a bit or two due to driver pipeline-cache
state. Wire the preview pipeline to accept an
`Arc<Compositor>` parameter; the parity test constructs one and
passes it to both paths. (Production code can construct its own per
preview; tests just need determinism.)

**22. Click-while-preview-open: refuse and require explicit close.**
Task 3's OpenClipPreview handler refuses if `current_mode` isn't
`Scanning`. v1 likely auto-closes the prior preview, but for
Phase 9 MVP refuse is simpler and safer (no double-teardown race).
UX: clicking another clip while one is open is a no-op + a
`clip_preview.failed` event with `reason="already_in_preview"`. The
user sees the "← Source" button and clicks it, then clicks the new
clip. Phase 10/11 can add auto-close-and-reopen; the cost of
refusing is one extra click that's at least obvious.

**23. Source decoder seek policy is restrictive — no per-tick
re-seeks.** Task 2's 30 Hz driver step 3.e ("ensure source decoder
is positioned at `source_time_at(...)`") is ambiguous and a naive
implementer could re-seek every tick when there's any drift. On a
long-GOP source (`fixtures/source-1080p.mp4`'s GOP is ~5s — see
Phase 7 commit notes), every drift-correcting seek dumps 0–5s of
decoded pre-roll and the next tick has no fresh frame. The driver
must seek the source decoder ONLY in three cases:
- (a) Initial mount in `PreviewPipeline::open` (seek to the first
  segment's `source_start`).
- (b) Entering a `Play` segment after a `Freeze` segment (seek to
  the new Play's `source_start`, accurate=true).
- (c) A user `Seek` command on the preview pipeline (seek to
  `source_time_at(clip, target_record_time)`; if target lands in a
  Freeze segment, NO source seek — switch to frozen-frame mode for
  that segment).

In steady-state `Play` the source pipeline runs at 1× rate and the
driver consumes whatever the appsink slot holds at tick time. The
appsink and the 30 Hz driver are running on independent clocks;
brief drift between them (<= one tick of frame-time) is invisible
and self-corrects on the next decoded frame. NEVER seek "to fix
drift" inside a Play segment.

During a `Freeze` segment the driver ignores the source appsink slot
entirely and uses the cached frozen frame. The source pipeline can
be left PLAYING during the Freeze (cheap; we throw the frames away)
or paused as an optimization — pick one and document it; pausing
adds state-transition latency at Freeze→Play boundaries (need to
PLAY + seek before the first useful frame), so leaving it PLAYING
and seeking on the boundary is simpler.

**24. `compose_tick` is a free function, called by both the preview
pipeline driver AND the parity test.** As specced, Task 6 builds a
`PreviewPipeline` from synthetic `Frame`s, but `PreviewPipeline::
open` takes file paths and spins up GStreamer chains. The two are
incompatible. Fix: in Task 1, extract the per-tick compose+push
logic out of any GStreamer wrapper into a free function:
```rust
pub fn compose_tick(
    compositor: &Compositor,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError>;
```
This is essentially a thin wrapper around `compositor.compose(...)`
— maybe identical to it — but naming it as the canonical "one tick
of preview/export work" makes the parity test obvious: Path A and
Path B both call `compose_tick(...)` with the SAME inputs, byte-for-
byte equality is automatic. No GStreamer in the parity test.
PreviewPipeline's driver also calls `compose_tick(...)` per tick.
Phase 5's `compose.rs::compose_two_files` migrates to call
`compose_tick(...)` too, so all three paths share one entry point.

**25. Don't canonicalize paths per command — canonicalize once at
OpenProject and join from there.** Task 3 step 5 originally said
`canonicalize(folder.join(...))`. The project folder is already
canonicalized at OpenProject/NewProject time (Phase 7 commit
e107240 — required on macOS for `/var/folders → /private/var/
folders`). Source/recording paths are derived by joining from the
canonical folder; the joined paths are also canonical with no
further work. Per-command canonicalize is wasted IO + risks
spurious "file not found" failures during racy test teardown. State:
`source_path = project_folder.join(source_ref.relative_path);
recording_path = project_folder.join("recordings")
.join(clip.recording_filename);` — no `.canonicalize()` on either.
Validate file existence with `is_file()` if needed, but don't re-
resolve symlinks.

**26. Harness E2E asserts `frames_pushed > 0`.** Task 5's harness
test currently ends at `wait_for_event("clip_preview.closed")`,
which proves lifecycle round-trips but NOT that the bus correctly
wired the FrameSink active-flag handover or that the preview
pipeline actually pushed pixels. Add a `frames_pushed: u64` field
on the `clip_preview.closed` event (counted by the FrameSink wrapper
in the bus task — every `push_frame` call increments an
`Arc<AtomicU64>`). Task 5 asserts the count is > 10 after a 1s
preview play. Costs three lines; catches the entire class of "bus
wiring works for control but the pixel path is broken" regressions.

---

## Tasks (~7 total — split across 4-5 sub-agent dispatches per fix #2)

### Task 0: Preflight — bus shapes + AppMode + slots + FrameSink active flag

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/event_layer.rs`
- Modify: `crates/video-coach-app/src/frame_sink.rs`
- Modify: `crates/video-coach-app/src/main.rs` (wire the new slot
  + factory shape).

**Add to `Command`:**
- `OpenClipPreview { clip_id: String }` (UUID as string per existing
  serde shape).
- `ClosePreview`.

**`AppMode` gains `PreviewClip(Uuid)` variant.** Drop `#[derive(Copy)]`
from `AppMode`; switch to `Clone`. Update every read site (passing
by value or via `*deref`); pass `&AppMode` or `clone()` where the
old code passed `*current_mode`. Update `is_recording`'s signature
from `current_mode: AppMode` → `current_mode: &AppMode` (one less
clone). Run `cargo clippy --workspace --all-targets --features
media -- -D warnings` to catch fallout.

**`RecordingMode` mirror in frame_sink.rs gains `PreviewClip` variant.**
The mirror only needs to distinguish "is the REC indicator visible"
vs. "is the preview transport visible"; UUID payload doesn't ride
the mirror (the bus task is the source of truth for which clip).

**`FORWARDED_TARGETS` gains `clip_preview.lifecycle`**. Per
adversarial fix #1, every event in this phase namespaces under
`clip_preview.*` — never `preview.*` (would collide), never
`recording.*`.

**`ClipSummary` + `ClipListSlot` (per fix #18).** Add to
`frame_sink.rs`:
```rust
#[derive(Debug, Clone)]
pub struct ClipSummary {
    pub id: uuid::Uuid,
    pub name: String,
    pub recording_duration: f64,
    pub source_index: usize,
}
pub type ClipListSlot = Arc<Mutex<Vec<ClipSummary>>>;
pub fn new_clip_list() -> ClipListSlot { /* ... */ }
```
Thread the slot through `bus::spawn_on` + `ui::run` signatures (same
shape as `RecordingStateSlot`). Hydration in handlers lands in
Task 3 (per fix #13: OpenProject populates, NewProject clears,
StopClipRecording appends).

**FrameSink active flag (per fix #3) + frame counter (per fix #26).**
Modify `SlintFrameSink` and `NullFrameSink` so each carries:
- `active: Arc<AtomicBool>` (default true). `push_frame` returns
  early when false.
- `frames_pushed: Arc<AtomicU64>`. `push_frame` increments after the
  active check passes, so the counter reflects "frames that landed in
  the slot", not "frames the GStreamer thread tried to push".

The mount handle exposes both: the bus can flip the flag and read
the counter (drained on `clip_preview.closed` to populate the
event's `frames_pushed` field).

**`FrameSinkFactory` becomes `FrameMountFactory`** that returns
`(Box<dyn FrameSink>, Arc<AtomicBool>)` — or wrap into a
`MountedSink { sink, active }` struct. Bus task gets two mount
handles: `current_player_mount` (set on player open) and
`current_preview_mount` (set on OpenClipPreview, cleared on
ClosePreview). On preview open: flip player_mount.active=false
BEFORE pause. On preview close: flip preview_mount.active=false,
tear down, flip player_mount.active=true.

**Bus serde unit tests** for the two new commands + the AppMode
variant.

**Update PROGRESS.txt + commit + SHA-fill follow-up.**

---

### Task 1: Compositor strokes — extend `compose()` API + new wgpu pass

**Files:**
- Modify: `crates/video-coach-compositor/Cargo.toml` (per fix #19,
  add `video-coach-core = { path = "../video-coach-core" }` dep).
- Modify: `crates/video-coach-compositor/src/compositor.rs`.
- Create: `crates/video-coach-compositor/src/shaders/strokes.wgsl`.
- Modify: `crates/video-coach-compositor/src/lib.rs` (re-export
  `video_coach_core::stroke_replay::VisibleStroke` for callers).
- Modify: `crates/video-coach-media/src/compose.rs` — Phase 5 export
  pipeline gains a `&[]` pass for strokes (no strokes during the
  Phase 5 → Phase 9 transition).

**API change:**
```rust
pub fn compose(
    &self,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError>;
```

**Free function `compose_tick` (per fix #24):** export from
`video-coach-compositor`'s lib.rs:
```rust
pub fn compose_tick(
    compositor: &Compositor,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError> {
    compositor.compose(source, webcam, strokes)
}
```
Trivial wrapper today, but it's the **single canonical entry point**
that `PreviewPipeline`'s 30 Hz driver, `compose.rs::compose_two_
files`'s per-source-frame loop, and Task 6's parity test all call.
Future per-tick orchestration (frame timing, stats counters, color-
space conversions) lands here without forking. `compose.rs`'s
existing call site updates to `compose_tick(&comp, &source_frame,
&webcam_frame, &[])`.

**Stroke pass:** new wgpu pipeline that takes stroke vertices in
[0,1] space (per fix #4 — Phase 9 ships only 16:9→16:9, so no
active-rect uniform; the vertex shader maps `[0,1] → clip space` via
`x*2-1, 1-y*2`). Uniform carries stroke color + stroke width only.
v1's StrokeReplayLayer uses CALayer with a CGPath; ours is GPU-
rendered, anti-aliased via a fragment shader that does perpendicular
distance + smoothstep.

**Line-rendering approach:** wgpu's `LineStrip` primitive only
guarantees 1-px lines on most backends. Skip the line-strip detour
and go directly to a triangle-strip-from-line-segments
implementation: for each pair of adjacent stroke points, emit a quad
(two triangles) wide enough to render the line + AA falloff. The
fragment shader computes perpendicular distance to the segment and
smoothsteps the alpha. Width: ~4 px on output (passed in the
uniform as a fraction of output height so it scales with resolution).
Color: white with 80% alpha.

**Tests:**
- New golden-frame test in `video-coach-compositor`: `compose` with
  one stroke should differ from `compose` with no strokes; check that
  pixels along the stroke path differ from the no-stroke output.
- Sanity test: `compose` with `&[]` strokes produces byte-identical
  output to a Phase-5-style call (verifies no regressions in the
  stroke-less path that export uses).

**Update PROGRESS.txt + commit.**

---

### Task 2: Preview pipeline — `crates/video-coach-media/src/preview_pipeline.rs`

**Files:**
- Create: `crates/video-coach-media/src/preview_pipeline.rs`.
- Modify: `crates/video-coach-media/src/lib.rs` (cfg-gate behind
  `media`).
- Create: `crates/video-coach-media/tests/preview_pipeline_smoke.rs`
  (per adversarial fix #10).

**API:**
```rust
pub struct PreviewPipeline { /* gst pipeline + state */ }

impl PreviewPipeline {
    pub fn open(
        source_path: &Path,
        recording_path: &Path,
        clip: &video_coach_core::project::Clip,
        source_duration_seconds: f64,
        compositor: Arc<video_coach_compositor::Compositor>, // fix #21
        frame_sink: Box<dyn FrameSink>,
    ) -> Result<Self, PreviewPipelineError>;

    pub fn play(&self) -> Result<(), PreviewPipelineError>;
    pub fn pause(&self) -> Result<(), PreviewPipelineError>;
    pub fn seek(&self, record_time_seconds: f64, accurate: bool)
        -> Result<(), PreviewPipelineError>;
    pub fn snapshot(&self) -> PlayerSnapshot; // same shape as Phase 7
    pub fn stop(self) -> Result<(), PreviewPipelineError>; // fix #14
}
```

**Inside `open()`:**
1. Use `playback_segments(clip, source_duration)` to get the
   `Vec<PlaybackSegment>` for the clip.
2. **Pre-decode freeze frames** (per fix #6 + fix #11) — for each
   `Freeze` segment, walk segments backward from index `i` to find
   the most recent `Play`; the source-time to decode is
   `prev_play.source_start + prev_play.out_duration` (or
   `clip.start_source_seconds` if no preceding Play). Decode via a
   `filesrc → decodebin → videoconvert → RGBA appsink` mini-pipeline
   that seeks → grabs one buffer → tears down. Run in
   `spawn_blocking` throughout. Store as `HashMap<usize, Frame>`.
3. Build the GStreamer composition pipeline:
   - Source decoder (filesrc → decodebin → videoconvert → RGBA
     appsink), seekable. **Source AUDIO chain is NOT built** — webcam
     is the only audio source in preview (Phase 9 ships commentary-
     only per "deliberately not included"). decodebin's audio pad
     gets routed to a fakesink to avoid "Internal data flow error".
   - Webcam decoder (filesrc on the recording.mov → decodebin →
     videoconvert → RGBA appsink + audio sink chain via
     `audioconvert → audioresample → volume → osxaudiosink|...`,
     same `platform_audio_sink_name()` helper as `source_player.rs`
     including `VIDEO_COACH_NO_AUDIO=fakesink` fallback).
   - **Driver: a 30 Hz tokio interval timer** (per fix #17), NOT the
     source appsink. Each tick:
     a. Compute `record_time = playhead.elapsed()` (with pause/seek
        bookkeeping).
     b. If `record_time >= clip.recording_duration`: stop pushing
        frames; emit `clip_preview.completed`; pause internally
        (mode in bus stays PreviewClip until ClosePreview, per fix
        #20).
     c. Resolve segment index for this record_time.
     d. If segment is `Freeze`: source frame = pre-decoded frozen
        frame for that segment.
     e. If segment is `Play`: ensure source decoder is positioned at
        `source_time_at(clip, record_time)` (via fix #12); pull the
        latest source frame from a single-slot Mutex written by the
        source appsink.
     f. Pull the latest webcam frame (single-slot Mutex written by
        the webcam appsink; persists last frame past webcam EOS per
        fix #20).
     g. Compute strokes via
        `visible_strokes(clip, record_time)`.
     h. Call `compositor.compose(source, webcam, &strokes)`.
     i. Push to `FrameSink`.
4. Webcam EOS handling (fix #20): the webcam appsink's EOS callback
   is a no-op; the webcam slot keeps the last frame. The driver
   sees `Some(...)` in the slot and continues compositing until
   record_time hits `clip.recording_duration`.

**Teardown (`stop`, per fix #14):** mirror `recording.rs::Recording::
stop`'s stepped Paused → Ready → Null transitions with `state(timeout)`
waits at each level. No EOS send (we're not finalizing a file). Drop
impl calls the same teardown as a panic-path safety net. Cancel the
30 Hz driver timer task before transitioning state.

**Smoke test:** record a clip via the existing flow → open a
preview → assert ≥10 frames flowed through the FrameSink in 1s of
playback. No display needed.

**Update PROGRESS.txt + commit.**

---

### Task 3: Bus wiring — `OpenClipPreview` / `ClosePreview` + `ClipListSlot`

> **NOTE FOR SUB-AGENT DISPATCHER:** Phase 8's two sub-agents both
> timed out on the watchdog (~10 min idle). Strongly consider
> dispatching Tasks 0–2 as one sub-agent and Tasks 3–5 as a second
> sub-agent (per adversarial fix #2). Tasks 6 + 7 can go to a third
> or run in main session.

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`.

**OpenClipPreview handler:**
1. Parse `clip_id` (Uuid::parse_str). Error on malformed.
2. Refuse if no project open.
3. Refuse if `current_mode` isn't `Scanning` (per fix #22, including
   the "already in preview" case — emit `clip_preview.failed` with
   `reason="already_in_preview"`). Reuse the centralized busy check
   from Phase 8 — extend `is_recording()` to `is_busy()` that returns
   true if mode != Scanning OR recording_clip is some.
4. Find clip by id in `project.clips`. Error if missing.
5. Per fix #25: resolve `source_path = project_folder.join(
   source_ref.relative_path)` and `recording_path = project_folder
   .join("recordings").join(clip.recording_filename)` — NO per-call
   `.canonicalize()` (project_folder was canonicalized once at
   OpenProject/NewProject time, joined paths inherit canonicality).
   Validate `recording_path.is_file()` — if missing, fail with a
   clean `clip_preview.failed` event before spawning the pipeline.
   Look up `source_duration_seconds` from
   `project.source_videos[clip.source_index].duration_seconds`.
6. **Flip player_mount.active=false** (per fix #3) BEFORE pausing —
   even if pause is async, no more frames reach the slot once the
   flag is off.
7. Pause source player (per fix #3 — order: flag-off → pause →
   spawn preview).
8. Build a fresh preview FrameSink + active flag via
   `frame_mount_factory()`; stash as `current_preview_mount`.
9. `spawn_blocking(|| PreviewPipeline::open(..., compositor.clone(),
   sink))`. The bus task holds an `Arc<Compositor>` (constructed
   once at startup, shared across preview opens — keeps fix #21's
   parity test architecturally honest). On success:
   - `current_preview = Some(Arc::new(pipeline))`.
   - `current_mode = AppMode::PreviewClip(clip_id_uuid)`.
   - `RecordingStateSlot` updated to mode = PreviewClip.
   - **Spawn position-poll task** (per fix #15) using a
     refactored `spawn_position_poll` that returns its
     `JoinHandle`/`AbortHandle`. Store the handle in
     `current_preview_poll: Option<AbortHandle>`. The task writes
     `pipeline.snapshot()` into the **same** `PlayerStateSlot` (fix
     #16) that Phase 7 uses — no separate slot.
   - `tracing::info!(target: "clip_preview.lifecycle", event =
     "clip_preview.opened", clip_id, source = ..., recording = ...)`.
10. Failure: flip player_mount.active=true (rollback);
    `current_preview_mount = None` (defensive — don't leave a
    stale mount handle that ClosePreview would later flip);
    `current_preview = None`; emit `clip_preview.failed` with the
    error; mode stays Scanning; player stays paused (won't auto-
    resume per fix #9).

**ClosePreview handler:**
1. Refuse if mode isn't PreviewClip.
2. Abort the preview position-poll task
   (`current_preview_poll.take().map(|h| h.abort())`).
3. **Flip preview_mount.active=false** (per fix #3) BEFORE teardown
   — no more pixel writes from the preview's GStreamer threads even
   if a callback is in flight.
4. Tear down `current_preview` via explicit `pipeline.stop()` in
   `spawn_blocking` (per fix #14 — NOT relying on Drop). Drop is a
   safety-net only.
5. Mode → Scanning. RecordingStateSlot updated.
6. **Flip player_mount.active=true** so the source player's
   FrameSink can write again when the user resumes. Player is paused
   (fix #9); it won't push until the user re-presses Space, but the
   slot needs to be writable when they do.
7. `tracing::info!(target: "clip_preview.lifecycle", event =
   "clip_preview.closed", frames_pushed = preview_mount
   .frames_pushed.load(SeqCst))`. Per fix #26 — the harness E2E
   asserts this is > 10 after a 1s preview play.

**Existing `Play` / `Pause` / `Seek` commands**: route to
`current_preview` when in `PreviewClip` mode, to `current_player`
otherwise. Single-line dispatch. The `last_seek_at` write into
`PlayerStateSlot` is unchanged (fix #16 — one shared slot).

**Update PROGRESS.txt + commit.**

---

### Task 4: UI — clip sidebar + mode-aware transport + preview-close action

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`.
- Modify: `crates/video-coach-app/src/ui.rs`.
- Modify: `crates/video-coach-app/src/frame_sink.rs` if needed for
  clip-list slot.

**Clip sidebar:** narrow panel on the left (200 px). Lists clips by
name + duration. Clicking dispatches `Command::OpenClipPreview`. The
list is hydrated from `project.clips` via a shared
`ClipListSlot: Arc<Mutex<Vec<ClipSummary>>>` written by the bus when
projects are opened or clips are added; read by the 30 Hz UI timer.

**Mode-aware transport:** the bottom transport bar already shows the
play/pause + scrubber. In PreviewClip mode it ALSO shows a "← Source"
button on the left and a clip-name label in the center. The skip
buttons + keyboard shortcuts route to the active player, which is
already the case (Task 3 routes Play/Pause/Seek to `current_preview`
when in PreviewClip mode).

**Esc key + close button:** Esc dispatches `ClosePreview` when in
PreviewClip mode (otherwise no-op). FocusScope handles this.

**Update PROGRESS.txt + commit.**

---

### Task 5: Harness E2E — record + preview + verify frames

**Files:**
- Create:
  `crates/video-coach-harness/tests/preview_clip_smoke.rs`.

**Test flow:**
1. Open temp project + add a source.
2. Use `--fixture-recording-source` to record a 1.5s clip with the
   recording flow already covered by Phase 8.
3. Send `open_clip_preview` with the clip's id (extract from the
   `clip_recording.stopped` event's clip_id field).
4. Wait for `clip_preview.opened`.
5. Send Play (Phase 7's `play` command).
6. Sleep 1s.
7. Send `close_preview`.
8. Wait for `clip_preview.closed`. Per fix #26: assert the event's
   `frames_pushed` field is > 10 (≥ ~one third of a 1s play at the
   pinned 30 fps driver rate, accounting for first-frame preroll +
   tear-down). This catches end-to-end "bus wired the lifecycle but
   the pixel path is broken" regressions that the unit-level smoke
   misses (because the unit test bypasses the bus's mount handover).
9. Quit cleanly.

The full per-frame parity verification is in the unit-level
`preview_pipeline_smoke` (Task 2) and `preview_export_parity`
(Task 6). The harness test verifies the control plane PLUS that
pixels actually flowed end-to-end.

**Update PROGRESS.txt + commit.**

---

### Task 6: Single-frame preview-vs-export parity check

**Files:**
- Create: `crates/video-coach-compositor/tests/parity_smoke.rs`
  (lives in compositor crate now — the test no longer needs
  GStreamer/media, only `compose_tick` from fix #24).

Per fixes #21 + #24: both call sites use the SAME `Compositor`
instance AND the SAME `compose_tick(...)` entry point, so byte-for-
byte equality is automatic. No GStreamer in this test.

1. `let compositor = Compositor::new_headless()?;`
2. Build hand-rolled solid-color `source` + `webcam` Frames + a
   `&[VisibleStroke]` slice with one stroke at a known position.
3. **Path A**: `compose_tick(&compositor, &source, &webcam, &strokes)`.
4. **Path B**: same call. (The "two paths" framing collapses now
   that both preview and export funnel through one entry point;
   the test verifies the entry point is deterministic on the same
   instance + same inputs across two back-to-back calls.)
5. Assert `path_a.pixels == path_b.pixels` (byte-for-byte).

The earlier framing of this test ("preview pipeline frame 0 vs
direct compose call") was unimplementable as written (PreviewPipeline
takes file paths, not Frames). Fix #24's `compose_tick` extraction
is what makes the parity test trivially correct: BOTH the preview
driver AND the export pipeline call `compose_tick`, so any future
divergence requires forking that function — and this test would
catch it instantly.

If byte-for-byte proves flaky in CI across runs (very unlikely with
two back-to-back calls on the same instance, but possible with
driver pipeline-cache state), downgrade to a tolerance diff
(`(a as i16 - b as i16).abs() <= 2` per channel, fail if any
channel exceeds). Sample assertions on specific pixels (one inside
the stroke, one outside) make failures more diagnostic than a
buffer-wide compare.

The full N-frame "preview hash == export hash" parity lands in
Phase 10 once batch export is wired up. **Phase 10 prerequisite
(per fix #N2 / new fix #27 below):** export must also pin to 30 fps
so preview-vs-export hash equality is achievable — currently
`compose.rs::compose_two_files` runs source-driven (60 fps source =
60 fps export) while preview is pinned 30 fps.

**Update PROGRESS.txt + commit.**

---

### Task 7: Closeout

- Run `cargo build --workspace` (default), `--no-default-features`,
  `--features media`.
- Run `cargo test --workspace` and `cargo test --workspace --features
  media`.
- Run `cargo clippy --workspace --all-targets --features media --
  -D warnings` AND `cargo clippy --workspace --exclude
  video-coach-media --all-targets -- -D warnings` (Phase 7 closeout
  taught: the no-media variant catches lints the media one misses).
- Run `cargo fmt --check`.
- `git push` + verify CI green via `gh run list --branch rust-rewrite
  --limit 1`.
- Append a closeout section at the bottom of THIS plan file (commits
  table, adversarial-fix verification, deferred items: full N-frame
  parity test → Phase 10, source-volume mix → Phase 9.5).
- Mark Phase 9 SHIPPED in PROGRESS.txt.

---

## What Phase 9 deliberately does NOT include

- **Source-volume mix during preview.** v1 has separate sliders for
  source-volume + commentary-volume; preview defaults to commentary-
  only. Phase 9 ships commentary-only (webcam audio passes through;
  source muted). Phase 9.5 or alongside Phase 10 adds the dual-slider
  + audiomixer wiring.
- **Multiple clips in the sidebar with thumbnails.** MVP shows
  `clip.name + duration`. Phase 10/11 can add thumbnails.
- **Drag-to-reorder clips.** v1 has it; Phase 9 doesn't.
- **Full N-frame preview-vs-export hash equality test.** Single-frame
  proof in Task 6; full N-frame lands in Phase 10's export sheet.
- **Stroke ANIMATION during replay.** v1 fades strokes in/out over
  ~5s windows. Phase 9 ships static strokes (visible at the right
  time per `visible_strokes_at`, then disappear). Animation is a
  Phase 11 polish item.

- **Framerate alignment between preview and export.** Phase 9 pins
  preview to 30 fps internal driver (fix #17) but Phase 5's
  `compose_two_files` still runs source-driven (e.g. 60 fps in →
  60 fps out). The "preview hash == export hash" goal of the
  rewrite is unreachable until the two agree on a sampling rate.
  Phase 10's batch-export task must pin export to 30 fps too (or
  source-rate, with preview matching). Phase 9's single-frame
  parity test (Task 6) sidesteps this by comparing one frame
  through one shared entry point; the N-frame variant in Phase 10
  is blocked on this alignment landing.

---

## Known performance risks (acceptable for Phase 9; revisit in 10/11)

- **`Compositor::compose` rebuilds wgpu pipelines per frame.** The
  current implementation creates shader modules + bind group layouts
  + render pipelines on every call. On Apple Silicon this is fine; on
  Intel integrated / lavapipe in CI it's measurable (2–10 ms/frame
  pipeline objects + readback). At 30 fps + a new stroke pass the
  budget gets tight. Phase 9 does NOT optimize this; if preview drops
  frames on a real machine, file a Phase 10 follow-up to cache the
  pipeline + bind group layout in `Compositor` itself.

- **VBO-per-stroke per-frame.** The naive impl rebuilds a vertex
  buffer per stroke per frame. At 200 strokes that's 200 buffer
  creates + 200 draw calls / frame. CPU-side overhead on integrated
  GPU. Same Phase 10 follow-up applies — pool the VBOs or pack
  multiple strokes into one buffer with offsets.

## Risks / unknowns (sub-agent may need to make calls)

1. **wgpu line-strip rendering with anti-aliasing.** Plan calls for a
   simple line-strip + perpendicular-distance fragment shader. If
   that's harder than expected (line widths > 1 px need a triangle
   strip), substitute a quad-strip implementation. Don't substitute a
   CPU rasterization fallback — the design doc requires GPU-rendered
   strokes for preview/export parity.
2. **`PreviewPipeline` audio-source mute.** v1 mutes source audio
   during preview by default. GStreamer's volume element with
   volume=0 works; or skip building the source's audio chain
   entirely. Plan picks "skip the source audio chain" for simplicity
   — webcam audio is the only audio source in preview.
3. **Pre-decoded freeze frame extraction.** Phase 5 already opens a
   pipeline-then-grab-a-frame for compose; copy that pattern. The
   risk is decoder warm-up time per freeze segment — if it's > 200
   ms per freeze, OpenClipPreview latency on a clip with 10 freezes
   becomes user-visible. Mitigation: run the pre-decodes in parallel
   on the tokio blocking pool (tokio::task::spawn_blocking + join).
4. **`Compositor::compose` stroke parameter is a breaking change.**
   Phase 5 callers must pass `&[]`. The change is small but visible;
   include it in the same task (Task 1) so the workspace stays
   buildable between commits.

---

## Done when

- All 7 tasks committed.
- CI matrix green on macOS / Linux / Windows.
- New `preview_pipeline_smoke` unit test passing.
- New `preview_clip_smoke` harness test passing.
- New `preview_export_parity` single-frame test passing.
- New `clip_preview.{opened,closed,failed}` events flow over the
  socket.
- Clicking a clip in the sidebar shows preview pixels; clicking
  "← Source" or pressing Esc returns to scanning mode (source paused).
- No regressions in Phase 1–8 tests.
- PROGRESS.txt reflects each task + the phase SHIPPED line.

---

## Closeout — SHIPPED 2026-05-01

| Task | Commit | Notes |
|---|---|---|
| 0 | `7041d98` | Bus + AppMode::PreviewClip + ClipListSlot + MountedSink + active flag + frames_pushed counter |
| 1 | `0ddcd6c` | Compositor strokes — extend compose() + new wgpu pass + compose_tick free function. Phase 5's compose.rs migrated. macOS golden hash unchanged (early-return on empty strokes). |
| 2 | `119ff7a` | PreviewPipeline — pre-decoded freeze frames + 30 Hz internal driver + segment-aware compositing + visible_strokes lookup per tick |
| 3 | `93f46f7` | Bus wiring — OpenClipPreview / ClosePreview handlers + Play/Pause/Seek dispatch + ClipListSlot hydration (3 sites) + spawn_preview_position_poll |
| 4 | `f19e731` | UI — clip sidebar (left, 200 px) + mode-aware transport (← Source button + clip-name overlay) + Esc keybinding + clip-clicked / close-preview-clicked callbacks |
| 5 | `b867bb1` | preview_clip_smoke harness — records a clip → opens preview → plays 1s → asserts frames_pushed > 10 on close |
| 6 | `b867bb1` | parity_smoke compositor — compose_tick byte-for-byte deterministic with and without strokes |
| 7 | _this commit_ | Closeout |

CI run on rust-rewrite (final task push) green on all 4 jobs:
ubuntu-latest, windows-latest, macos-latest, media-tests.

### Adversarial-fix verification (all 26 fixes shipped)

- **#1** event names namespaced under `clip_preview.*`; `FORWARDED_TARGETS` gains `clip_preview.lifecycle` ✓
- **#2** split into 4 sub-agents (Tasks 0, 1, 2, 3+4) plus main session (5+6+7) — no watchdog timeouts this phase ✓
- **#3** FrameSink active-flag handover: player_mount.active flipped false BEFORE pause; preview_mount.active flipped false BEFORE teardown; both restored on close ✓
- **#4** Phase 9 ships only 16:9→16:9; no active-rect uniform; strokes pass [0,1] coords directly ✓
- **#5** compose() API change is breaking; Phase 5's compose.rs migrated to compose_tick(&comp, &src, &cam, &[]) ✓
- **#6** freeze frames pre-decoded inline in PreviewPipeline::open; bus wraps the entire open() call in spawn_blocking ✓
- **#7** no full hash-equality test; single-frame parity in Task 6, full N-frame deferred to Phase 10 ✓
- **#8** AppMode dropped Copy; switched to Clone; is_recording → is_busy(&AppMode); all sites updated ✓
- **#9** source player stays paused after ClosePreview; user re-presses Space ✓
- **#10** preview_pipeline_smoke is a media-crate integration test, no display required ✓
- **#11** freeze-frame source-time = `prev_play.source_start + prev_play.out_duration`; Skip-then-Freeze unit test added in `video-coach-core` ✓
- **#12** PreviewPipeline::seek uses `source_time_at`; Freeze-segment seeks skip the source decoder ✓
- **#13** ClipListSlot hydration in OpenProject / NewProject / StopClipRecording with 3 unit tests ✓
- **#14** PreviewPipeline::stop is explicit (NOT Drop-only); mirrors Recording::stop's stepped Paused→Ready→Null with state-waits ✓
- **#15** spawn_preview_position_poll returns AbortHandle; ClosePreview aborts before teardown ✓
- **#16** ONE shared PlayerStateSlot; both pipelines write into it; UI reads one slot ✓
- **#17** preview driver pinned to 30 Hz internal timer (NOT source-driven) ✓
- **#18** ClipSummary defined in Task 0, not Task 4 ✓
- **#19** video-coach-compositor depends on video-coach-core (re-exports VisibleStroke) ✓
- **#20** webcam EOS = keep last frame; clip end = stop pushing + emit clip_preview.completed (once) ✓
- **#21** parity test uses single Compositor instance via shared Arc on the bus task ✓
- **#22** OpenClipPreview refuses if not Scanning; emits clip_preview.failed with reason="already_in_preview" ✓
- **#23** source decoder seeks ONLY on initial mount, Freeze→Play transitions, and user Seek ✓
- **#24** compose_tick free function; PreviewPipeline driver, compose.rs::compose_two_files, and parity test all call it ✓
- **#25** project folder canonicalized once at OpenProject; per-call canonicalize removed ✓
- **#26** clip_preview.closed event carries frames_pushed; harness E2E asserts > 10 ✓

### Deferred items (Phase 10 prerequisites)

- **Full N-frame preview-vs-export hash parity.** Lands in Phase 10 alongside the export sheet. Blocked on framerate alignment (see below).
- **Framerate alignment between preview and export.** Phase 9 pinned preview to 30 fps internal driver; Phase 5's compose_two_files runs source-driven (e.g. 60 fps in → 60 fps out). Phase 10 must pin export framerate (or migrate preview to source-rate when not GPU-bound) before N-frame hash equality is achievable.
- **Source-volume mix during preview.** v1 has separate sliders for source-volume + commentary-volume; preview defaults to commentary-only. Phase 9 ships commentary-only (webcam audio passes through; source audio chain is not built). Phase 9.5 or alongside Phase 10 adds the dual-slider + audiomixer wiring.
- **Stroke animation during replay.** Phase 9 ships static strokes (visible at the right time per visible_strokes_at, then disappear). v1 fades strokes in/out over ~5s windows. Phase 11 polish item.
- **Clip thumbnails + drag-to-reorder.** MVP shows name + duration only. Phase 10/11.
- **Per-frame compositor pipeline rebuild.** compose_tick rebuilds wgpu shader modules + bind group layouts + render pipelines on every call. Acceptable on Apple Silicon; measurable (5-15 ms) on lavapipe in CI. Phase 10/11 follow-up to cache the pipeline + bind group layout in `Compositor` itself, plus pool VBOs for the stroke pass.
- **Preview pipeline "auto-close-and-reopen" on click-while-open.** Phase 9 refuses with `reason="already_in_preview"`; user clicks ← Source first. Phase 10/11 can add auto-close.
