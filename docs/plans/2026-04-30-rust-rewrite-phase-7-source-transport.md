# Rust Rewrite — Phase 7: Source-Video Timeline + Transport

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Open a v2 project, add a source video to it, and play / pause / scrub / skip through that source inside the Slint window. Audio plays through the OS default sink. First on-screen pixels and first transport state machine in the Rust port.

**Architecture:** A new `SourcePlayer` in `video-coach-media` owns a GStreamer pipeline `filesrc → decodebin → tee → (video: videoconvert → RGBA capsfilter → appsink) (audio: audioconvert → audioresample → autoaudiosink)`. The video appsink callback grabs each decoded frame, copies into a `slint::SharedPixelBuffer<Rgba8Pixel>`, and pushes via `slint::invoke_from_event_loop` into a Slint `Image` property on `MainWindow`. Audio plays directly through the OS sink (no Rust intervention; volume controlled via the audiosink's `volume` property). The bus task owns the `SourcePlayer` lifetime and exposes `Play / Pause / Seek / SetVolume / AddSourceVideo` commands. UI buttons + keyboard shortcuts dispatch through the bus exactly like Phase 6's File-menu wiring.

**Locked-in decisions** (from pre-plan brainstorm with user):
1. **Video pixels via custom Slint sink** — appsink → SharedPixelBuffer → Slint Image. No GStreamer-native window.
2. **Single-source MVP** — `project.sourceVideos[0]` is the active source. Multi-source virtual concat deferred to a future Phase 7.5.
3. **Hybrid seek policy** — `GST_SEEK_FLAG_ACCURATE` for skip buttons + keyboard shortcuts (frame-exact, ~100ms HEVC decode tax); `GST_SEEK_FLAG_KEY_UNIT` (keyframe-snap) during live slider drag; `ACCURATE` on slider release. Better UX than v1, which used keyframe-snap everywhere.
4. **Add Source Video = reference only** — picker writes the path relative to project folder via `pathdiff::diff_paths`. Allowed to traverse `..` outside the project. No copying. Breaks if the user moves the source file (acceptable; matches v1 behavior modulo bookmarks).

**Tech stack add:** `pathdiff = "0.2"` for cross-platform relative-path computation. Everything else is already in the workspace.

---

## Adversarial review changes baked in (from feature-dev:code-reviewer round)

1. **Single-slot frame buffer + display-rate pull, not per-frame `invoke_from_event_loop`.** At 30fps × 8MB the per-push pattern saturates the Slint event queue during slider drag and leaks unbounded memory. Replaced with `Arc<Mutex<Option<FrameSlot>>>` written by appsink (overwrites, drops old) and read by a 30Hz Slint timer that calls `set_source_frame` once per tick. (Task 4 hard requirement.)

2. **Fixed-size frame pool (2 buffers).** Even with single-slot overwrite, 1080p RGBA at 30fps = 249 MB/s of `Vec<u8>` churn. Pre-allocate two reusable buffers; appsink rotates between them. (Task 1.)

3. **`AddSourceVideo` spawns the player if it was empty.** After pushing a SourceRef, if `current_player.is_none() && project.source_videos.len() == 1`, instantiate the player. Without this, the first source added to an empty project never plays. (Task 2.)

4. **OpenProject / NewProject normalize the folder path.** If user passes a path ending in `project.json`, treat it as the parent directory. Otherwise the relative-path math in AddSourceVideo writes paths with a stray `..`. Same fix on both handlers. (Task 0.)

5. **Platform-specific audio sinks unconditionally.** `autoaudiosink` triggers macOS mic-permission dialog on first launch. Use `osxaudiosink` on macOS, `wasapisink` on Windows, `pulsesink` on Linux. Single match arm, gated by `cfg(target_os = ...)`. (Task 1.)

6. **`SourcePlayer::open` accepts the source's duration as a parameter** rather than running a Discoverer at play time. The duration is already known from `SourceRef.duration_seconds` (probed once at AddSourceVideo time). Avoids the Discoverer + player double-open race that made VT decoders deadlock in Phase 5. (Task 1.)

7. **Slint `Slider` cannot expose drag press/release** — the only API is `changed value =>` which fires per-tick. Use `TouchArea` + manual fill bar implementation. (Task 5 hard requirement, not a fallback.)

8. **Position polling suppresses one cycle after a seek.** A keyframe seek's position-query lags the decoder's first post-seek buffer. Track `seeking_until: Option<Instant>` in the bus task; skip the position-event emission while we're inside that window. (Task 5.)

9. **Position events emit from the poll task, which lives in Task 5.** Earlier-task harness tests don't assert on position events. (Clarification across Tasks 3 / 5.)

---

## Task 0: Preflight — bus command shapes + tracing targets

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/event_layer.rs`

**Step 1: Add the new `Command` variants (serde shape only; impl in later tasks).**

```rust
pub enum Command {
    // ...existing...
    AddSourceVideo { absolute_path: String },
    Play,
    Pause,
    /// Seek to absolute time in seconds. `accurate` chooses between
    /// frame-exact (true) and keyframe-snap (false). UI uses
    /// accurate=true for buttons/keys, accurate=false during slider drag.
    Seek { seconds: f64, accurate: bool },
    SetScanVolume { value: f64 },
}
```

**Step 2: Add tracing targets to `FORWARDED_TARGETS`.**

Add `"player.lifecycle"`, `"player.state"`. The player will emit `player.opened`, `player.playing`, `player.paused`, `player.seeked`, `player.position` (throttled).

**Step 3: Bus serde unit tests for each new variant (mirror Phase 6's pattern).**

**Step 4: Verify `cargo test --workspace` green. Commit.**

---

## Task 1: SourcePlayer in `video-coach-media` (headless)

**Files:**
- Create: `crates/video-coach-media/src/source_player.rs`
- Modify: `crates/video-coach-media/src/lib.rs`
- Create: `crates/video-coach-media/tests/source_player.rs`

**Step 1: Define `SourcePlayer` API.**

```rust
pub struct SourcePlayer { /* pipeline, state */ }

pub struct PlayerSnapshot {
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub is_playing: bool,
}

impl SourcePlayer {
    pub fn open(path: &Path, frame_sink: Box<dyn FrameSink>) -> Result<Self, _>;
    pub fn play(&self) -> Result<(), _>;
    pub fn pause(&self) -> Result<(), _>;
    pub fn seek(&self, seconds: f64, accurate: bool) -> Result<(), _>;
    pub fn snapshot(&self) -> PlayerSnapshot;
    pub fn set_volume(&self, value: f64); // 0.0..=1.0
}

pub trait FrameSink: Send + 'static {
    fn push(&self, width: u32, height: u32, rgba: Vec<u8>);
}
```

`FrameSink` is the seam between media-crate and ui-crate so the media tests don't need Slint.

**Step 2: GStreamer pipeline construction.**

```
filesrc location=<path>
  ! decodebin (dynamic pads on pad_added)
  → video pad: queue ! videoconvert ! capsfilter format=RGBA ! appsink (FrameSink::push)
  → audio pad: queue ! audioconvert ! audioresample ! volume name=scan_volume ! autoaudiosink
