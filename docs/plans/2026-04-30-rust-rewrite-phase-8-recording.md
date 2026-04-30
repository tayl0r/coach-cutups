# Rust Rewrite — Phase 8: Recording Integration

> **For Claude:** This phase is implemented by a fresh sub-agent (per
> the durable feedback memory). The sub-agent reads this plan + the
> design doc + Phase 7's plan to learn the patterns we've established.

**Goal:** R-press starts a webcam+mic recording, captures stroke events
drawn over the source video, and on stop produces a `Clip` entry in
`project.json`. Full clip lifecycle in the Rust port; brings the v1
"Mode B" workflow online.

**Architecture:** A new `AppMode` state machine lives in the bus task
(alongside `current_player`, `recording`, `current`). UI dispatches
`StartClipRecording` / `StopClipRecording` bus commands; bus
transitions mode (`Scanning → RecordingStarting → Recording →
Scanning`) and emits `mode.changed` events. On `StartClipRecording`
the bus pauses the source player, snapshots the playhead, derives a
clip filename + output path under `<project>/recordings/`, starts the
capture pipeline, and creates a fresh `RecordingController` that
collects timestamped event entries (`stroke`, `play`, `pause`, `skip`,
`clear_all` — same shape `video-coach-core::CommentaryEvent` already
defines). On `StopClipRecording` the bus stops the capture pipeline,
finalizes a `Clip` (id, sourceIndex, startSourceSeconds, duration,
filename, events, sortIndex), appends it to `project.clips`, persists
`project.json`, transitions back to `Scanning`.

The `PlatformDefault` source variant on `Command::StartRecording`
(currently "not yet implemented") gets a real macOS implementation via
GStreamer's `avfvideosrc` + `osxaudiosrc`. Windows + Linux versions
land via `mfvideosrc` / `v4l2src` + `wasapisrc` / `pulsesrc` in
parallel; CI test runners stay on `FixtureSource` so no camera
permission is needed on a green build.

**Locked-in scope:**
1. **Stroke capture = events only, no drawing yet.** Mouse drag over
   the video surface during `Recording` mode produces a sequence of
   normalized `(x, y, t)` points → one `Stroke` per drag → one
   `CommentaryEvent { kind: Stroke }`. On-screen rendering of the
   stroke line lands in **Phase 8.5** (small follow-up phase) since
   it requires either a Slint Canvas/Path layer or a wgpu overlay.
2. **macOS-first for `PlatformDefault`.** Windows + Linux platform
   capture is included but only tested in CI via FixtureSource. The
   user's daily driver is macOS; other platforms get a smoke build.
3. **No clip preview yet.** Clips land in `project.clips`. Phase 9
   wires preview-on-click + stroke replay.

---

## Required reading (in order, by the sub-agent)

1. This plan, top to bottom.
2. `docs/plans/2026-04-28-rust-rewrite-design.md` — the architecture.
3. `docs/plans/2026-04-30-rust-rewrite-phase-7-source-transport.md`
   — patterns established (bus refactor for `current_player`, the
   shared slot pattern, position-poll task, harness E2E shape,
   adversarial-review-fix style).
4. Current state of:
   - `crates/video-coach-app/src/bus.rs` — where the new mode + clip
     handlers go. Phase 7 left the file 900+ LOC; if it gets
     unwieldy, factor out `bus/recording.rs` etc.
   - `crates/video-coach-media/src/recording.rs` — Phase 3's recording
     pipeline (FixtureSource works; `PlatformDefault` is the
     `not yet implemented` arm in `bus.rs::Command::StartRecording`).
   - `crates/video-coach-media/src/source.rs` — `CaptureSourceFactory`
     trait Phase 3 added.
   - `crates/video-coach-app/src/ui.rs` — Phase 7's keyscope handles
     Space + arrows; Phase 8 adds `r`.
   - `crates/video-coach-app/src/frame_sink.rs` — Phase 7's
     `PlayerStateSlot`. Phase 8 will add a `RecordingStateSlot`
     alongside it (mode + elapsed seconds + REC indicator state).
   - `crates/video-coach-core/src/event.rs` — `CommentaryEvent` shape.
   - `crates/video-coach-core/src/project.rs` — `Clip` struct shape.
   - `App/Recording/RecordingController.swift` — v1 reference for the
     event-log model. The Rust version mirrors this 1:1.
   - `App/ContentView.swift` lines 452–653 — v1's start/stop flow
     with the source-pause-on-R-press detail Phase 8 must reproduce.

