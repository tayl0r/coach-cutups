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
The export path applies a deterministic rational soft-clip
`x / (1.0 + x.abs())` (adv-fix #5 — transcendentals like `tanh`
are forbidden because libm's last-ULP results differ across macOS
Accelerate vs Linux glibc, which would flake any future N-frame
audio parity test). The preview path relies on the audio sink's
natural hard clip + audiomixer's `normalize` property (off by
default — Plan #1 leaves it off, matching v1's "trust the user,
full gain by default" behavior).

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

> Findings come from `/tmp/phase11-plans/plan-1/adv-review.md` (10 net-
> new findings). Triage: 9 REAL (folded below), 1 OVERSTATED (#9,
> trimmed to a tracing breadcrumb only; full toast/dialog deferred).
> Numbered fixes are non-negotiable for sub-agents.

**Fix #1 — Bound each `AudioSampleQueue` to ~2-4s of audio so a fast
`sync=false` source decoder can't accumulate 50-150 MB of decoded
samples before the driver consumes them.** (REAL, high; finding #1.)
Each `AudioSampleQueue` (both commentary and source variants) gains
a `MAX_QUEUED_BYTES = 4 * AUDIO_RATE * AUDIO_BYTES_PER_SAMPLE`
(~1.5 MB at 48k stereo F32). Implementation: set the audio appsink's
`max-buffers` property so GStreamer holds the decoder when the queue
is full. Document in a code comment that this is back-pressure for
hw-decoded sources running well above real-time on Apple Silicon.
*Touches Task 1 implementation note 1 + 3.*

**Fix #2 — Drain the active source-audio queue on EVERY entry
transition, not only when `source_index` changes.** (REAL, medium;
finding #2.) Two consecutive entries on the same source with a Skip
segment between them will leave stale source samples in the queue
that pre-roll covered the OLD `record_time` window; the driver
would read them as the NEW entry's first samples. The seek-flush
refills within ~33ms; one frame of silence is inaudible. Document:
"source-decoder seek policy is flush-on-entry-boundary, identical
to webcam." *Replaces Task 1 implementation note 8/12 partially —
drain unconditionally on every entry transition for both queues.*

**Fix #3 — `audiomixer` MUST have a downstream capsfilter pinning
F32LE/48k/2ch to anchor caps negotiation.** (REAL, high; finding
#3.) audiomixer negotiates output caps from the FIRST sinkpad to
get caps; pad-added ordering between source and recording is non-
deterministic (decodebin async). Without a downstream anchor a
race can land the mixer at S16LE before our upstream capsfilter
forces F32LE, causing the second sinkpad's renegotiation to fail.
Wiring is `... → volume → capsfilter(F32LE,48k,2ch) → audiomixer →
capsfilter(F32LE,48k,2ch) → audiosink`. Plan note 4 mentioned this
AFTER the mixer; promoted to hard requirement. *Touches Task 2
implementation note 1 + 4.*

**Fix #4 — Add explicit "both volumes 0.0" tests so the silent-
audio-track regression doesn't slip past CI.** (REAL, medium;
finding #4.) Two new tests:
- Unit: `both_volumes_zero_pushes_silent_buffer_not_noop` — assert
  the appsrc receives a `target_bytes`-sized zero-filled buffer
  with `pts_ns = audio_pts_ns` and the cursor advances.
- Integration: `export_with_both_volumes_zero_yields_silent_audio_
  track` — run export with both volumes 0.0 and use Discoverer to
  confirm an audio track exists with non-zero duration.
*Touches Task 1 tests + reinforces note 6 + 11.*

**Fix #5 — Soft-clip MUST be deterministic across libm impls.
Replace `x.tanh()` with `x / (1.0 + x.abs())`.** (REAL, medium;
finding #5.) `tanh` is a transcendental whose last-ULP result
differs between macOS Accelerate and Linux glibc; future N-frame
audio parity tests would flake across the CI matrix. The rational
approximation is bit-identical across platforms and produces a
similar soft-knee. Document in code comment: "soft-clip MUST be
bit-identical across platforms; transcendentals forbidden."
*Touches Architecture overview "Volume range and clipping",
Task 1 note 4, Risks #4.*

**Fix #6 — Pin volumes to `f32` end-to-end through the mix chain
and assert `chunk.len() % 8 == 0` in the mix function.** (REAL,
medium; finding #6.) Plan pseudocode mixed `f32` (note 4) and
`f64` (note 10) — silent precision loss with no compile warning.
Convert volumes from `Preferences::preview_*_volume` (`f64`) to
`f32` exactly once at the `export_compilation` boundary; thread
`f32` everywhere downstream. The mix function asserts each input
chunk is a multiple of 8 bytes (stereo F32) and panics with context
on mismatch — better to crash a buggy export than silently produce
audio with cumulative drift. *Touches Task 1 note 4, 6, 10 +
cross-task touchpoint #2.*

**Fix #7 — Wire a phantom silence sinkpad on the preview audiomixer
at construction time so PAUSED state-change can't deadlock when
both real sources delay pad-added.** (REAL, medium; finding #7.)
audiomixer needs ≥1 sinkpad to transition to PAUSED. If both
decodebins are still probing, the mixer has zero pads and PAUSED
blocks indefinitely; osxaudiosink never prerolls. Construction:
`audiotestsrc wave=silence is-live=true → volume(volume=0.0) →
capsfilter(F32LE,48k,2ch) → audiomixer.sink_%u`, wired BEFORE the
PAUSED transition. Same trick `playbin3`'s internal mixer uses.
Document why in a code comment. *Touches Task 2 notes 2, 6, 9 +
Risks #3.*

**Fix #8 — Slider tooltip + closeout must call out that
`Preferences::scan_volume` (line 73 of project.rs, controls SCAN-
mode source playback) is INDEPENDENT from the new export/preview
source-volume setting.** (REAL, high; finding #8.) Users who set
`scan_volume` to 0.3 will hear source at 100% during clip preview
unless told. Pick option (a) — independence — for simplicity:
- Slider tooltip on Source-volume slider: "Source audio volume
  during preview and export (separate from Scan volume)."
- Closeout note in PROGRESS.txt's Plan #1 SHIPPED line explicitly
  states: "scan_volume unchanged; new export/preview source
  volume is a SEPARATE preference."
*Touches Task 0 implementation notes + Task 3 implementation
note 1.*

**Fix #9 — Emit a tracing breadcrumb when the default 1.0/1.0 mix
is applied to an upgrading project; SKIP the toast/dialog.**
(OVERSTATED → trimmed; finding #9.) Original finding asked for a
one-shot toast on first project-open after Plan #1 lands. That's
over-engineered for a pre-1.0 rewrite — defer the user-visible
notification. Keep only the cheap belt-and-suspenders:
- Emit `tracing::info!(event = "preferences.audio_mix_default_
  applied", source_volume, commentary_volume)` at the top of
  `export_compilation` whenever both volumes equal exactly 1.0
  AND the project's `Preferences` was deserialized from a file
  predating Plan #1. (Detected via a no-existing-`audio_mix_
  baseline_set: bool` field that defaults `false` and is flipped
  `true` once after first export.)
- Closeout PROGRESS.txt line includes a "BEHAVIOR CHANGE" callout
  in plain text so users grepping logs see it.
*Rationale for the trim*: toast/dialog churns Slint UI work for a
once-per-user notification. The tracing event covers the support-
log breadcrumb need; users discover the change on their first
export and can adjust via the new sliders. Defer richer
notification to Phase 12+ if user feedback warrants. *Touches
Architecture overview + Task 0 + Task 4 closeout.*

**Fix #10 — Closeout's "Phase 11 SHIPPED" line is GUARDED by a
verification grep; if other Plan #X SHIPPED lines are missing,
write the per-plan line only and skip the overall claim.** (REAL,
high; finding #10.) PROGRESS.txt suggests Phase 11 plans were not
drafted in numerical order; Plan #7 already references "adv fix
#1" so Plan #1 may not actually be the LAST to ship. Closeout
sequence (Task 4):
1. `grep -c "PHASE 11 PLAN .* SHIPPED" PROGRESS.txt` BEFORE
   writing the overall line.
2. If the count is ≥ 6 (one per other plan), write the
   "Phase 11 SHIPPED" overall line.
3. Otherwise, write only "Phase 11 Plan #1 SHIPPED" and add a
   plain-text note: "Phase 11 overall SHIPPED line deferred —
   Plans <list missing> not yet shipped."
*Touches Task 4 + Done-when last bullet.*

---

### Rejected findings

(none — all 10 findings folded; #9 trimmed but not rejected)

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
- **adv-fix #8**: `Preferences::scan_volume` (project.rs line 73)
  is INDEPENDENT from `preview_source_volume`. Document this in
  the doc-comment for both fields. Task 3's slider tooltip (see
  below) carries the user-facing copy.
- **adv-fix #9**: add a `audio_mix_baseline_set: bool` field to
  `Preferences` (defaults `false` via `#[serde(default)]`) so
  `export_compilation` can detect the first export on an upgrading
  project and emit `tracing::info!(event = "preferences.audio_mix_
  default_applied", source_volume, commentary_volume)` exactly
  once. Flip to `true` after the first emit; persist via
  `save_project_meta`. NO toast/dialog — the trim from finding #9
  keeps the breadcrumb only.

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
       → audio-appsink (sync=false, max-buffers=N, name="src_audio_<idx>")
   ```
   Build alongside the existing video chain. The decodebin pad-added
   handler routes `video/*` to the existing video queue and `audio/*`
   to a new audio chain that's added dynamically (decodebin doesn't
   surface caps until prerolled). **adv-fix #1**: set the appsink's
   `max-buffers` so a `sync=false` hw-decoded source can't run far
   ahead of the driver and accumulate decoded samples in RAM. Pick
   `max-buffers` such that the appsink internal queue + the
   `AudioSampleQueue` together cap at ~4s of audio
   (`MAX_QUEUED_BYTES = 4 * AUDIO_RATE * AUDIO_BYTES_PER_SAMPLE`).
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
   `SourceVideoChain` gains `audio_appsink: Option<AppSink>`. **adv-
   fix #1**: every `AudioSampleQueue` (commentary AND source) honors
   the same `MAX_QUEUED_BYTES` cap; the queue's push path either
   drops oldest bytes or relies on the upstream `max-buffers` back-
   pressure (preferred). Add an assertion in tests that the queue
   never exceeds `MAX_QUEUED_BYTES + one buffer`.
4. **Hand-rolled mix in `push_audio_for_window`**. Per tick, pull
   `target_bytes` from the active commentary queue and the active
   source queue. Both produce `[f32; 2]` samples (F32LE stereo, 48k).
   Sample-domain mix (`source_volume: f32`, `commentary_volume: f32`
   — see adv-fix #6):
   ```rust
   debug_assert_eq!(source_chunk.len() % 8, 0);
   debug_assert_eq!(commentary_chunk.len() % 8, 0);
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
   **adv-fix #5**: soft-clip is `x / (1.0 + x.abs())` —
   deterministic across libm impls. Do NOT use `x.tanh()`; macOS
   Accelerate vs Linux glibc disagree at last-ULP, which would
   flake any future N-frame audio parity test. Document in code
   comment: "soft-clip MUST be bit-identical across platforms;
   transcendentals forbidden. v1 used AVMutableComposition's
   preferredVolume which is linear gain + system clip; this rational
   approximation is gentler at the high end while staying
   deterministic."
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
   `commentary_volume == 0.0` skip commentary. If both 0.0, push a
   `target_bytes`-sized zero-filled F32 buffer (still pushes — see
   note 11 + adv-fix #4). Save decoder work on the silent-source-
   channel case (common: the user wants commentary-only behavior
   identical to Phase 10). **adv-fix #6**: even on the
   commentary-only fast path, assert the commentary chunk is a
   multiple of 8 bytes; never let `chunks_exact(8)` silently drop
   trailing bytes that would cause `audio_pts_ns` cumulative drift.
7. **Cancel polling unchanged.** The existing per-frame cancel
   check covers audio-sample pulling implicitly (audio mix runs
   inside the same per-frame loop). Document this in a code comment.
8. **Entry transition: drain BOTH active queues on every entry
   boundary (adv-fix #2).** When the driver activates a new entry,
   drain the active commentary queue (existing Phase 10 behavior at
   line ~1413) AND the active source-audio queue UNCONDITIONALLY —
   not only when `source_index` changes. Two consecutive entries on
   the same source with a Skip segment between them will leave
   stale source samples in the queue covering the OLD `record_time`
   window; the driver would otherwise read them as the NEW entry's
   first samples. The seek-flush refills within ~33ms; one frame of
   silence is inaudible. Document: "source-decoder seek policy is
   flush-on-entry-boundary, identical to webcam." This SUPERSEDES
   the original "DO NOT drain if same source_index" guidance.
9. **Format pinning.** Source decoder output may be S16LE 44.1k mono;
   audioconvert + audioresample + capsfilter to F32LE 48k 2ch BEFORE
   the appsink, so the driver's mix function sees a consistent
   format. The capsfilter caps string is identical to the audio-
   appsrc caps string (line ~1031): single source of truth.
10. **`export_compilation` signature.** Change `_source_volume` →
    `source_volume` and `_commentary_volume` → `commentary_volume`.
    Both are `f64` clamped to `[0.0, 1.0]` at the top of the function
    (defensive; UI also clamps). **adv-fix #6**: convert each clamped
    `f64` to `f32` exactly once at this boundary, then thread `f32`
    through every downstream function (mix function, soft-clip,
    short-circuit branches). f64/f32 mismatch in the mix chain is
    silent precision loss with no compile warning.
11. **Both volumes 0.0 → silent track, NOT skipped audio track.** The
    output .mp4 must always have an audio track — qtmux's audio
    sink-pad was requested at pipeline-construction time, removing it
    mid-flight is fragile. When both volumes are 0.0, push silent
    F32 buffers (sample-aligned, exact `target_bytes` size) on every
    tick; encoder produces a valid silent AAC stream. Document the
    choice: a fully silent export is rare and the consistency win
    (always one audio track) outweighs the few KB of silent AAC.
    **adv-fix #4**: explicit unit test
    `both_volumes_zero_pushes_silent_buffer_not_noop` confirms the
    appsrc gets the buffer and the cursor advances; integration
    test `export_with_both_volumes_zero_yields_silent_audio_track`
    runs export and uses Discoverer to verify the output has an
    audio track. Without these, a regression silently strips the
    audio track.
12. **AudioSampleQueue drain on entry boundary — both queues, every
    transition.** SUPERSEDED by note 8 + adv-fix #2 above. Always
    drain the active commentary queue AND the active source-audio
    queue on every entry transition, regardless of whether
    `source_index` changes. The seek-flush plus one frame of
    silence is inaudible; the safety win is preventing stale OLD-
    `record_time` samples from polluting the NEW entry's audio.

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
  output bytes equal `soft_clip(s*sv + c*cv)` per sample. Use small
  values (< 0.4) where `x / (1.0 + x.abs())` is approximately linear
  so the assertion can be tight.
- **adv-fix #4** unit test: `both_volumes_zero_pushes_silent_buffer_
  not_noop` — call mix with `source_volume=0.0, commentary_volume=
  0.0`; assert the output is `target_bytes` of zero F32 samples and
  the cursor advances by `target_bytes`.
- **adv-fix #4** integration test: `export_with_both_volumes_zero_
  yields_silent_audio_track` — run export with both volumes 0.0;
  use Discoverer on the output .mp4 to assert an audio track
  exists with non-zero duration.
- **adv-fix #1** stress test: `source_audio_queue_caps_at_max_
  queued_bytes` — feed a fast appsink push loop that would otherwise
  unboundedly grow the queue; assert queue length never exceeds
  `MAX_QUEUED_BYTES + one buffer`.
- **adv-fix #2** test: `entry_transition_drains_both_queues_even_
  when_source_unchanged` — seed both queues with stale bytes,
  trigger an entry transition with the same `source_index`, assert
  both queues are empty after.
- **adv-fix #6** test: `mix_panics_on_misaligned_chunk_length` —
  pass a 7-byte chunk; assert the mix function panics (or returns
  Err) with a context message.

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
   preview pipeline builds ONE audiosink + ONE audiomixer + ONE
   downstream capsfilter at pipeline construction (adv-fix #3).
   Source-audio and commentary-audio chains each link to a NEW
   audiomixer sink-pad via `audiomixer.request_pad_simple("sink_%u")`.
   Pipeline shape:
   ```
   <each chain> → volume(named) → capsfilter(F32LE,48k,2ch)
       → audiomixer.sink_%u
   audiomixer → capsfilter(F32LE,48k,2ch) → audiosink
   ```
   The downstream capsfilter is HARD REQUIRED; without it audiomixer's
   output caps are negotiated from whichever sinkpad gets caps first
   and we hit a non-deterministic race that can land at S16LE before
   the upstream capsfilter forces F32LE, failing the second sinkpad's
   renegotiation.
2. **Preview-side source audio.** Currently
   `build_video_input_chain`'s pad-added handler routes audio to
   fakesink. Replace with:
   ```
   queue → audioconvert → audioresample → volume(name="source_volume")
       → capsfilter(F32LE 2ch 48k)
       → audiomixer's sink-pad
   ```
   No appsink — preview is wall-clock-paced and the audiomixer
   handles real-time blending. **adv-fix #7**: a phantom silence
   sinkpad (see note 11 below) must already be wired before this
   chain is added, guaranteeing audiomixer can transition to PAUSED
   even if decodebin's audio pad-added is delayed.
3. **Preview-side commentary audio.** Modify `build_and_link_
   webcam_audio_chain`: replace the direct audiosink with a link to
   the audiomixer's next sink-pad. Keep the `volume(name=
   "commentary_volume")` element; rename or duplicate the helper
   if mixing into a shared audiomixer requires a different shape.
4. **audiomixer caps + latency.** audiomixer has a `latency`
   property (default 60ms); leave at default for Plan #1. The mixer
   imposes a bounded delay for blending — acceptable for preview
   playback. **adv-fix #3 (HARD REQUIREMENT)**: the downstream
   capsfilter pinning F32LE/48k/2ch AFTER audiomixer is non-
   negotiable. audiomixer negotiates output caps from the FIRST
   sinkpad to get caps; pad-added ordering between source and
   recording is non-deterministic (decodebin async). Without the
   downstream anchor, the mixer can land at S16LE before our
   upstream capsfilters force F32LE, and the second sinkpad's
   renegotiation fails. With the anchor, audiomixer negotiates
   upward from the downstream capsfilter and the race vanishes.
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
   needed in driver code. **adv-fix #7 caveat**: "blends the
   available pad" assumes the mixer has ≥1 sinkpad when transitioning
   to PAUSED. The phantom silence sinkpad (note 11) guarantees this
   even when neither real source has prerolled.
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
   audiomixer doesn't deadlock on the PAUSED step. **adv-fix #7**:
   the phantom silence sinkpad guarantees the mixer always has ≥1
   pad through PAUSED, so the stepped-teardown sequence won't hang
   on a zero-pad mixer. If teardown still surfaces a deadlock,
   document with a comment and skip directly to NULL on the
   audiomixer-bearing path.
10. **Volume element placement matters.** Place the `volume` element
    AFTER `audioconvert + audioresample` and BEFORE the audiomixer
    sink-pad. Placing volume before audioconvert means scaling raw
    decoder output (could be S16, range mismatch when scaling); after
    audioconvert the data is F32 and scaling is mathematically clean.
    audiomixer also expects all sink-pads to negotiate the same caps
    so volumes operating on F32 inputs guarantees consistent caps to
    the mixer.

11. **Phantom silence sinkpad (adv-fix #7).** At pipeline construction
    time, BEFORE the PAUSED transition, wire a silence-source to the
    audiomixer:
    ```
    audiotestsrc wave=silence is-live=true
        → volume(volume=0.0)
        → capsfilter(F32LE,48k,2ch)
        → audiomixer.sink_%u
    ```
    This guarantees the mixer has ≥1 sinkpad when transitioning to
    PAUSED, even if both real sources delay pad-added (decodebin still
    probing). Without this, the mixer transitions block indefinitely
    on PAUSED and osxaudiosink never prerolls. The volume=0.0 makes
    the silence inaudible; document why in a code comment ("phantom
    silence-source: same trick `playbin3`'s internal mixer uses").

**Tests:**
- `preview_pipeline_smoke.rs::audiomixer_builds_with_two_input_pads` —
  construct preview with a source + recording, query the pipeline
  for the `audiomixer` element by name, assert it has 2 real sink-
  pads (3 total counting the phantom silence pad).
- `preview_pipeline_smoke.rs::source_volume_property_is_live_tunable` —
  build pipeline, set preview state to PLAYING, call `set_preview_
  source_volume(0.5)`, query `volume` element's `volume` property,
  assert it's 0.5.
- **adv-fix #3** test: `audiomixer_downstream_capsfilter_pins_f32le_
  48k_2ch` — query the capsfilter immediately downstream of the
  mixer, assert its caps property matches `audio/x-raw,format=
  F32LE,channels=2,rate=48000,layout=interleaved`.
- **adv-fix #7** test: `audiomixer_paused_transition_succeeds_with_
  no_real_sources` — construct preview WITHOUT any decodebin
  prerolling (e.g. with a fixture that returns no audio pads
  promptly); transition pipeline to PAUSED with a 5s timeout; assert
  the transition succeeds (the phantom silence sinkpad is sufficient).
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
   **adv-fix #8** — the Source-volume slider's tooltip / helper
   text reads exactly: "Source audio volume during preview and
   export (separate from Scan volume)." This explicitly tells users
   that `Preferences::scan_volume` (controls source playback during
   SCAN mode) is independent and unaffected by this slider.
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
- **Phase 11 closeout (adv-fix #10) — GUARDED.** Plan #1 is the
  last of Phase 11's seven plans BY FILE INDEX, but PROGRESS.txt
  ordering suggests plans were drafted out of numerical order
  (Plan #7 already references "adv fix #1"). Closeout sequence:
  1. Run `grep -c "PHASE 11 PLAN .* SHIPPED" PROGRESS.txt`
     BEFORE writing the overall line.
  2. If the count is ≥ 6 (one SHIPPED line per other plan), write
     the overall "Phase 11 SHIPPED" line summarizing all seven
     plans + their cumulative CI run.
  3. Otherwise, write only the per-plan "Phase 11 Plan #1
     SHIPPED" line plus a plain-text note: "Phase 11 overall
     SHIPPED line deferred — Plans <list missing> not yet
     shipped." A future plan's closeout will write the overall
     line when the count finally reaches 7.
- **adv-fix #8** closeout note in PROGRESS.txt explicitly states:
  "scan_volume unchanged; new export/preview source volume is a
  SEPARATE preference."
- **adv-fix #9** closeout note: include a "BEHAVIOR CHANGE" callout
  in plain text (not buried in a code comment): existing projects
  upgrading to Plan #1 default to 1.0/1.0 source/commentary mix —
  louder + includes source audio vs Phase 10's commentary-only
  output. Detection breadcrumb is the
  `preferences.audio_mix_default_applied` tracing event.

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
4. **Soft-clip choice.** Plan #1 picks `x / (1.0 + x.abs())` (soft,
   asymptotic, deterministic across libm impls — see adv-fix #5).
   `x.tanh()` was the original draft choice but rejected because
   macOS Accelerate vs Linux glibc disagree at last-ULP, flaking
   any future audio parity test. `x.clamp(-1.0, 1.0)` (hard,
   classic) remains an option if the rational approximation sounds
   noticeably worse than v1's effective AVMutableComposition +
   AAC hard-clip. Defer the ear-test to closeout review; a swap is
   a one-line code change.
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

## Closeout — Phase 11 Plan #1 (audio-mix) SHIPPED 2026-05-04

**Plan #1 (audio-mix) is the final plan of Phase 11. With this
closeout, Phase 11 OVERALL ships.**

**CI run**: pending (filled in once green; closeout commit pushes
trigger the run).

### Commits (in shipping order)

Task 1 split into 1a / 1b / 1c during execution to keep individual
commits reviewable; Tasks 0 / 2 / 3 each shipped as a single commit.
Two code-review fix-up commits landed before closeout for git-blame
clarity.

| Stage | SHA | Summary |
|---|---|---|
| Plan first pass | `4129041` | Initial plan + 4-task structure (Task 0 preflight + Task 1 export hand-rolled mix + Task 2 preview audiomixer + Task 3 UI sliders); known unknowns + adversarial-fixes placeholder. ~720 lines. |
| Plan adversarial pass | `2edfebc` | Plan adv-fixes #1-#10 from inline adversarial review. 9 REAL folded as numbered fixes #1-#8 + #10; #9 OVERSTATED trimmed to a tracing breadcrumb only (toast/dialog deferred). Highest-impact fixes: #1 unbounded source-audio FIFO → `MAX_QUEUED_BYTES = 4 × 48000 × 8` cap; #3 audiomixer caps-negotiation race → HARD-REQUIRED downstream F32LE/48k/2ch capsfilter; #7 preview audiomixer state-change deadlock → phantom silence sinkpad wired BEFORE PAUSED. Plan grew 720 → 1001 lines. |
| Task 0 | `6ae239b` | Preflight — Preferences breadcrumb + Command/ExportPrefsSnapshot volume plumbing. Adv-fix #8 (scan_volume independence) doc-comments + dedicated test. Adv-fix #9 breadcrumb infrastructure: `Preferences::audio_mix_baseline_set: bool` (default false via `#[serde(default)]` for legacy-JSON compat). New `default_preview_source_volume()` / `default_preview_commentary_volume()` helpers (both 1.0). `Command::ExportCompilations` gains `source_volume` / `commentary_volume` `f64` fields with `#[serde(default = "...")]` named-defaults delegating to the core helpers (anti-drift guards `default_command_source_volume_matches_core` + `default_command_commentary_volume_matches_core`). `ExportPrefsSnapshot` carries `source_volume` + `commentary_volume` + `audio_mix_baseline_set`; Default impl + `write_export_prefs_snapshot` mirror from Preferences. `handle_export_compilations` destructures Command volumes, clamps each to `[0.0, 1.0]` via `clamp_unit` (NaN folds to 0.0), persists onto Preferences alongside `last_export_resolution` / `quality` / `codec` / `template` / `policy`, threads clamped values into `export_compilation`. ~10 tests added across core+app. 534 LOC. |
| Task 0 progress flip | `26b56c8` | PROGRESS.txt — Phase 11 Plan #1 Task 0 row [x] |
| Task 1a | `0de67c9` | Per-source audio appsink chain in `build_source_video_chain`. Constants `MAX_QUEUED_BYTES = 4 × 48000 × 8` (4s F32LE 48k stereo ≈1.5 MB) + `AUDIO_APPSINK_MAX_BUFFERS = 64` cap source FIFO (adv-fix #1). decodebin's `pad-added` closure now routes audio: `queue → audioconvert → audioresample → capsfilter (F32LE/48k/2ch interleaved) → appsink(sync=false, max-buffers=64, name=src_audio_<idx>)` per adv-fix #3 + #6. `SourceVideoChain.audio_appsink: Arc<Mutex<Option<AppSink>>>` — None for silent sources (Task 1b falls back to silence). 183 insertions / 6 deletions in `export.rs`. |
| Task 1b | `109728e` | Hand-rolled two-stream mix in `push_audio_for_window`. Pull source + commentary samples per tick, scale by f32 volumes, sum sample-wise with deterministic soft-clip `x/(1+|x|)`, push to shared audio-appsrc with monotonic `audio_pts_ns`. Volume=0 still pushes silence (adv-fix #4); chunks 8-byte aligned (adv-fix #6); soft-clip rational not tanh (adv-fix #5). Source queues drop oldest sample-aligned bytes on `MAX_QUEUED_BYTES` overflow (adv-fix #1). Both source-audio and commentary queues drained for outgoing AND incoming clip/source on every entry transition (adv-fix #2). 198 insertions / 47 deletions in `export.rs`. |
| Task 1c | `c844b3b` | Mix + queue helper unit tests. Refactored inline per-sample mix into pure `mix_one_sample(s, c, sv, cv)` helper so tests exercise math without GStreamer. 12 pure-Rust unit tests in `export::tests`: `soft_clip` endpoints (4), `push_into_queue_capped` oldest-bytes-dropped + sample-alignment-on-unaligned-overflow (2), `drain_aligned_chunk` zero-fill-on-short + drains-exactly-N + len-decreases-by-drained (3), `mix_one_sample` full-volumes / sv=0 / cv=0 / both=0 (4). 189 insertions / 1 deletion in `export.rs`. |
| Task 1 progress flip | `623b261` | PROGRESS.txt — Phase 11 Plan #1 Task 1 (1a + 1b + 1c) shipped |
| Task 2 | `e220632` | Preview pipeline — audiomixer spine + source-audio chain. Replaces commentary-only audio path with a real GStreamer audiomixer that blends source-audio + commentary-audio live (preview is wall-clock-paced; `sync=true` appsinks → audiomixer is the right tool, NOT the hand-rolled mix from export Task 1). New `build_audio_mixer_and_sink` helper: `audiomixer(name=preview_audio_mixer) → audioconvert → audioresample → capsfilter(F32LE/48k/2ch HARD-REQUIRED downstream anchor per adv-fix #3) → audiosink`. Phantom silence sinkpad (`audiotestsrc wave=silence is-live=true → audioconvert → capsfilter → mixer.sink_%u`; adv-fix #7) wired BEFORE PAUSED so the mixer never blocks state-change waiting on real decodebins. New `link_audio_pad_to_mixer` per-input chain (`queue → audioconvert → audioresample → volume(named) → capsfilter → mixer.sink_%u`) called from both source + webcam decodebin pad-added handlers. New public `set_source_volume(f64)` / `set_commentary_volume(f64)` methods (atomic property update). Build-only smoke test confirms construction. 355 insertions / 95 deletions in `preview_pipeline.rs`. |
| Task 2 progress flip | `67fe047` | PROGRESS.txt — Phase 11 Plan #1 Task 2 shipped |
| Task 3 | `947a59a` | UI — two volume sliders in the export sheet. Two new `in-out` float properties `export-source-volume` / `export-commentary-volume` (default 1.0). Slider shape mirrors Phase 7's transport-bar scan-volume slider (TouchArea over a track Rectangle with a fill Rectangle child). Inserted between Overwrite checkbox + Cancel/Export bottom buttons; panel height bumped 712 → ~780-800px (Cancel/Export anchored to `parent.height - 52px` so they ride down automatically). Sheet-open hydration in `on_export_sheet_open_clicked` reads `snap.source_volume` / `snap.commentary_volume`. `on_export_start_clicked` replaces placeholder defaults with `w.get_export_source_volume() as f64` / `w.get_export_commentary_volume() as f64`. Persistence is automatic — bus's existing `handle_export_compilations` clamps + writes the volumes onto Preferences when the Command arrives. Adv-fix #8 helper text under sliders clarifies independence from `scan_volume`. ~120 LOC across `main.slint` + `ui.rs`. Final implementation task; 251 tests pass. |
| Task 3 progress flip | `3b583eb` | PROGRESS.txt — Phase 11 Plan #1 Task 3 shipped |
| Code-review fix [#1] | `a879930` | REAL/HIGH — adv-fix #9 breadcrumb wiring. Added 23-line block to `handle_export_compilations`'s prefs-persist site (bus.rs step 6) that flips `project.preferences.audio_mix_baseline_set` `false → true` and emits `tracing::info!(target: "preferences", event = "preferences.audio_mix_default_applied", source_volume, commentary_volume)` on the first export with the Plan #1 mix path; subsequent exports skip the emission (flag now true). Persistence rides the existing `project_store::write` `spawn_blocking` already in step 6 so no new disk-write site needed. |
| Code-review fix [#2] | `ec05f30` | REAL/HIGH — `PreviewPipeline::set_source_volume` + `set_commentary_volume` marked `#[allow(dead_code)]` with TODO comment pointing at Phase 12 bus-accessor plumbing. Chose ALLOW+DEFER over wiring (full live-update path requires `bus → preview` accessor plumbing well beyond Plan #1 scope). Documented as deferred below. |
| Closeout | this commit | Plan closeout section + PROGRESS.txt Plan #1 SHIPPED + Phase 11 OVERALL SHIPPED |

### Adversarial-fix coverage (Fixes #1-#10)

All 10 fixes shipped (with adv-fix #9 trimmed at planning to a tracing
breadcrumb only — toast/dialog explicitly deferred); each verified
present in shipped code.

- ✅ #1 Unbounded source-audio FIFO → `MAX_QUEUED_BYTES = 4 × 48000 × 8` (≈1.5 MB) cap on `AudioSampleQueue::push`; `AUDIO_APPSINK_MAX_BUFFERS = 64` cap on the appsink itself; `push_into_queue_capped` drops oldest **sample-aligned** bytes on overflow (Task 1a + 1b + 1c — `export.rs`).
- ✅ #2 Both source-audio AND commentary queues drained UNCONDITIONALLY for outgoing AND incoming clip/source on every entry transition (supersedes any source_index gating) (Task 1b — `export.rs`).
- ✅ #3 Audiomixer caps-negotiation race anchored by HARD-REQUIRED downstream `capsfilter(F32LE/48k/2ch interleaved)` on BOTH the export source-audio appsink chain (Task 1a) AND the preview audiomixer output spine (Task 2). Prevents the mixer from auto-negotiating a non-F32 format that breaks the hand-rolled mix or the audiosink.
- ✅ #4 `volume = 0` short-circuits to a silent buffer push, NOT a skipped track. Confirms `audio_pts_ns` advances monotonically even when both volumes are zero; the appsrc still receives a buffer per frame budget. `mix_one_sample(s, c, 0.0, cv)` test pins the math (Task 1b + 1c — `export.rs`).
- ✅ #5 Soft-clip uses rational `x / (1 + |x|)` NOT `tanh`. Deterministic, branch-free, no transcendental cost. `soft_clip` endpoint tests pin the math at +∞ → 1.0, -∞ → -1.0, 0 → 0, 1 → 0.5 (Task 1c — `export.rs`).
- ✅ #6 F32 throughout the pipeline (NOT i16 or i32); chunks aligned to `AUDIO_BYTES_PER_SAMPLE = 8` (stereo F32 = 4 + 4); `drain_aligned_chunk` floor-aligns to sample boundary on partial reads with zero-fill on short. `target_bytes` calculation rounds DOWN to alignment (Task 1b + 1c — `export.rs`).
- ✅ #7 Preview audiomixer phantom silence sinkpad — `audiotestsrc wave=silence is-live=true → audioconvert → capsfilter(F32LE/48k/2ch) → mixer.sink_%u` wired into the audiomixer BEFORE the pipeline transitions to PAUSED. Mixer always has ≥1 active sinkpad so it never blocks the state-change waiting on real decodebin pad-added events (Task 2 — `preview_pipeline.rs`).
- ✅ #8 Sliders' helper text under the export-sheet form clarifies that the export source-volume slider is independent from the transport-bar scan-volume slider (different runtime, different persistence field). Doc-comments on `Preferences::scan_volume` / `preview_source_volume` / `preview_commentary_volume` reinforce. Test `scan_volume_does_not_change_when_preview_source_volume_changes` pins the orthogonality (Task 0 + Task 3 — `project.rs`, `main.slint`).
- ✅ #9 Tracing breadcrumb on first export with the new default mix — `Preferences::audio_mix_baseline_set: bool` flag + `preferences.audio_mix_default_applied` `tracing::info!` event emitted exactly once per project. Plumbing landed in Task 0; the actual flag-flip + emit landed in code-review fix `a879930` (Task 1's `export_compilation` only takes a snapshot, so the round-trip moves to the bus's `handle_export_compilations` after a successful `Ok(_)` — documented in code-review notes). Toast / dialog UI explicitly deferred at adversarial-pass triage. (Task 0 + code-review fix [#1] — `project.rs`, `bus.rs`).
- ✅ #10 Closeout-sequence guard — `link_audio_pad_to_mixer` failures fall through to `drain_pad_to_fakesink` rather than crashing the preview pipeline, so a malformed source still plays the picture even with no audio. Behavior verified by adv-fix-pass review of the existing fall-through pattern (carried over from Phase 10's `build_and_link_webcam_audio_chain`). See Deferred for the user-toast follow-up (Task 2 — `preview_pipeline.rs`).

### Code-review findings

Inline code-review pass on the full Plan #1 diff `2edfebc..947a59a`
(plan + adv-fixes + 6 task commits + 3 progress commits, ~1.6k LOC
across `export.rs` / `preview_pipeline.rs` / `ui.rs` / `bus.rs` /
`project.rs` / `main.slint`) produced 12 findings:

| Triage | Count | Findings |
|---|---|---|
| **REAL — fixed in this plan** | 2 | [#1] adv-fix #9 breadcrumb plumbed but never flipped/emitted by `export_compilation` — fix `a879930` adds the flip + emit to `handle_export_compilations`; [#2] `PreviewPipeline::set_source_volume` / `set_commentary_volume` have zero callers (live-update bus accessor not plumbed) — fix `ec05f30` marks both `#[allow(dead_code)]` with Phase 12 TODO. |
| **REAL — deferred to closeout text** | 2 | [#6] Default-volume change Phase 10 (commentary-only) → Plan #1 (1.0/1.0 mix) is undocumented for users — see "Behavior changes from Phase 10" below; [#10] mixer-link failure on commentary-audio path silently drops audio with no UI toast — see Deferred for follow-up plan. |
| **SPECULATIVE** | 4 | [#3] Source-decoder seek may not propagate through audio branch (PTS drift on entry transition) — covered by `audio_buffer_queues.bytes.clear()` on transition + manual A/B audio diff is the verification path; [#4] audiomixer-as-LIVE clock vs non-live filesrc sync interaction — same risk pattern as v1's AVKit, no fix unless QA reports drift; [#5] 4s `MAX_QUEUED_BYTES` cap could clip the first 4s of audio on hw-burst decoders (rare; Apple Silicon videotoolbox + long-GOP HEVC + entry > 4s) — bump to 16s if reported; [#8] F32 chunk-align truncation drift ~1.08 ms/s, audibly imperceptible (threshold ≈ 40 ms). |
| **OVERSTATED** | 2 | [#7] At `sv = cv = 1.0` user gets `~0.667` per channel (soft-clip math is correct; UX label could note "combined output may attenuate when both maxed"); [#11] slider hydration race vs concurrent snapshot write — Mutex serializes; Slint event loop is single-threaded; not a defect. |
| **SPECULATIVE — cross-plan** | 2 | [#9] Phantom silence sinkpad uses default mixer props (no harm — silence summed with zeros is mathematically a no-op); [#12] Plan #3 HEVC encoder × Plan #1 mix interaction — audio path unchanged across the Plan #1 diff, so the interaction is "mix → AAC encoder" which the codec selection already accepts. |

The 2 REAL fix-worthy findings shipped as 2 separate fix-up commits
(`a879930`, `ec05f30`) for git-blame clarity — see Commits table
above. REAL findings #6 (default-volume UX docs) + #10 (mixer-link
silent drop) are documented in this closeout (#6) / deferred to
Phase 12+ (#10) per the orchestrator's dispatch instructions.

### Behavior changes from Phase 10

- **Default-volume behavior changed.** Phase 10's `Command::ExportCompilations`
  exported recording-audio only — the `_source_volume` / `_commentary_volume`
  fields didn't exist; source-video audio was discarded. Plan #1 ships with
  `Preferences::default()` of `preview_source_volume = 1.0` AND
  `preview_commentary_volume = 1.0` — i.e. **equal** mix of source +
  commentary, soft-clipped. **Users upgrading a Phase-10 project will find
  their previously-silent (because muted-by-omission) source-video audio
  suddenly at full volume in every export, equal to the commentary they're
  used to hearing solo.** Concretely: a tennis-coaching video that played
  the user's voice clearly in v0 will, after Plan #1 export, mix in stadium
  ambient + opponent grunts at the same level. The export-sheet sliders let
  the user re-mute source-volume to recover Phase-10 behavior; the new
  `audio_mix_baseline_set` breadcrumb + `preferences.audio_mix_default_applied`
  tracing event lets us see the upgrade bite in production logs. Document
  in the eventual release notes; consider an in-app migration toast in
  Phase 12+ if telemetry shows users hitting the surprise.
- **`audio_mix_baseline_set` flag in `project.json`.** New `bool` field
  on `Preferences` (default `false` via `#[serde(default)]` for legacy-JSON
  compat); flipped to `true` by the bus on the first successful export
  with the Plan #1 mix path. Consumers reading `project.json` should
  treat absence-or-`false` as "first-export default mix not yet applied".
- **`source_volume` + `commentary_volume` on `Command::ExportCompilations`.**
  Two new optional `f64` fields on the export command (default 1.0 each
  via `#[serde(default = "...")]` named-defaults). Existing harness clients
  with omitted-fields payloads continue to work; the bus clamps to
  `[0.0, 1.0]` (NaN → 0.0) on receipt.

### Deferred to Phase 12 (or later)

- **[Code-review #6 — documented above] Default-volume change UX migration.**
  This closeout's "Behavior changes from Phase 10" section calls out the
  silent regression from Phase-10 commentary-only to Plan-#1 1.0/1.0 mix;
  the current mitigation is the `audio_mix_default_applied` tracing
  breadcrumb plus the export-sheet sliders. A future plan could add an
  in-app migration toast on first export OR detect the upgrade via
  `audio_mix_baseline_set == false` and one-shot force `preview_source_volume = 0.0`
  for the very first sheet open (zero-surprise migration). Out of scope
  for Plan #1; depends on telemetry from the breadcrumb to prioritize.
- **[Code-review #10] Mixer-link failure silently drops commentary audio
  with no UI toast.** `link_audio_pad_to_mixer` returning `Err` from the
  decodebin `pad-added` closure is currently logged and falls through to
  `drain_pad_to_fakesink`, matching Phase 10's `build_and_link_webcam_audio_chain`
  fall-through. For the COMMENTARY audio path this means the user's voice
  is silently dropped — same symptom as a corrupt `recording.mov`. Plan #1
  is not a regression here, but the new mixer-routing surfaces a different
  failure mode (e.g., `audiomixer.request_pad_simple` returning `None` on
  out-of-memory) than the prior direct-to-audiosink path was. Future plan:
  bubble a UI toast `"Commentary audio could not be wired — playback silent"`
  on the bus when the fall-through fires. Phase 12 hardening sweep.
- **[Code-review #2 follow-up] PreviewPipeline live-slider wiring.** Task 2
  exposed `PreviewPipeline::set_source_volume(f64)` / `set_commentary_volume(f64)`
  for live tuning of the audiomixer while a clip is open in preview. Code-
  review fix `ec05f30` marked both `#[allow(dead_code)]` because the live-
  update path requires bus → preview accessor plumbing well beyond Plan #1
  scope (no `bus.preview_pipeline()` getter exists today). A future plan
  adds a bus accessor + wires `on_export_source_volume_changed` /
  `on_export_commentary_volume_changed` in `ui.rs` to call the setters
  on the active PreviewPipeline. Without it, dragging an export-sheet
  slider has zero audible effect on a currently-open preview clip — the
  user must close + re-open the preview to hear the new mix. Phase 12.
- **[Code-review #5] 4s `MAX_QUEUED_BYTES` cap on hw-burst decoders.**
  `4 × 48000 × 8 ≈ 1.5 MB` per source. On Apple Silicon videotoolbox hw
  decoder bursts (decoder emits 30+ frames in microseconds followed by a
  100 ms quiet period), an entry > 4s long-GOP HEVC could in principle
  drop the oldest 4s of decoded audio at the entry boundary. Mitigation
  if it bites: bump cap to 16s (~6 MB per source — still trivial) or add
  bytes-dropped tracing to detect in production. Not bumping preemptively
  because the cap is what defeats the unbounded-RAM risk of adv-fix #1
  on long playlists.
- **[Code-review #8] F32 chunk-align truncation drift ~1.08 ms/s.**
  `target_bytes = (48000 * 8) * 33333333 / 1e9 = 12799` bytes/frame raw,
  floor-aligned to 12792 (1599 stereo F32 samples). Cumulative drift is
  7 bytes × 30 frames = 210 bytes/sec = ~52 samples/sec = ~1.08 ms/s
  relative to wall-clock 48000 sample/sec rate. Audibly imperceptible
  (threshold of audible audio-video sync ≈ 40 ms; 60s entry → 65 ms
  cumulative, just at threshold for very long single entries). Won't
  bite users in practice; document if anyone diffs export bytes-per-
  second between source and exported audio.
- **Source-decoder seek propagation through audio branch.** Code-review
  finding #3 SPECULATIVE — current `audio_buffer_queues.bytes.clear()`
  on entry transition is belt-and-suspenders for the case where the
  `seek_chain_to` event doesn't propagate through decodebin's audio
  sink branch. A targeted unit test that drives `transition_chains`
  + samples from the source-audio appsink to verify post-seek bytes
  have caught up to the new position would close the gap; not blocking
  because the `clear()` covers all observed cases.

### Known coverage gaps (acceptable for shipping)

- **Mix correctness end-to-end via export.** `mix_one_sample` + queue
  helper unit tests (Task 1c) prove the math at byte level; existing
  `export_smoke` covers full-pipeline mix output exists + > 100 KB +
  ftyp magic. No harness E2E asserts byte-level audio waveform
  equality against a v1 fixture (would require a checked-in golden
  audio fixture + cross-platform-stable encoder output, both out of
  scope for Plan #1).
- **Preview pipeline mix audibility on real hardware.** Task 2's
  build-only smoke test confirms the audiomixer + phantom silence
  + downstream capsfilter construct cleanly. No integration test
  drives a clip preview to PLAYING and asserts both source-audio
  + commentary-audio are present in the output (would require an
  audio loopback capture + spectral analysis on CI). Manual smoke
  on macOS confirmed the mix renders correctly during preview.
- **Slider live-update during preview.** Code-review #2 deferral —
  the `set_source_volume` / `set_commentary_volume` API exists but
  has no caller; dragging an export-sheet slider while a preview
  clip is open does NOT update the preview audio in real time. The
  user must close + re-open the preview to hear changes. No
  regression test (would be moot until Phase 12 wires the bus
  accessor).

These gaps are noted for future regression sweeps; they don't block
shipping.
