# Rust Rewrite — Phase 11 Plan #1: Source + Commentary Audio Mix

> **For Claude:** Implement via the per-phase sub-agent pattern (per
> `feedback_phase_per_subagent.md`). Phase 10's per-task split (Tasks
> 0/1/2/3 each in their own sub-agent, main session for closeout) hit
> zero watchdog timeouts. Match that here.
>
> **This is the FINAL plan of Phase 11** — wraps the biggest single
> deferred item from Phase 10 (fix #8: source/commentary audio mix
> in export AND preview).

**Goal:** Restore v1's two-volume audio behavior. Both batch export
AND clip preview honor `Preferences::preview_source_volume` and
`Preferences::preview_commentary_volume` (currently only the latter
is wired, into preview's commentary chain). After Plan #1: each
exported .mp4 contains the source video's audio + the recording's
commentary mixed together at user-set levels; preview plays the same
mix in real time. Default volumes 1.0/1.0 mean "full source + full
commentary" — closer to v1 than Phase 10's commentary-only output.

---

## Architecture overview (~150 words)

Two pipelines, two strategies:

- **Export** — driver-controlled, encoder-throttled, `sync=false`
  appsinks. The Phase 10 driver already pulls one audio stream
  (commentary) per tick into a shared audio-appsrc. Plan #1 extends
  the driver to ALSO pull a source-audio stream from a per-source-
  index audio appsink, scale both by their volumes, sum sample-wise
  into one output buffer, push to the same audio-appsrc. The
  monotonic `audio_pts_ns` cursor (Phase 10 fix #37) is unchanged —
  one stream out, sample-mixed in software. **Hand-rolled mix**, NOT
  GStreamer's `audiomixer` element, because the driver controls
  pacing and we want determinism.

- **Preview** — wall-clock-paced, `sync=true` audio sinks. Hand-
  rolling sample-pacing across two real-time audio sources is fragile
  (clock drift, sample-rate mismatch, race with `osxaudiosink`). Use
  GStreamer's `audiomixer` element directly: source-audio chain →
  volume(name=src_vol) → audiomixer; recording-audio chain →
  volume(name=cmty_vol) → audiomixer; audiomixer → audiosink.
  audiomixer handles real-time blending; volumes are live-tunable.

Both paths normalize formats via `audioconvert + audioresample`
before mix (Phase 10 already pins F32LE 48kHz 2ch on the export
audio-appsrc; preview adopts the same target).

**Why two strategies?** Export needs frame-by-frame determinism so
that the same Compilation Plan + same volumes + same fixture
produces the same audio bytes — required for the Phase 10 N-frame
parity discipline (audio side wasn't covered by parity_n_frames but
should be eventually). The hand-rolled mix is deterministic by
construction: the driver pulls exactly N bytes per tick and the sum
function is pure. Preview prioritizes A/V latency over byte-
determinism — `audiomixer` is GStreamer's standard real-time blend
element, designed exactly for this case. Trying to use the same
strategy for both was rejected: hand-rolling sync=true real-time
mixing requires a clock domain we don't currently own, and using
audiomixer in export means losing the per-tick PTS control we DO
own (Phase 10 fix #37's whole reason for existing).

**Volume range and clipping.** Both `preview_source_volume` and
`preview_commentary_volume` clamp to `[0.0, 1.0]`. With both at the
1.0 default and two correlated signals (e.g. recorded commentary
that includes the source's audible audio bleed-through from the
laptop speakers), the sample-domain sum can exceed `[-1.0, 1.0]`.
The export path applies a `tanh`-style soft-clip; the preview path
relies on the audio sink's natural hard clip + audiomixer's
`normalize` property (off by default — Plan #1 leaves it off,
matching v1's "trust the user, full gain by default" behavior).

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; **Adversarial-review fixes baked in**
   below is non-negotiable.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`,
   especially:
   - **Fix #8** — explicit deferral of source/commentary audio mix
     to Phase 11 (this plan).
   - **Fix #37** — driver-fed audio appsrc with monotonic
     `audio_pts_ns` cursor. Plan #1 EXTENDS this; doesn't replace.
3. `crates/video-coach-media/src/export.rs`:
   - Lines ~600-650 — current source-audio handling: routed to
     fakesink to keep decodebin from stalling. Plan #1 replaces
     this with a real audio appsink chain.
   - `build_webcam_chain` (lines ~670-880) — pattern for routing
     decodebin's audio pad through audioconvert + audioresample +
     capsfilter to an `audio-appsink`. Plan #1's source-audio path
     mirrors this shape.
   - `AudioSampleQueue` (lines ~1114-1170) — the FIFO that the
     driver pulls from per tick. Plan #1 introduces a SECOND queue
     keyed by source_index.
   - `push_audio_for_window` (lines ~1626-1680) — current
     commentary-only push. Plan #1 rewrites this to mix two
     queues' bytes sample-wise.
4. `crates/video-coach-media/src/preview_pipeline.rs`:
   - `build_and_link_webcam_audio_chain` (lines ~737-777) — current
     commentary-only audio chain feeding `osxaudiosink/wasapisink/
     pulsesink/fakesink`. Plan #1 inserts an `audiomixer` element
     and adds a parallel source-audio chain.
   - `build_video_input_chain` source-side audio routing (lines
     ~488-580) — currently fakesinks the source's audio. Plan #1
     replaces with a real chain into the audiomixer.
5. `crates/video-coach-core/src/project.rs::Preferences`:
   - `preview_source_volume: f64` (default 1.0), `preview_commentary_
     volume: f64` (default 1.0) — already exist. Plan #1 wires
     `preview_source_volume` into preview AND export (currently
     unused).
6. `crates/video-coach-app/src/bus.rs::handle_export_compilations`
   (around line 2755) — already reads
   `project_snapshot.preferences.preview_source_volume` and passes to
   `export_compilation`. Plan #1's export.rs work makes that
   parameter actually do something.

---

## Adversarial-review fixes baked in

> _**To main session writing this plan**: run an adversarial-review
> pass before committing. Paste fixes below, then commit. If you
> skip and the section stays empty, the sub-agent should stop and
> ask the user._

(awaiting adversarial-review pass)

---

## Tasks (Task 0 preflight + 3 implementation tasks + closeout)

### Task 0: Preflight — Preferences hookup + bus snapshot

**Files:**
- Inspect: `crates/video-coach-core/src/project.rs` — confirm
  `Preferences::preview_source_volume` + `preview_commentary_volume`
  are already there with default 1.0 each. No new fields needed.
  (The scope.md draft considered `last_export_*` fields; reusing the
  existing `preview_*` is simpler — Phase 10 already plumbs them
  through, and the user's mental model is "one slider per source,
  applies everywhere".)
- Modify: `crates/video-coach-core/src/project.rs` if a doc-comment
  rename is warranted ("preview" prefix is misleading once both
  preview AND export consume the field). **Decision**: keep the field
  names. Renaming churns 5+ files for cosmetic gain; document in the
  field's doc-comment that it covers BOTH preview and export.
- Modify: `crates/video-coach-app/src/bus.rs` — `handle_export_
  compilations` already reads the volumes. Verify the snapshot path
  is unchanged. No code change expected; this task's purpose is to
  audit + document.
- Modify: `crates/video-coach-app/src/ui.rs` — add two callback
  handlers (`on_export_source_volume_changed`,
  `on_export_commentary_volume_changed`) that update the live
  `Preferences` and write through `project_store::save_project_meta`.
  Mirror Phase 7's `scan-volume-changed` handler pattern.
- Modify: `crates/video-coach-app/src/main.rs` — wire the two new
  callbacks to bus dispatchers if needed (or handle inline in ui.rs
  via the project store; pick the cheaper path).

**Scope:**
- ~80 LOC: doc-comment update + two ui.rs callback handlers + a
  serde test confirming `preview_source_volume` round-trips through
  `Preferences`.
- No new bus Command — volumes flow through Preferences persistence,
  not transient per-export Command fields. (The Command shape stays
  unchanged from Phase 10; `export_compilation` already takes
  `source_volume: f64, commentary_volume: f64` as args.)

**Implementation notes:**
- Confirm `preview_source_volume` / `preview_commentary_volume`
  defaults are 1.0/1.0 (verified — see project.rs line 119-120).
  Don't change defaults; this is a behavior change documented in
  the closeout (Phase 10 = commentary-only ≈ source 0.0; Phase 11
  Plan #1 = both 1.0).
- Volume range stays `0.0..=1.0`. Values > 1.0 work numerically
  (gain) but risk clipping after sum (1.0 + 1.0 = 2.0 sample-domain).
  Plan #1 explicitly forbids > 1.0 in the UI; the audio mixer's
  sample-domain sum can still exceed clip range when both are
  exactly 1.0 with simultaneously loud signals — see Task 1 fix #X
  for the soft-clip strategy.
- Update PROGRESS.txt with a Phase 11 Plan #1 section + Task 0 row
  marked shipped + commit SHA.

**Tests:**
- `preview_source_volume_default_is_1_0` — already exists if the
  Preferences default test exists; otherwise add.
- `preview_volumes_round_trip_through_preferences_serde` — confirm
  serde retains both fields exactly.
- `preview_source_volume_clamps_to_unit_range_on_save` — write 1.5,
  read back 1.0; write -0.2, read back 0.0. Defends against
  malformed control-socket payloads from harness fixtures.

---

### Task 1: Export pipeline — source-audio chain + hand-rolled mixer

**Files:**
- Modify: `crates/video-coach-media/src/export.rs` (the big one).
- Modify: `crates/video-coach-media/tests/export_smoke.rs` —
  add an assertion that the output .mp4's audio track is non-silent
  (analytical, not perceptual; verify via Discoverer that an audio
  track exists with non-zero duration).

**Scope:**
- ~250 LOC. Largest task in the plan.
- Replace `build_source_video_chain`'s fakesink-on-audio-pad branch
  with a real audio chain mirroring `build_webcam_chain`'s audio
  branch.
- Replace `push_audio_for_window` with a hand-rolled two-stream mix.
- Update `export_compilation`'s arg list: change the underscore-
  prefixed `_source_volume` / `_commentary_volume` to active
  parameters; thread through to the mix function.

**Implementation notes:**

1. **Source audio chain** (mirror webcam's audio path). Each unique
   `source_index` in the plan gets:
   ```
   filesrc → decodebin → [pad-added: audio/* branch]
       → queue → audioconvert → audioresample → capsfilter(F32LE 2ch 48k)
       → audio-appsink (sync=false, name="src_audio_<idx>")
   ```
   Build alongside the existing video chain. The decodebin pad-added
   handler routes `video/*` to the existing video queue and `audio/*`
   to a new audio chain that's added dynamically (decodebin doesn't
   surface caps until prerolled).
2. **Source-with-no-audio fallback.** Some source files have no audio
   track (e.g. silent reference videos). The `pad-added` handler may
   never fire for an audio pad. After pipeline preroll completes
   (state(timeout=10s) returns), check whether each source's audio
   appsink actually received any caps. If not: the driver treats
   that source's audio queue as empty and the mix falls back to
   commentary-only for those entries. Add a tracing event
   `event = "export.source_audio_missing", source_index = <idx>` so
   the user can see why their export sounds "wrong".
3. **Per-source-index audio queue map** alongside the existing per-
   clip-id map:
   ```rust
   let mut source_audio_queues: HashMap<usize, Arc<Mutex<AudioSampleQueue>>>
       = HashMap::new();
   for (idx, chain) in &source_chains {
       if let Some(audio_appsink) = &chain.audio_appsink {
           let q = Arc::new(Mutex::new(AudioSampleQueue::default()));
           attach_audio_sample_queue(audio_appsink, q.clone());
           source_audio_queues.insert(*idx, q);
       }
   }
   ```
   `SourceVideoChain` gains `audio_appsink: Option<AppSink>`.
4. **Hand-rolled mix in `push_audio_for_window`**. Per tick, pull
   `target_bytes` from the active commentary queue and the active
   source queue. Both produce `[f32; 2]` samples (F32LE stereo, 48k).
   Sample-domain mix:
   ```rust
   for (sample_idx, (s_pair, c_pair)) in
       source_chunk.chunks_exact(8).zip(commentary_chunk.chunks_exact(8))
   {
       let s_l = read_f32(s_pair, 0) * source_volume;
       let s_r = read_f32(s_pair, 4) * source_volume;
       let c_l = read_f32(c_pair, 0) * commentary_volume;
       let c_r = read_f32(c_pair, 4) * commentary_volume;
       write_f32(out_pair, 0, soft_clip(s_l + c_l));
       write_f32(out_pair, 4, soft_clip(s_r + c_r));
   }
   ```
   Use a tanh-style soft-clip (`x.tanh()` or `x / (1.0 + x.abs())`)
   to avoid digital clipping when both volumes are 1.0 and signals
   align in phase. Document the choice in a code comment: "v1 used
   AVMutableComposition's preferredVolume which is also a linear
   gain + system clip; we approximate with soft-clip for slightly
   gentler artifacts at the high end."
5. **Length mismatch handling.** Source audio chunk and commentary
   audio chunk may not have the same number of bytes available
   (decoder fragmentation, EOS-near-end-of-clip). Strategy:
   - If both have ≥ `target_bytes`: mix exactly `target_bytes`.
   - If commentary has < target: pad commentary chunk with zeros to
     `target_bytes`, mix.
   - If source has < target: pad source chunk with zeros, mix.
   - If both empty: push silence at full target_bytes (Phase 10
     existing fallback path).
6. **Volume = 0.0 short-circuit.** If `source_volume == 0.0` skip
   pulling source samples entirely (commentary path only). If
   `commentary_volume == 0.0` skip commentary. If both 0.0, push
   silence. Save decoder work on the silent-source-channel case
   (common: the user wants commentary-only behavior identical to
   Phase 10).
7. **Cancel polling unchanged.** The existing per-frame cancel
   check covers audio-sample pulling implicitly (audio mix runs
   inside the same per-frame loop). Document this in a code comment.
8. **Entry transition unchanged for source audio queues.** When the
   driver activates a new entry whose `source_index` differs from
   the previous entry's, the new source's `set_state(Playing)` plus
   seek-to-segment-start will start that source's audio decoder.
   The previous source's queue is drained on activation (mirror the
   existing commentary-queue drain at line ~1413). Stale samples
   from the previous source must NOT bleed into the new entry's
   audio.
9. **Format pinning.** Source decoder output may be S16LE 44.1k mono;
   audioconvert + audioresample + capsfilter to F32LE 48k 2ch BEFORE
   the appsink, so the driver's mix function sees a consistent
   format. The capsfilter caps string is identical to the audio-
   appsrc caps string (line ~1031): single source of truth.
10. **`export_compilation` signature.** Change `_source_volume` →
    `source_volume` and `_commentary_volume` → `commentary_volume`.
    Both are `f64` clamped to `[0.0, 1.0]` at the top of the function
    (defensive; UI also clamps).
11. **Both volumes 0.0 → silent track, NOT skipped audio track.** The
    output .mp4 must always have an audio track — qtmux's audio
    sink-pad was requested at pipeline-construction time, removing it
    mid-flight is fragile. When both volumes are 0.0, push silent
    F32 buffers (sample-aligned) on every tick; encoder produces a
    valid silent AAC stream. Document the choice: a fully silent
    export is rare and the consistency win (always one audio track)
    outweighs the few KB of silent AAC.
12. **AudioSampleQueue drain on entry boundary — both queues.** The
    Phase 10 driver drains the active commentary queue at line ~1413
    on entry transition. Plan #1 also drains the active source
    queue when `source_index` differs between consecutive entries.
    If the same source_index continues across entries (typical
    single-source compilation), DO NOT drain — the source decoder
    just continues feeding samples after a seek, and the seek
    itself flushes pending samples upstream. Verify experimentally;
    if cross-segment seeks within one source produce stale samples,
    add a drain there too.

**Tests:**
- `export_smoke.rs::audio_mix_produces_audio_track` — record a clip
  against a fixture source with audio (need to add: a 1.5s WAV
  embedded in the fixture source via `gst-launch` test pattern, OR
  use an existing audio-bearing fixture if one exists in
  `tests/fixtures/`). Run export. Use Discoverer to verify the
  output has an audio track with duration ≈ 1.5s and AAC codec.
- `export_smoke.rs::silent_source_falls_back_to_commentary_only` —
  use a video fixture WITHOUT audio (the existing fixture). Run
  export. Discoverer reports an audio track (the commentary). The
  test does NOT assert "exactly equal to commentary" because the
  soft-clip and audioconvert may introduce tiny differences; it
  asserts "audio track present, duration matches".
- `export_smoke.rs::source_volume_zero_excludes_source_audio` —
  use audio-bearing source. Run with `source_volume=0.0,
  commentary_volume=1.0`. Output should match a commentary-only
  reference within ±epsilon. Loose check: the export with
  `source=0` has noticeably less RMS loudness than the export with
  `source=1, commentary=1` over the same clip.
- Unit test for the mix function itself: `audio_mix_sums_two_streams_
  with_volume_scaling` — feed two known F32 byte chunks, assert the
  output bytes equal `s*sv + c*cv` per sample (with `soft_clip`
  applied; if soft-clip is `x.tanh()` the test uses values < 0.5 so
  tanh ≈ identity).

---

### Task 2: Preview pipeline — audiomixer element + source audio chain

**Files:**
- Modify: `crates/video-coach-media/src/preview_pipeline.rs`.
- Modify: `crates/video-coach-media/tests/preview_pipeline_smoke.rs`
  (or wherever the preview audio test lives) — extend to assert
  audiomixer wiring.

**Scope:**
- ~150 LOC.
- Insert `audiomixer` between the existing audio chains and the
  audiosink.
- Add a parallel source-audio chain feeding the audiomixer.
- Hook both chains' `volume` elements to live property updates from
  Preferences (via the existing `commentary_volume` element name +
  a new `source_volume` element name).

**Implementation notes:**

1. **Shared audio output** — instead of each per-recording chain
   building its own audio path to the audiosink (currently
   `build_and_link_webcam_audio_chain` inlines the audiosink), the
   preview pipeline builds ONE audiosink + ONE audiomixer at
   pipeline construction. Source-audio and commentary-audio chains
   each link to a NEW audiomixer sink-pad via `audiomixer.request_
   pad_simple("sink_%u")`.
2. **Preview-side source audio.** Currently
   `build_video_input_chain`'s pad-added handler routes audio to
   fakesink. Replace with:
   ```
   queue → audioconvert → audioresample → volume(name="source_volume")
       → capsfilter(F32LE 2ch 48k)
       → audiomixer's sink-pad
   ```
   No appsink — preview is wall-clock-paced and the audiomixer
   handles real-time blending.
3. **Preview-side commentary audio.** Modify `build_and_link_
   webcam_audio_chain`: replace the direct audiosink with a link to
   the audiomixer's next sink-pad. Keep the `volume(name=
   "commentary_volume")` element; rename or duplicate the helper
   if mixing into a shared audiomixer requires a different shape.
4. **audiomixer caps + latency.** audiomixer has a `latency`
   property (default 60ms); leave at default for Plan #1. The mixer
   imposes a bounded delay for blending — acceptable for preview
   playback. The output of audiomixer is `audio/x-raw,F32LE,2ch,
   48000` (or whatever the sink-pads negotiate); add a capsfilter
   AFTER audiomixer pinning to F32LE 2ch 48k for deterministic
   downstream encoder/sink negotiation.
5. **Volume property updates from UI.** The existing UI scan-volume
   slider pattern updates the source-player's `volume` element via
   `set_property`. Plan #1 mirrors this for two new volume elements
   in the preview pipeline:
   ```rust
   fn set_preview_source_volume(&self, v: f64);
   fn set_preview_commentary_volume(&self, v: f64);
   ```
   Both look up the named element via `pipeline.by_name("source_
   volume")` / `by_name("commentary_volume")` and call
   `element.set_property("volume", v)`. Live update — no pipeline
   restart.
6. **Preview source has no audio fallback.** If the source video has
   no audio track, the source-audio chain is never built (pad-added
   doesn't fire for audio). audiomixer handles missing pads
   gracefully — it just blends the available pad. No special-case
   needed in driver code.
7. **Headless / `VIDEO_COACH_NO_AUDIO=1` mode.** Existing behavior:
   the audiosink is replaced with `fakesink (sync=true)` for CI
   determinism. Plan #1 keeps this; the audiomixer still mixes (its
   output goes to fakesink), so the wiring path is exercised in CI
   even though no audio is rendered.
8. **Preview pipeline construction order.** Build audiosink + audiomixer
   FIRST, then per-recording chains link to mixer pads on creation.
   Document this with a code comment explaining the dependency.
9. **Cleanup on pipeline shutdown.** Existing preview shutdown calls
   `pipeline.set_state(Null)` which tears down all elements. The
   audiomixer's request-pads are released automatically as part of
   element destruction. No new cleanup logic — but verify in the
   Phase 9 stepped-teardown sequence (PAUSED → READY → NULL) that
   audiomixer doesn't deadlock on the PAUSED step. If it does (audio
   element pause-races are well-known), document with a comment and
   skip directly to NULL on the audiomixer-bearing path.
10. **Volume element placement matters.** Place the `volume` element
    AFTER `audioconvert + audioresample` and BEFORE the audiomixer
    sink-pad. Placing volume before audioconvert means scaling raw
    decoder output (could be S16, range mismatch when scaling); after
    audioconvert the data is F32 and scaling is mathematically clean.
    audiomixer also expects all sink-pads to negotiate the same caps
    so volumes operating on F32 inputs guarantees consistent caps to
    the mixer.

**Tests:**
- `preview_pipeline_smoke.rs::audiomixer_builds_with_two_input_pads` —
  construct preview with a source + recording, query the pipeline
  for the `audiomixer` element by name, assert it has 2 sink-pads.
- `preview_pipeline_smoke.rs::source_volume_property_is_live_tunable` —
  build pipeline, set preview state to PLAYING, call `set_preview_
  source_volume(0.5)`, query `volume` element's `volume` property,
  assert it's 0.5.
- Existing preview smoke tests must keep passing (commentary path
  unchanged from user-visible side).

---

### Task 3: UI — two volume sliders in the export sheet

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`.
- Modify: `crates/video-coach-app/src/ui.rs`.

**Scope:**
- ~100 LOC.
- Two horizontal sliders ("Source volume" + "Commentary volume") in
  the export sheet's Form view, between the resolution/quality
  pickers and the Export button. Mirror Phase 7's `scan-volume`
  slider widget shape (Rectangle with width-driven indicator + a
  TouchArea that maps mouse-x to a 0..1 float).
- Each slider bound to a Slint property
  (`export-source-volume: float`, `export-commentary-volume: float`)
  and emits a callback on drag.
- Bus persistence on Export click (already in the pipe via
  `Preferences::preview_*_volume`; UI just needs to write through
  before dispatching `ExportCompilations`).

**Implementation notes:**

1. **Slider widget** — copy the Phase 7 scan-volume pattern (lines
   ~770-800 in main.slint). Rectangle with `width: parent.width *
   root.export-source-volume`, TouchArea on the parent that on-
   pressed and on-moved sets `root.export-source-volume = max(0,
   min(1, self.mouse-x / self.width))`. Repeat for commentary.
   Label each slider with text + a numeric readout (e.g. "0.85").
2. **Initial values.** When the export sheet opens (File → Export
   Compilations menu activation), the sheet's `init` callback (or
   the menu-handler in `ui.rs`) hydrates `export-source-volume` and
   `export-commentary-volume` from
   `current_project.preferences.preview_source_volume /
   preview_commentary_volume`. Defaults to 1.0/1.0 for new projects.
3. **Persistence on Export click.** When the user clicks Export, the
   `export-start-clicked` handler in ui.rs reads the slider values
   off the Slint properties, writes them into the live Preferences,
   persists via `project_store::save_project_meta`, THEN dispatches
   the existing `Command::ExportCompilations`. (The bus's
   `handle_export_compilations` then snapshots the Preferences and
   passes the volumes to `export_compilation`.)
4. **Live preview-side updates.** When the user drags either slider,
   the callback (`export-source-volume-changed(float)`) updates the
   live preview pipeline (if a clip preview is active) via the new
   `set_preview_source_volume` / `set_preview_commentary_volume`
   from Task 2. This way the user can A/B the mix in real time
   before clicking Export. **Caveat**: clip preview is gated behind
   `AppMode::PreviewClip` — the export sheet generally opens from
   `AppMode::Scanning`, so live tuning won't typically happen during
   export-sheet interaction. The wiring still belongs there for
   correctness.
5. **Slider focus discipline.** The export sheet's existing focus
   scope (Phase 10 fix #32) handles Esc / click-outside; the new
   sliders don't introduce new focus complications because they're
   TouchArea-driven, not text-input.
6. **Disable during InProgress outcome.** When the export is running
   (`export-active == true`), grey out and disable both sliders to
   prevent mid-export changes (the export pipeline has already
   captured the snapshot). Slint property `enabled: !root.export-
   active` on the TouchArea.
7. **Slider layout.** Stack the two sliders vertically below the
   resolution/quality picker row, each with its own label + numeric
   readout. Width matches the picker row width. ~24px slider track,
   ~16px gap between sliders. Mirror Phase 7's scan-volume styling
   (background colour, indicator colour, border) for visual
   consistency.
8. **Project-store persistence batching.** When the user clicks
   Export, two volume writes plus the existing
   `last_export_resolution` / `last_export_quality` /
   `last_export_codec` writes go through `save_project_meta`. The
   existing helper writes the entire `Preferences` struct in one
   atomic save; just mutate all four fields then save once. Don't
   call `save_project_meta` per slider change — that would write to
   disk on every drag tick.

**Tests:**
- Manual UI smoke (no integration test — Phase 11 plans don't add
  Slint-rendering tests).
- ui.rs unit test if the persistence path warrants one:
  `export_volumes_persist_to_preferences_on_export_click` — mock the
  project store, send an `export-start-clicked` callback, assert
  `preview_source_volume` is updated.

---

### Task 4: Closeout (handled by main session / orchestrator)

- Run the full verification battery (build × 3 feature flavors,
  test × default + media, clippy × 2, fmt). Per Phase 9/10 lesson:
  ALWAYS `cargo build --workspace --features media` BEFORE
  `cargo test --workspace --features media` — incremental feature
  unification can leave a stale binary.
- `git push` + verify CI green via `gh run list --branch rust-rewrite
  --limit 1` AND `gh run view <id> --json conclusion,status,jobs`.
- Append a closeout section at the bottom of THIS plan file:
  commits table, adversarial-fix verification, deferred items.
- Mark Phase 11 Plan #1 SHIPPED in PROGRESS.txt with the final CI
  run id.
- **Phase 11 closeout** — Plan #1 is the LAST of Phase 11's seven
  plans. Add an overall "Phase 11 SHIPPED" line in PROGRESS.txt
  summarizing all seven plans + their cumulative CI run.

---

## What Plan #1 deliberately does NOT include

- **Per-clip volume overrides.** v1 had project-level volume only;
  Plan #1 matches. A future patch could add `Clip::source_volume_
  override: Option<f64>` for the rare case of a single noisy clip.
- **Audio ducking** (auto-lower source when commentary is loud).
  Out of scope; v1 didn't have it.
- **Audio waveform display in the preview transport.** Useful but
  separate UX work.
- **Audio-only preview mode.** No checkbox to mute video and play
  just the mix; not a v1 feature.
- **Multi-channel surround.** All audio normalized to F32LE stereo.
  v1 was stereo only.
- **Custom mix profiles per export preset.** A "default loud" vs
  "default soft" set of volumes. Out of scope.
- **Real-time level meters.** No VU display anywhere; would require
  audio tap + render. Phase 11+1 maybe.

---

## Known performance risks (acceptable for Plan #1)

- **Per-tick mix CPU cost.** Source decode + commentary decode +
  per-sample multiply + sum + soft-clip × 48000 samples/sec × 30
  frames/sec = ~1.4M scalar ops/sec. Negligible vs encode + GPU
  composite. Single-threaded in the driver loop; no need for SIMD.
- **audiomixer latency in preview.** Default 60ms. User-noticeable
  if they're trying to A/V-sync a stroke event mid-clip. Acceptable
  for Plan #1; tune lower in a follow-up if user reports it.
- **Source audio decoder for projects with many sources.** Each
  unique source_index now spawns an audio appsink + queue + audio
  decoder. Memory ~5-15 MB per source. For typical projects (1-3
  sources) trivial; multi-source compilations (rare) get the bigger
  cost.
- **Two-queue lock contention.** Each tick the driver locks both
  queues sequentially to pull bytes. Decoder threads also lock to
  push. Lock-acquire cost ~50ns; total per-tick overhead ~300ns × 4
  locks = 1.2 μs. Lost in the noise vs the ~10ms encoder push. If a
  future profile shows it dominating, switch to a lock-free SPSC
  ring buffer (`crossbeam` or hand-rolled with `AtomicUsize` head/
  tail). Out of scope for Plan #1.

---

## Risks / unknowns (sub-agent may need to make calls)

1. **Sample alignment between source-audio and commentary-audio
   queues.** Source audio starts at the source's seek-target time
   (deterministic per Phase 9 fix #23). Commentary audio starts at
   the recording's t=0. Both feed the same audio-appsrc with the
   same monotonic `audio_pts_ns` so OUTPUT alignment is fine, but
   the per-tick mix assumes both queues have samples ready. If the
   source decoder lags (cold-start on Apple Silicon: ~200-400ms),
   the first ~10 frames may have source-zeros + commentary mixed.
   Acceptable; encoder catches up after preroll. Document.
2. **audiomixer's "sink_0" / "sink_1" pad ordering.** GStreamer's
   audiomixer doesn't guarantee request-pad order matches volume.
   Solution: Plan #1 names each volume element (`source_volume` /
   `commentary_volume`) and looks them up by name when setting
   property values — the audiomixer pad order is irrelevant.
3. **Preview audiomixer + osxaudiosink interaction.** Combined
   with macOS's CoreAudio HAL clock, audiomixer can produce audible
   discontinuities during state transitions (PAUSED → PLAYING). v1
   used AVAudioEngine which has its own quirks. If testing surfaces
   pops at preview-start, the fallback is to hold the audiomixer
   in PLAYING from pipeline construction (instead of state-following
   the pipeline) — same trick the existing source-player.rs uses.
4. **Soft-clip choice.** `x.tanh()` (smooth, slightly compressive)
   vs `x.clamp(-1.0, 1.0)` (hard, classic clipping) vs `x / (1.0 +
   x.abs())` (soft, asymptotic). Plan #1 picks `x.tanh()`; if the
   resulting export sounds noticeably different from v1's hard-clip
   (which is what AVMutableComposition + AAC encoding effectively
   produces), switch to `clamp`. Defer to ear-test by the user
   during closeout review.
5. **Source audio with mismatched channel count** (mono source +
   stereo commentary). audioconvert handles upmixing transparently;
   audioresample handles rate. The capsfilter pinned to
   `channels=2,rate=48000` forces both upstream conversions. Should
   "just work" but the matrix-mixing audioconvert applies for mono
   → stereo upmix may produce subtly different L/R balance than v1.
   Acceptable; users with mono sources are uncommon.
6. **Preview live-volume update during a clip preview.** If
   `set_preview_source_volume` is called while the pipeline is
   PLAYING, the volume element changes its property atomically —
   no pipeline restart, no glitch. Verified pattern in
   `source_player.rs`. Plan #1 reuses the same approach.
7. **Phase 10's `_source_volume` placeholder fields.** Phase 10
   shipped `export_compilation` with underscore-prefixed args to
   signal "deferred to Phase 11". Plan #1 removes the underscores
   and wires them through. Any harness/test code calling
   `export_compilation` directly (e.g. `tests/export_smoke.rs`)
   already passes positional args — no API break. Audit with
   `grep -rn "export_compilation(" crates/` before commit.
8. **Recording's audio rate vs export's audio rate.** Phase 8 records
   audio at the platform default (commonly 44.1k or 48k depending on
   device). Phase 10's audio appsrc pins 48k, so recordings at 44.1k
   get resampled by the in-pipeline `audioresample` element. Source
   files vary even more (24k YouTube downloads through 96k pro
   captures). audioconvert + audioresample handles all cases via the
   capsfilter, but Plan #1's source-audio chain MUST preserve this
   exact pattern: `audioconvert → audioresample → capsfilter(48k 2ch
   F32LE)` before the appsink. Otherwise a 96k source feeds 96k
   bytes-per-second to the mix which then mismatches commentary's
   48k buffer length and the mix function reads garbage.
9. **AudioSampleQueue's allocation pressure.** Each tick the driver
   allocates a `Vec<u8>` of `target_bytes` size (~6400 bytes for one
   frame at 48k/2ch/F32). Two queues now produce two such allocations
   per tick PLUS one for the mixed output. ~600 KB/s of churn at 30
   fps. Negligible vs encoder pressure but non-zero. Future
   optimization: pre-allocate three reusable buffers in the driver
   loop. Out of scope for Plan #1.

---

## Done when

- All 4 task commits land on `rust-rewrite`.
- CI matrix green on macOS / Linux / Windows + media-tests.
- New `export_smoke::audio_mix_produces_audio_track` test passes.
- New `preview_pipeline_smoke::audiomixer_builds_with_two_input_pads`
  test passes.
- Existing Phase 1-10 tests still pass.
- Manual smoke: open a project, scan a source, record a clip, open
  Export sheet, drag both sliders to mid-range, export. Output .mp4
  contains a mix of source audio + commentary audio at user-set
  levels.
- PROGRESS.txt reflects each task + the plan SHIPPED line + CI run id.
- The plan file gains a closeout section at the bottom.
- Phase 11 overall SHIPPED line added to PROGRESS.txt (Plan #1 is
  the last of seven).

---

## Cross-task touchpoints (heads-up for sub-agents)

- **Task 1 ↔ Task 2 share the F32LE 48k 2ch caps string.** Both
  pipelines should reference a single `const AUDIO_CAPS_STR: &str`
  (already in export.rs as `audio/x-raw,format=F32LE,channels={...},
  rate={...},layout=interleaved`). If preview defines a parallel
  constant, document the duplication or extract to a shared module
  (`crates/video-coach-media/src/audio_caps.rs`?) — pick whichever
  bug-prevents-drift more cheaply.
- **Task 1's mix function is testable WITHOUT GStreamer.** Extract
  `fn mix_audio_buffers(source: &[u8], commentary: &[u8],
  source_volume: f32, commentary_volume: f32, target_bytes: usize,
  out: &mut Vec<u8>)` as a free function (or a method on a small
  `AudioMixer` struct). Unit-test it with hand-rolled byte arrays.
  This is the single highest-leverage test in the plan: a regression
  here corrupts every export.
- **Task 3's slider hydration depends on Task 0.** The export sheet
  reads `current_project.preferences.preview_*_volume` on open. If
  the project store load order changes in Task 0 (it shouldn't, but
  audit), Task 3's hydration logic reads the wrong values. Verify
  by opening a project with non-default preferences and confirming
  the slider lands at the persisted value.
- **All three tasks write to PROGRESS.txt.** Existing convention:
  each task ends with a `[x] Task N — <description> (commit <SHA>)`
  line under the Phase 11 Plan #1 section. Sub-agent flips `[ ]` to
  `[x]` and fills in SHA after the commit lands.
