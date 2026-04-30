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
out twice on Phase 8's single-prompt-for-all-tasks approach. Phase 9
should be split: dispatch ONE sub-agent for Tasks 0-2 (compositor
strokes + preview pipeline + bus wiring — the "media + bus" half),
verify CI green, then a SECOND sub-agent for Tasks 3-5 (UI + tests +
closeout). Or split even finer.

**3. FrameSink contention with the source player.** Phase 7's
`SourcePlayer` and the new preview pipeline both write to the SAME
`FrameSlot` (single-slot Arc<Mutex<Option<...>>>). On
`OpenClipPreview` the source player pauses (no more frames written),
THEN the preview pipeline starts (begins writing). On `ClosePreview`
the preview pipeline stops, then the source player can play again
(unpauses NOT done — match v1; user re-presses Space). The handover
must be ordered: `pause source player` → `wait for last frame to
flush` → `spawn preview pipeline`. Otherwise a race delivers a
preview frame followed by a stale source frame.

**4. Strokes-in-compositor coordinate space.** Phase 8 stored stroke
points normalized to [0,1] against the displayed (post-letterbox)
video rect. The compositor renders into a fixed-size output frame
(say 1920x1080). Stroke vertices need to be transformed from
[0,1]-relative to the source video aspect-ratio rect within the
output canvas. Concretely: if export resolution is 1920x1080 and the
source is also 16:9, [0,1] maps to [0,1920] x [0,1080]. If a future
export targets 1080x1920 (vertical) for a 16:9 source, strokes letter
box too. Phase 9 ships only 16:9 → 16:9, but the shader should accept
the active rect as a uniform so the math is in one place.

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

---

## Tasks (~7 total — split across two sub-agent dispatches)

### Task 0: Preflight — bus shapes + AppMode extension + tracing targets

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/event_layer.rs`
- Modify: `crates/video-coach-app/src/frame_sink.rs` (extend
  `RecordingMode` enum mirror — add a `PreviewClip` variant).

**Add to `Command`:**
- `OpenClipPreview { clip_id: String }` (UUID as string per existing
  serde shape).
- `ClosePreview`.

**`AppMode` gains `PreviewClip(Uuid)` variant.** Drop `#[derive(Copy)]`
from `AppMode`; switch to `Clone`. Update every read site that
expects `Copy` (mostly `*current_mode = ...` patterns). Cargo
clippy catches the rest.

**`FORWARDED_TARGETS` gains `clip_preview.lifecycle`**. Per
adversarial fix #1, every event in this phase namespaces under
`clip_preview.*` — never `preview.*` (would collide), never
`recording.*`.

**Bus serde unit tests** for the two new commands + the AppMode
variant.

**Update PROGRESS.txt + commit + SHA-fill follow-up.**

---

### Task 1: Compositor strokes — extend `compose()` API + new wgpu pass

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs`.
- Create: `crates/video-coach-compositor/src/shaders/strokes.wgsl`.
- Modify: `crates/video-coach-compositor/src/lib.rs` (re-exports if
  any).
- Modify: `crates/video-coach-media/src/compose.rs` — Phase 5 export
  pipeline gains a `&[]` pass for strokes (no strokes during the
  Phase 5 → Phase 9 transition).

**API change:**
```rust
pub fn compose(
    &self,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke], // re-export from video-coach-core
) -> Result<Frame, CompositorError>;
```

**Stroke pass:** new wgpu pipeline that takes a vertex buffer of
stroke points (one VBO per stroke, line-strip primitive) + a uniform
(stroke color, stroke width, active-rect bounds for letterbox math
per fix #4) and renders on top of the PiP-composited output. v1's
StrokeReplayLayer uses CALayer with a CGPath; ours is GPU-rendered
lines, anti-aliased via a fragment shader that does perpendicular
distance + smoothstep. Width: ~4 px on output. Color: white with 80%
alpha.

**Tests:**
- New golden-frame test in `video-coach-compositor`: `compose` with
  one stroke should differ from `compose` with no strokes; check that
  pixels along the stroke path differ from the no-stroke output.

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
        frame_sink: Box<dyn FrameSink>,
    ) -> Result<Self, PreviewPipelineError>;

    pub fn play(&self) -> Result<(), PreviewPipelineError>;
    pub fn pause(&self) -> Result<(), PreviewPipelineError>;
    pub fn seek(&self, record_time_seconds: f64, accurate: bool)
        -> Result<(), PreviewPipelineError>;
    pub fn snapshot(&self) -> PlayerSnapshot; // same shape as Phase 7
}
```