---

## Tasks (estimated 6 tasks + closeout = 7)

### Task 0: Preflight — AppMode + new command shapes + tracing targets

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/event_layer.rs`
- Modify: `crates/video-coach-app/src/frame_sink.rs` (add
  `RecordingStateSlot`).

**Add to `Command` enum (serde shape only; impls in later tasks):**
- `StartClipRecording` (no params).
- `StopClipRecording` (no params).
- (Keep `StartRecording` / `StopRecording` for the lower-level
  fixture-driven tests.)

**Add an `AppMode` enum** alongside `Command`:
```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AppMode {
    Scanning,
    RecordingStarting,
    Recording,
}
```

**Add to `FORWARDED_TARGETS`:** `"recording.lifecycle"` (mode
transitions + start/stop) — distinct from existing `"recording"`
which is the lower-level pipeline events.

**`RecordingStateSlot`** (in `frame_sink.rs`, alongside
`PlayerStateSlot`): `Arc<Mutex<RecordingStateData>>` carrying mode +
`recording_started_at_host: Option<Instant>` (so the UI can compute
elapsed time at display rate without a separate poll task).

**Tests:** serde roundtrip for the two new commands + AppMode enum
(camelCase / snake_case as applicable).

**Update PROGRESS.txt** flipping Task 0's `[ ]` to `[x]` after commit.

---

### Task 1: AppMode state machine + StartClipRecording handler

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`

Bus task gains `current_mode: AppMode` and (when feature = "media")
`recording_clip: Option<RecordingClipInProgress>` containing:
- `clip_id: Uuid`
- `filename: String` (`clip-<uuid>.mov`)
- `output_path: PathBuf` (`<project>/recordings/<filename>`)
- `source_index: usize` + `start_source_seconds: f64` (snapshot at R-press)
- `t0_host_seconds: f64` (`SystemTime::now()` or `Instant::elapsed`)
- `events: Vec<CommentaryEvent>` (appended to during recording)

**StartClipRecording handler:**
1. Refuses unless `current_mode == Scanning`. Errors otherwise.
2. Refuses unless a project is open + has `sourceVideos[0]`.
3. Pauses the source player (player.pause()).
4. Snapshots the playhead via `player.snapshot().position_seconds`.
5. Builds the `RecordingClipInProgress` record.
6. Writes RecordingState slot: mode = RecordingStarting, started_at = now.
7. Calls `video_coach_media::recording::start` with
   `PlatformDefault` source factory.
8. On success, transitions mode to `Recording`, tracing event
   `recording.started` with clip_id, filename, source_seconds.

**StopClipRecording handler:**
1. Refuses unless `current_mode == Recording`.
2. Calls existing `Recording::stop` (spawn_blocking).
3. Builds a `Clip` record: id, name (mm:ss format from
   `start_source_seconds`), source_index, start_source_seconds,
   recording_duration (returned by stop), recording_filename, events,
   sort_index = `project.clips.len()`.
4. Appends to `project.clips`; persists via
   `project_store::write` (spawn_blocking).
5. Transitions mode to `Scanning`. Updates RecordingState slot.
6. Emits `recording.stopped` event with clip_id + duration.

**Update PROGRESS.txt + commit.**

---

### Task 2: PlatformDefault source factory (macOS first)

**Files:**
- Modify: `crates/video-coach-media/src/source.rs`
- Create: `crates/video-coach-media/src/platform_source.rs`
- Modify: `crates/video-coach-media/src/lib.rs`

Implement `PlatformDefaultSource: CaptureSourceFactory` that wires
the platform-native GStreamer elements:

| Platform | Video src | Audio src |
|---|---|---|
| macOS | `avfvideosrc` (default device) | `osxaudiosrc` |
| Windows | `mfvideosrc` | `wasapisrc` |
| Linux | `v4l2src device=/dev/video0` | `pulsesrc` |