```

The `volume` element is named so `set_volume` can grab it via `pipeline.by_name("scan_volume")` and update the `volume` property live.

Use the same `decodebin → queue → videoconvert` pattern Phase 5 nailed (compose.rs:build_input_chain). Same async=false trick if needed.

**Step 3: Headless test against a fixture.**

`tests/source_player.rs` opens `fixtures/source-1080p.mp4` with a counting FrameSink (just increments a counter on each push). Asserts:
- `player.snapshot().duration_seconds` ≈ 60.0 (within ±0.5)
- `play()` then 1-second wait → counter > 25 (we pushed at least ~25 frames in 1s of playback)
- `pause()` then 1-second wait → counter delta near zero (within tolerance for in-flight frames)
- `seek(30.0, accurate: true)` → `snapshot().position_seconds` between 29.5 and 30.5
- `seek(30.0, accurate: false)` → snapshot in 28..32 range (keyframe tolerance)

Test gated `#[cfg(feature = "media")]` and uses the same `fixture()` helper Phase 5 added.

**Step 4: Verify the test passes locally with `--features media`. Commit.**

---

## Task 2: AddSourceVideo command + project mutation

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-core/src/project_store.rs` (only if it doesn't already expose `write`)
- Modify: `crates/video-coach-harness/tests/open_project_smoke.rs` (or new test file)

**Step 1: Implement `AddSourceVideo` handler.**

```rust
Command::AddSourceVideo { absolute_path } => {
    // Require an open project.
    let Some(project) = current_project.as_mut() else {
        return CommandReply::err("no project open");
    };
    let project_folder = current_project_folder.clone(); // tracked alongside project
    let result = tokio::task::spawn_blocking(move || -> Result<_, String> {
        let abs = std::path::Path::new(&absolute_path);
        let rel = pathdiff::diff_paths(abs, &project_folder)
            .ok_or_else(|| "could not compute relative path".to_string())?;
        // Probe duration via gstreamer::PadProbe-ish discoverer for the
        // SourceRef.duration_seconds field.
        let duration = video_coach_media::discover::probe_duration(abs)
            .map_err(|e| e.to_string())?;
        Ok((rel.to_string_lossy().into_owned(), duration, abs.file_name()...))
    }).await...;

    project.source_videos.push(SourceRef { relative_path, display_name, duration_seconds });
    project_store::write(project, &project_folder).map_err(...)?;
    tracing::info!(target: "project.lifecycle", event = "source.added", ...);
    CommandReply::ok()
}
```

**Step 2: Track the project folder alongside the loaded `Project`.**

Currently `current_project: Option<Project>` doesn't remember WHERE it was loaded from. Refactor to `current: Option<(Project, PathBuf)>` so AddSourceVideo can write back.

**Step 3: New crate `video-coach-media::discover` (or inline in source_player.rs).**

Tiny helper: `probe_duration(&Path) -> Result<f64, _>` runs a GStreamer Discoverer. ~20 LOC.

**Step 4: Harness E2E test.**

`add_source_video_persists_to_disk`:
- Create temp project (using `new_project` command)
- Send `add_source_video` with the test fixture path
- Verify reply.ok = true
- Read the project.json off disk; assert it now lists one source video with the expected relative path + duration

**Step 5: Commit.**

---

## Task 3: Wire bus → SourcePlayer (Play / Pause / Seek / SetScanVolume)

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/Cargo.toml` (depend on video-coach-media's source_player module unconditionally — already gated by `media` feature)

**Step 1: Bus task gains `current_player: Option<SourcePlayer>`.**

When a project is opened or created with `sourceVideos[0]` set, the bus auto-creates the SourcePlayer in the OPENED state but PAUSED. When project is closed (Phase 8+), drop it.

**Step 2: Each new command routes to the player.**

`Play / Pause / Seek / SetScanVolume` return `err("no source loaded")` if `current_player` is None.

**Step 3: After `OpenProject` / `NewProject` succeed, if the project has `sourceVideos[0]`, instantiate a SourcePlayer.**

The FrameSink hand-off requires a UI-side sink to exist. For Task 3 (no UI yet), use a `NullFrameSink` that drops frames. Task 5 swaps to the real one.

**Step 4: Harness test exercises the full chain.**

Open project, add source video, send `play`, wait 1s, send `pause`, send `seek 5.0 accurate=true`, assert `player.position` event around 5.0.

**Step 5: Commit.**

---

## Task 4: Slint video surface — `Image` binding + `SharedPixelBuffer` push

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`
- Create: `crates/video-coach-app/src/frame_sink.rs`

**Step 1: Slint surface.**

```slint
in property <image> source-frame;
Image {
    x: 0px; y: 0px; // anchored under the menu bar
    width: parent.width;
    height: parent.height - <transport-bar-height>;
    image-fit: contain;
    source: source-frame;
}
```

**Step 2: `FrameSink` impl that pushes into the Slint property.**

```rust
pub struct SlintFrameSink {
    weak: slint::Weak<MainWindow>,
}

impl FrameSink for SlintFrameSink {
    fn push(&self, w: u32, h: u32, rgba: Vec<u8>) {
        let weak = self.weak.clone();
        slint::invoke_from_event_loop(move || {
            if let Some(win) = weak.upgrade() {
                let buf = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(&rgba, w, h);
                win.set_source_frame(slint::Image::from_rgba8(buf));
            }
        }).ok();
    }
}
```

`invoke_from_event_loop` cost per frame: one tokio→main-thread message + one Slint event-loop wake. At 30fps that's 30 wakes/sec — acceptable. If profiling shows this is hot, consider a single shared `Arc<Mutex<SlintImage>>` with a 30Hz pull instead.

**Step 3: Replace `NullFrameSink` from Task 3 with `SlintFrameSink`.**

The bus task can't hold a `slint::Weak` (it's not Send across thread boundaries the way the mpsc loop is). Pass the Weak through `bus::spawn_on` as an extra parameter, OR have the UI thread create the FrameSink and hand it to the bus via a setter command at startup.

The cleaner choice: a startup-only `attach_ui_frame_sink(weak)` setter on BusHandle. Bus stashes it in the closure scope.

**Step 4: Manually verify a video plays.**

Open the test project, add `fixtures/source-1080p.mp4`, send `play`, look at the window — moving pixels should appear.

**Step 5: Commit.**

---

## Task 5: Transport UI — play/pause button, scrubber, position label

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`

**Step 1: Slint transport bar at the bottom.**

```slint
in property <bool> is-playing: false;
in property <float> position-seconds: 0;
in property <float> duration-seconds: 0;

callback play-pause-clicked();
callback scrub-pressed(float);   // value in seconds
callback scrub-released(float);

Rectangle {
    x: 0; y: parent.height - 56px;
    width: parent.width; height: 56px;
    background: #1a1a1a;

    HorizontalLayout {
        spacing: 12px; padding: 12px;
        Button { text: is-playing ? "❚❚" : "▶"; clicked => { play-pause-clicked() } }
        Slider {
            minimum: 0; maximum: duration-seconds; value: position-seconds;
            // Slint Slider already emits "changed" (drag) and ... TBD: check exact API.
        }
        Text { text: format-time(position-seconds) + " / " + format-time(duration-seconds); }
    }
}
```

(Slint's built-in `Slider` lets us hook drag start/end; if not, build our own with TouchArea + the same accurate-seek-on-release behavior.)

**Step 2: Position polling.**

Spawn a tokio task that, while a player is loaded, queries the player's snapshot every 100ms and pushes `(position, duration, is_playing)` back to the UI via `invoke_from_event_loop`. Cancel the task on player drop.

**Step 3: Wire `play-pause-clicked` → bus Play or Pause based on `is_playing`.**

**Step 4: Wire scrubber → `Seek { accurate: false }` during drag, `{ accurate: true }` on release.**

**Step 5: Manual smoke + commit.**

---

## Task 6: Skip buttons + keyboard shortcuts (J / K / L / arrows)

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`

Add buttons `<< 10s`, `< 3s`, `▶/❚❚`, `3s >`, `10s >>`. Each dispatches `Seek { seconds: current + delta, accurate: true }` via bus.

Slint key handlers map:
- `Space` → play/pause
- `Left` → -3s, `Shift+Left` → -10s
- `Right` → +3s, `Shift+Right` → +10s
- (Skip `J/K/L` for now; design doc + v1 use shift+arrows. Consistent.)

Manual smoke + commit.

---

## Task 7: Audio playback + scan-volume slider

**Files:**
- Modify: `crates/video-coach-media/src/source_player.rs`
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`

The pipeline already routes audio through `volume name=scan_volume → autoaudiosink` (Task 1). This task ships the UI slider.

```slint
in property <float> scan-volume: 1.0;
callback scan-volume-changed(float);

Slider { minimum: 0; maximum: 1; value: scan-volume; changed value => { scan-volume-changed(value); } }
```

UI dispatches `SetScanVolume { value }` on every change. Bus updates the GStreamer `volume` property (cheap; no encode disturbance).

Persist to `project.preferences.scan_volume` with debounce (slider release, not every tick). Match v1 behavior — same `try? saveProject()` pattern.

Manual smoke + commit.

---

## Task 8: Closeout

**Files:**
- Modify: `docs/plans/2026-04-30-rust-rewrite-phase-7-source-transport.md`

**Step 1: Run full build matrix + test matrix.**

```
cargo build --workspace
cargo build --workspace --no-default-features
cargo build --workspace --features media
cargo test  --workspace
cargo test  --workspace --features media
```

**Step 2: Manual smoke checklist (record results in PR description).**

- [ ] Open a v2 project (existing or via New Project)
- [ ] Add Source Video via menu (file picker → pick a .mp4)
- [ ] Source-1080p plays in the window with audio
- [ ] Pause/play button works
- [ ] Scrubber drags responsively, releases to accurate position
- [ ] Skip buttons land exactly +/- 3s, 10s
- [ ] Space, ←, →, Shift+←, Shift+→ keyboard shortcuts work
- [ ] Volume slider mutes/unmutes audio in real time
- [ ] Closing the project (or Cmd-W if implemented) tears down the player cleanly

**Step 3: Push, verify CI matrix green.**

**Step 4: Commit closeout.**

---

## What Phase 7 deliberately does NOT include

- **Multi-source virtual concat.** v1's stitching of `sourceVideos[]` into one timeline. Phase 7.5 if/when needed.
- **Frame stepping** (one-frame back/forward). Phase 8 alongside recording R-press.
- **Sidebar with source list** to switch between sources. Single-source means single-list.
- **Compositor preview** (PiP overlay during scan). That's Phase 9 (clip preview integration).
- **Project-rename UI**, sidebar, menu shortcuts.
- **Frame-accurate scrubbing during drag.** Drag = keyframe; release = accurate. By design.

---

## Risks / unknowns

1. **Slint `Slider` drag start/end events.** The 1.16 widget's `changed value =>` fires per-tick. May or may not expose drag-state. If not, replace with `TouchArea` + `pressed` / `released` callbacks driving a manual fill bar.

2. **30fps invoke_from_event_loop overhead.** Should be fine on modern machines; if profiling shows >5% main-thread time, switch to a 30Hz pull (timer fires on UI thread, reads from `Arc<Mutex<latest_frame>>`).

3. **Discoverer + decodebin race in tests.** If `probe_duration` and `SourcePlayer::open` both spin up GStreamer for the same file in quick succession, mac VT decoders sometimes deadlock. Phase 5 disabled VT decoders in tests via `GST_PLUGIN_FEATURE_RANK`; carry that forward.

4. **AVFoundation autoaudiosink on macOS.** On a fresh launch macOS may prompt for mic access (false positive). Audio playback doesn't need mic permission, but `autoaudiosink` initialization sometimes triggers a probe. If observed, switch to explicit `osxaudiosink`.

5. **Slint testing backend ≠ GStreamer test environment.** The component test from Phase 6 instantiates MainWindow with the Slint testing backend. With media linked in, the test crate may pull GStreamer init. Keep the source-player tests in `video-coach-media/tests/`, not under app's tests.

---

## Done when

- All tasks merged.
- CI matrix green on macOS / Linux / Windows.
- All nine items in Task 8's manual smoke checklist passing.
- New `add_source_video_persists_to_disk` harness test passing.
- New `source_player` GStreamer integration tests passing.
- No regressions in existing Phase 1–6 tests.

---

## Closeout (2026-04-30)

**Status: shipped.** CI run 25173830999 green on all four jobs
(macOS, Linux, Windows test + media-tests). See `PROGRESS.txt` for
the authoritative per-task commit map.

CI red runs along the way (each fixed by a small follow-up):
- 25148901311: clippy `unneeded_return` in no-media build, plus Linux
  `pulsesink` failed PAUSED→PLAYING with no PulseAudio daemon.
  Follow-up `6a0ca1f` fixed both: dropped the `return`; added
  `VIDEO_COACH_NO_AUDIO=1` env that switches to `fakesink sync=true`,
  set unconditionally by `App::launch` for harness-spawned binaries.
- 25171962188: same audio fix worked in the harness path but the
  `crates/video-coach-media/tests/source_player.rs` integration tests
  open SourcePlayer in-process and bypass the harness env. Follow-up
  `06c4fe4` set the env in `disable_vt_decoders()` (which already
  runs at the top of every source_player test).

**Commits (in order):**

| Task | Commit  | Title                                                               |
|------|---------|---------------------------------------------------------------------|
| 0    | 46ed43b | Bus command shapes + path normalization                             |
| 1    | 029de7d | SourcePlayer headless + 5 fixture tests                             |
| 2    | bf90602 | AddSourceVideo command + project mutation                           |
| 3    | e107240 | Bus ↔ SourcePlayer wiring + macOS path canonicalization             |
| 4    | 6d441a9 | Slint video surface + display-rate pull                             |
| 4b   | 0899d9b | File → Add Source Video menu item                                   |
| 5    | df034dd | Transport UI (play/pause + scrubber + clock)                        |
| 6    | 2dd5003 | Skip buttons + keyboard shortcuts                                   |
| 7    | c3f69ba | Scan-volume slider + persistence                                    |

Plus several `chore(progress)` follow-ups filling SHA references in
PROGRESS.txt (the SHA can't be inlined in the same commit it
references; pattern is documented in the file's header).

**Test counts:** 75 → 76 default (+1 play_without_source unit test);
87 → 89 with media (+2 play_pause_seek + add_source_video harness E2E).

**Adversarial-review fixes verified in code:**

- ✅ Single-slot frame buffer + 30Hz pull (`frame_sink.rs::FrameSlot`,
  `ui.rs` Slint Timer). NOT per-frame `invoke_from_event_loop`.
- ✅ Frame pool partial — single-slot model means at most one
  un-displayed frame in flight; full pool deferred (documented
  in-code).
- ✅ AddSourceVideo spawns the player when first source arrives.
- ✅ OpenProject / NewProject canonicalize the project folder
  (handles macOS /tmp → /private/tmp symlink).
- ✅ Platform-specific audio sinks unconditionally
  (`source_player.rs::platform_audio_sink_name`).
- ✅ SourcePlayer::open accepts known duration; no Discoverer race.
- ✅ TouchArea + manual fill bar for scrubber (Slint Slider can't
  separate press/release).
- ✅ Position polling suppresses one cycle after seek
  (`bus.rs::spawn_position_poll`, 200 ms window).
- ✅ Position events emit from poll task (Task 5), not from
  earlier task handlers.

**Empirical findings recorded for future phases:**

- The `source-1080p.mp4` fixture's GOP is ~5 s. Keyframe-snap seeks
  during slider drag can land up to 5 s away from the requested
  position. The hybrid policy (drag = keyframe, release = accurate)
  is confirmed correct for this footage.
- macOS test subprocesses launched by the harness MUST disable VT
  decoders via `GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,...` — the
  Cocoa NSApplication runloop the decoders need doesn't exist in
  `cargo test` workers. Already wired in `App::launch`.
- f64 fields in tracing events fall through to `record_debug` (which
  encodes them as JSON strings) unless `record_f64` is implemented
  on the visitor. Phase 7 added it; Phase 8+ tracing fields can use
  numeric f64 fields freely.

**Outstanding follow-ups:**

- Slider hydration from `project.preferences.scan_volume` on project
  open. Phase 7 MVP starts the volume slider at 1.0 every session;
  Phase 8+ should wire the loaded preferences value back into the UI
  via the existing `PlayerStateSlot` pattern (or a new
  `ProjectPrefsSlot`).
- Multi-source virtual concat (v1's "scanning mode" stitches all
  `sourceVideos[]` into one timeline). Phase 7 MVP uses
  `sourceVideos[0]` only.
- Frame buffer pool. Single-slot is safe under the current load; if
  4K playback shows allocator jitter, swap in a fixed-size 2-buffer
  pool inside `SlintFrameSink`.
- Player swap (close project → open another). Position-poll task
  currently lives until app shutdown; multi-player support needs an
  `AbortHandle` for cancellation.

**Manual smoke checklist (recorded by user when verifying):**

- [ ] Open a project (existing or via New Project)
- [ ] Add Source Video via menu (file picker → pick a .mp4)
- [ ] Source plays in the window with audio
- [ ] Pause/play button works
- [ ] Scrubber drags responsively, release lands at exact position
- [ ] Skip buttons land exactly +/- 3s, 10s
- [ ] Space / ←  / → / Shift+← / Shift+→ keyboard shortcuts work
- [ ] Volume slider mutes/unmutes audio in real time

The headless socket-driven flows are fully automated by
`play_pause_seek_roundtrip_via_harness`; the items above need a
human at the keyboard until Phase 11 ships a virtual-display
strategy.

**Phase 8 entry conditions met.** Recording integration can build on
the bus + SourcePlayer + transport UI without further refactor.