**Inside `open()`:**
1. Use `playback_segments(clip, source_duration)` to get the
   `Vec<PlaybackSegment>` for the clip.
2. **Pre-decode freeze frames** (per fix #6) — for each `Freeze`
   segment, decode one frame at `segment.source_start` from the
   source video. Use `gst-launch`-style filesrc → decodebin → seek
   → appsink → grab one buffer → close. Run in `spawn_blocking`
   throughout. Store as `HashMap<usize, Frame>`.
3. Build the GStreamer composition pipeline:
   - Source decoder (filesrc → decodebin → videoconvert → RGBA
     appsink), seekable.
   - Webcam decoder (filesrc on the recording.mov → decodebin →
     videoconvert → RGBA appsink + audio sink chain).
   - A driver task picks the source frame per output time (live
     decode for `Play`, frozen frame for `Freeze`), pulls the
     concurrent webcam frame, computes strokes via
     `visible_strokes_at(events, record_time)`, calls
     `compositor.compose(source, webcam, &strokes)`, pushes to the
     `FrameSink`.
4. Audio: webcam audio plays through the platform sink (or fakesink
   under VIDEO_COACH_NO_AUDIO). v1 also has a source-volume +
   commentary-volume mix; Phase 9 ships commentary-only (webcam audio
   passes through; source video audio is muted during preview to
   match v1's "preview commentary" mode default). Future patch can
   add the live volume mix.

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
3. Refuse if `current_mode` isn't `Scanning` (preview during recording
   = bad UX). Mirror `is_recording()` style: a centralized
   `is_busy()` that says "is the bus mid-op" → returns true if mode
   != Scanning OR recording_clip is some.
4. Find clip by id in `project.clips`. Error if missing.
5. Resolve `source_path = canonicalize(folder.join(clip's source
   ref).path)`. Resolve `recording_path =
   folder.join("recordings").join(clip.recording_filename).
   canonicalize()`.
6. Pause source player (per fix #3 — order matters, do this before
   spawning preview).
7. `spawn_blocking(|| PreviewPipeline::open(...))`. On success:
   - `current_preview = Some(Arc::new(pipeline))`.
   - `current_mode = AppMode::PreviewClip(clip_id_uuid)`.
   - `RecordingStateSlot` updated to mode = PreviewClip.
   - `tracing::info!(target: "clip_preview.lifecycle", event =
     "clip_preview.opened", clip_id, source = ..., recording = ...)`.
8. Failure: emit `clip_preview.failed` with the error; mode stays
   Scanning; player stays paused (won't auto-resume per fix #9 —
   user pressed "Open" then it failed; better not to resume).

**ClosePreview handler:**
1. Refuse if mode isn't PreviewClip.
2. Tear down `current_preview` (drop the pipeline; gstreamer state
   transitions to Null on drop).
3. Mode → Scanning. Slot updated.
4. Source player NOT auto-resumed (fix #9). User re-presses Space.
5. `tracing::info!(... event = "clip_preview.closed" ...)`.

**Existing `Play` / `Pause` / `Seek` commands**: route to
`current_preview` when in PreviewClip mode, to `current_player`
otherwise. Single-line dispatch.

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
8. Wait for `clip_preview.closed`.
9. Quit cleanly.

The full frame-counting parity is in the unit-level
`preview_pipeline_smoke` (Task 2). The harness test just verifies the
control-plane lifecycle works end-to-end.

**Update PROGRESS.txt + commit.**

---

### Task 6: Single-frame preview-vs-export parity check

**Files:**
- Create: `crates/video-coach-media/tests/preview_export_parity.rs`.

Builds the same input frame (source + webcam + one stroke at a known
position), runs through `compositor.compose(..., &strokes)` once, and
also through a 1-frame `PreviewPipeline` instance. Asserts byte-for-
byte equality on the output Frame's RGBA buffer.

This is the **Phase 9 down-payment on the visual parity test**. The
full N-frame "preview hash == export hash" lands in Phase 10 once
batch export is wired up.

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