Selected by `cfg(target_os)` at compile time. macOS gets the most
testing in this phase; Windows + Linux ship a working build but rely
on FixtureSource for harness E2E (no camera in CI).

The `bus::Command::StartRecording` handler's `PlatformDefault` arm
swaps from "not yet implemented" to actually wiring this factory in.

**Phase 3 reuse note:** the existing recording pipeline already mux'es
two independent appsink/audiosink streams into a fragmented `.mov`.
Task 2 only adds the source factory; the rest of the pipeline is
untouched.

**Tests:** A new `platform_source_smoke` integration test (gated
`cfg(target_os = "macos")`, ignored by default — runs only with
`cargo test --features media -- --ignored platform_source_smoke`).
Records 1s of webcam, asserts the .mov is non-trivial. Skipped in CI.

**Update PROGRESS.txt + commit.**

---

### Task 3: UI — R key + REC indicator + elapsed timer

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`

**MainWindow gains:**
- `in property <string> mode: "scanning"` (one of
  "scanning", "recording_starting", "recording")
- `in property <float> recording-elapsed-seconds: 0`
- `callback record-toggled()` (start or stop based on current mode)

**FocusScope adds:**
```slint
if (event.text == "r") {
    root.record-toggled();
    return accept;
}
```

**Visual:**
- A small red dot (12 px) + "REC" + elapsed `M:SS` timer at top-left,
  visible only when `mode != "scanning"`. Yellow + "Preparing…"
  during `recording_starting`.

**Frame timer extension:** the existing 30 Hz Slint Timer reads the
new `RecordingStateSlot`, computes elapsed = `now - started_at`,
updates `mode` + `recording-elapsed-seconds` properties.

**`on_record_toggled`** in ui.rs:
- Read current mode off the property.
- If `scanning`: dispatch `StartClipRecording`.
- If `recording`: dispatch `StopClipRecording`.
- If `recording_starting`: ignore (mid-transition).

**Update PROGRESS.txt + commit.**

---

### Task 4: Stroke event capture (events only, no drawing)

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/ui.rs`

**Slint:** the `Image` source-frame element gains a TouchArea overlay
that's enabled only when `mode == "recording"`. Mouse press starts a
new stroke; `moved while pressed` accumulates points; release
finalizes. Stroke points are emitted via a callback
`stroke-completed(points: [{ x: float, y: float, t: float }])`.

(Slint doesn't support arrays-of-records cleanly in callbacks; in
practice we'll emit one callback per point and have the UI assemble
the stroke, OR ship a single callback with a JSON-encoded string.
Sub-agent picks the cleanest approach for Slint 1.16 — see "Risks"
below.)

**Bus:** new `Command::AppendStroke { points: Vec<StrokePoint> }`
that appends a `CommentaryEvent { kind: Stroke(...) }` to the active
`recording_clip.events`. Errors if `current_mode != Recording`.

**Captured points:** normalized to `[0..1]` against video surface
size so strokes replay correctly at any zoom level. `t` is seconds
since `t0_host_seconds`.

**Update PROGRESS.txt + commit.**

---

### Task 5: Harness E2E — full record-clip flow against fixture

**Files:**
- Modify: `crates/video-coach-harness/tests/open_project_smoke.rs` (or
  new file `record_clip_smoke.rs` if it grows large).

Test:
1. New temp project + add a source video.
2. Send `start_clip_recording` with the bus's PlatformDefault source
   replaced by a FixtureSource path. **Open question for sub-agent**:
   how to swap the source factory at runtime? Probably easiest to
   add a `--fixture-recording-source=PATH` CLI flag that the harness
   passes; bus reads the flag at startup and uses FixtureSource for
   all subsequent StartRecording calls.
3. Wait for `recording.started` event.
4. Send `append_stroke` with synthetic points.
5. Sleep 1s.
6. Send `stop_clip_recording`.
7. Wait for `recording.stopped` event with clip_id + duration ≈ 1s.
8. Read project.json off disk; verify `clips[0]` has expected
   filename, source_index = 0, recording_filename starting with
   `clip-`, and a Stroke event in events.
9. Verify the recording file exists at `<project>/recordings/<filename>`
   and is non-trivial (>10 KB).

**Update PROGRESS.txt + commit.**

---

### Task 6: Closeout

- Run `cargo build --workspace` (default), `--no-default-features`,
  `--features media`.
- Run `cargo test --workspace` and `cargo test --workspace --features
  media`.
- Run `cargo clippy --workspace --all-targets --features media --
  -D warnings` AND `cargo clippy --workspace --exclude
  video-coach-media --all-targets -- -D warnings` (the no-media
  variant — Phase 7 closeout taught us local clippy with media
  features doesn't catch the no-media build's lints).
- Run `cargo fmt --check`.
- `git push` + verify CI green via `gh run list --branch rust-rewrite
  --limit 1` then `gh run view <id>`.
- Append a closeout section at the bottom of THIS plan file, mirroring
  Phase 7's closeout shape (commits table + adversarial-fix
  verification + outstanding follow-ups).
- Mark Phase 8 SHIPPED in PROGRESS.txt.

---

## Adversarial-review fixes baked in

The main session ran an adversarial review on this plan; the following
fixes are non-negotiable. Sub-agent: every one of these must be
present in the shipped code.

1. **Playhead snapshot happens in the UI, not the bus.** The
   `StartClipRecording` command gains a `playhead_snapshot_seconds:
   f64` field. The UI's `on_record_toggled` callback reads
   `player_state_slot.lock().position_seconds` and passes it in. The
   bus uses that value directly for `start_source_seconds` — does
   NOT re-read after the async `player.pause()` round-trip (which can
   take 10–200 ms during which the source has moved on).

2. **Mode mutations stay on the bus task thread.** Inside
   `try_spawn_clip_recording`, `recording::start` runs in
   `spawn_blocking`. After the `await` returns, the bus task code
   (still inside `handle()`) writes `current_mode` and the
   `RecordingStateSlot`. **Never** mutate mode or `recording_clip`
   from inside a `spawn_blocking` closure — those mutations must run
   on the bus task. (Same pattern Phase 7's `try_spawn_current_player`
   already follows.)

3. **`PlatformDefaultSource` honors `VIDEO_COACH_NO_AUDIO`.** When
   the env var is set, substitute `audiotestsrc` for the platform
   audio source (`osxaudiosrc` / `wasapisrc` / `pulsesrc`). Mirrors
   Phase 7's `source_player.rs::platform_audio_sink_name` pattern
   exactly. Without this, `record_clip_smoke` will hang on Linux CI
   the same way `play_pause_seek_roundtrip_via_harness` did before
   Phase 7's late-CI patch.

4. **Recording duration computed on the bus side, not from
   `Recording::stop`.** `Recording::stop`'s signature
   (`fn stop(self) -> Result<(), RecordingError>`) returns no
   duration. Add `t0_instant: Instant` to
   `RecordingClipInProgress`; compute
   `recording_duration = t0_instant.elapsed().as_secs_f64()` right
   before calling `stop()`. Do not modify `recording.rs`'s public
   API.

5. **Stroke-point normalization spec (concrete, no "port the math"):**
   Given video aspect `va = video_w / video_h` and container
   `(cw, ch)`, the displayed rect under `image-fit: contain` is:
   ```
   if cw / ch >= va:
       rw = ch * va; rh = ch
   else:
       rw = cw; rh = cw / va
   ```
   Centered offsets: `ox = (cw - rw) / 2`, `oy = (ch - rh) / 2`.
   Normalized point: `x = (touch_x - ox) / rw`, `y =
   (touch_y - oy) / rh`. **Clamp to [0, 1] AFTER letterbox
   compensation, not before** (clamping the raw touch coordinates
   would lose strokes that the user drew exactly on the letterbox
   boundary). Drop strokes that fall entirely outside the active
   rect (likely a UI dispatch bug; log + ignore).

6. **Stroke callback approach: JSON-string single callback.**
   `stroke-completed(points-json: string)` fires once per drag-release
   with the array of points encoded as JSON. UI accumulates points
   internally during the drag; release serializes + emits. Lower bus
   traffic than per-point dispatch, no Slint `ModelRc` plumbing.

7. **Centralized `is_recording()` helper.** Add to bus.rs:
   ```rust
   #[cfg(feature = "media")]
   fn is_recording(
       recording: &Option<Recording>,
       recording_clip: &Option<RecordingClipInProgress>,
       current_mode: AppMode,
   ) -> bool {
       recording.is_some() || recording_clip.is_some()
           || matches!(current_mode, AppMode::Recording | AppMode::RecordingStarting)
   }
   ```
   Both `StartRecording` (low-level fixture-driven) and
   `StartClipRecording` (UI-driven) check this before starting. Stops
   the harness from accidentally double-starting.

8. **Slot read order in the UI 30 Hz timer:** read
   `RecordingStateSlot` BEFORE `PlayerStateSlot`. So when a recording
   stops the "no longer recording" REC indicator clears in the same
   frame as the player resumes, rather than the player updating one
   tick before the indicator (visually distracting).

9. **Shutdown during recording: accepted as-is.** If the user quits
   while `Recording`, the runtime drops mid-`Recording::stop`, the
   `qtmux` may not flush the `moov` atom, and the `.mov` may be
   unplayable. v1 has the same problem. Sub-agent: do NOT try to
   "fix" this with complex async shutdown hooks; document the
   accepted behavior in Task 6 closeout.

10. **Camera permission is blocking + UX is terminal on first run.**
    `avfvideosrc` pipeline construction blocks on the macOS permission
    prompt (Allow / Deny). On Deny, `recording::start` returns Err;
    bus emits `recording.failed` with the error and transitions back
    to `Scanning`. Sub-agent: the bus must NOT panic, must NOT leave
    `current_mode` stuck in `RecordingStarting`, must roll back the
    source-player pause if appropriate (or: leave paused — match v1).

---

## Risks / unknowns (sub-agent may need to make calls)

1. **PlatformDefault source on macOS at runtime.** The user has not
   yet granted camera permission to the binary. First launch may
   prompt. Document this in the closeout; CI never hits the path.
2. **`avfvideosrc` caps negotiation.** macOS reports unusual default
   formats (e.g. `kCVPixelFormatType_2vuy`). The pipeline already
   has `videoconvert` → RGBA so this should be fine, but verify the
   first real test run.
3. **Stroke points across the Slint callback boundary.** Slint 1.16
   doesn't ergonomically pass `Vec<Struct>` through callbacks.
   Sub-agent may end up:
   - emitting one callback per point + having the UI build the
     stroke in Rust, OR
   - serializing the stroke as a JSON string to a single string
     callback, OR
   - using `slint::ModelRc<...>` if the API supports passing it
     cleanly. Whichever is simplest, document in commit.
4. **Mouse-coordinate mapping.** The video surface uses
   `image-fit: contain`, so the displayed image may be letterboxed.
   Stroke point normalization needs to account for the rendered
   rectangle, not the parent's full extent. Sub-agent: compute the
   active rect from `Image` metrics; v1's `DrawingOverlay.swift`
   already solves this — port the math.
5. **Source player pause-on-R + resume-on-stop.** v1 pauses on R-press
   and **does not resume on stop** (user explicitly resumes). The
   plan follows this — no resume.
6. **`recording_clip` cleanup on errors.** If `Recording::stop`
   fails, the `recording_clip` and the on-disk .mov are
   half-finalized. Plan: leave the .mov on disk + clear
   `recording_clip` + transition mode back to Scanning + emit
   `recording.failed` event with the error. Sub-agent: don't write
   project.json with a half-finished clip.

---

## Done when

- All 7 tasks committed.
- CI matrix green on macOS / Linux / Windows.
- New `record_clip_smoke` harness test passing.
- New `platform_source_smoke` test passing (manually, ignored by
  default; sub-agent runs once + records the result in the closeout).
- No regressions in existing Phase 1–7 tests.
- PROGRESS.txt reflects each task's completion + the phase SHIPPED
  line.
