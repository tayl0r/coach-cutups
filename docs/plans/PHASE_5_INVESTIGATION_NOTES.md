# Phase 5 Task 3 — Investigation Notes (paused)

Phase 5 Task 3 (single-input passthrough through appsink → appsrc) hit a real GStreamer deadlock that 5+ iterations did not resolve. The WIP is in `git stash` (`stash@{0}: phase-5-task-3-wip-debug`).

## What works

- Phases 1–4 ship clean and CI-green (commits up to `6134277`).
- `gst-launch-1.0` can do the equivalent direct pipeline in 5.5s and produces a 46 MB .mov:
  ```
  filesrc location=fixtures/source-1080p.mp4
    ! decodebin name=db
    db. ! videoconvert ! video/x-raw,format=NV12 ! vtenc_h264 ! h264parse ! qtmux ! filesink location=...
    db. ! fakesink
  ```
- `gst-launch-1.0 ... ! videoconvert ! video/x-raw,format=RGBA ! filesink ...` produces 14 GB of valid RGBA in 12 s — RGBA conversion works fine.
- Phase 4's headless wgpu compositor works standalone (PiP + golden hash, all 60 tests pass on macOS).

## Where Task 3's pipeline gets stuck

The Rust pipeline:

```
filesrc → decodebin → videoconvert_in → capsfilter("video/x-raw,format=RGBA") → appsink
                                                                                  ↓ (Rust callback — never fires)
appsrc → videoconvert_out → capsfilter("video/x-raw,format=NV12") → vtenc_h264 → h264parse → qtmux → filesink
```

Bus log evidence (with `bus.timed_pop` instead of filtered):

1. `set_state(Playing) → Ok(Async)`
2. State changes propagate through OUTPUT chain (filesink, qtmux, encoders, etc.).
3. Decodebin pad-added fires for video/x-raw — link to videoconvert_in_sink succeeds.
4. Pad-added fires for audio/x-raw — fakesink path runs (no error).
5. State changes propagate through INPUT chain (decodebin, fakesink, then appsink).
6. Many `Tag` messages arrive at appsink and fakesink — metadata is flowing.
7. **Final message: `StateChanged from appsink0` + `Latency from appsink0`. Pipeline appears fully PLAYING.**
8. `new_sample` callback — never invoked. No buffers reach Rust.
9. After 20s timeout — bus loop exits via "timeout waiting for filesink EOS".

## Hypotheses tried + ruled out

| Attempted fix | Result |
|---|---|
| Forward source caps to appsrc on first sample (`appsrc.set_caps(Some(&owned))`) | Compiled. Did not unblock. (Caps fix did kill an earlier `gst_util_fraction_*` divide-by-zero CRITICAL though — there are TWO bugs at minimum.) |
| Set explicit framerate=30/1 in appsrc construction caps | Killed the divide-by-zero CRITICAL. Did not unblock new_sample firing. |
| Add capsfilter NV12 between videoconvert_out and vtenc_h264 | Did not change behavior. |
| Drop `caps()` from appsink builder (let capsfilter constrain) | Did not change behavior. |
| Add `emit_signals(true)` on appsink | Did not change behavior. |
| Add `max_buffers(1)`, `drop(false)` on appsink | Did not change behavior. |

## What I haven't tried yet

- **Pad probe instead of appsink callback.** Attach a buffer-probe directly to the videoconvert_in src pad; pull bytes there. Bypasses the appsink mechanism entirely.
- **Two separate pipelines connected by an `mpsc::channel`.** Input pipeline (filesrc → ... → fakesink with pad probe) sends bytes into a channel; output pipeline (appsrc → ... → filesink) reads from the channel. Decouples state-change coordination.
- **`appsink::pull_sample` polled from a thread**, not via callback. Explicitly pull buffers in a loop rather than relying on `new_sample` firing.
- **Compare against a known-working gstreamer-rs example.** The `gstreamer-rs` repo has `examples/src/bin/appsink.rs` that does exactly this. Run it, then minimally diff against my code.

The fourth option is the highest-EV next step — comparing against working code rather than poking around blindly.

## State of the repo

- Branch: `rust-rewrite` at `6134277` (Phase 5 Task 2 skeleton).
- Phase 5 Tasks 1, 2 done and committed.
- Phase 5 Task 3 WIP stashed at `stash@{0}: phase-5-task-3-wip-debug` (357 lines of pipeline construction with debug instrumentation).
- `crates/video-coach-media/src/compose.rs` reset to skeleton.

## Resume procedure

1. `git stash pop` to restore the WIP debug code, OR start fresh from skeleton. Two stashes exist:
   - `stash@{0}: phase-5-task-3-wip-debug-v2` — adds `GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE` to switch to software codecs. Switch confirmed (avdec_h264 in use), but new_sample STILL doesn't fire — so VideoToolbox+runloop is NOT the root cause.
   - `stash@{1}: phase-5-task-3-wip-debug` — earlier WIP state without the rank override.
2. Read the `gstreamer-rs` examples/appsink.rs path — fetched to `/tmp/appsink_example.rs`. The example uses `audiotestsrc → appsink`, callbacks-based, and ALSO uses `examples_common::run` for macOS Cocoa runloop. The Cocoa runloop is needed for VIDEO elements specifically — but disabling VT didn't unblock us, so the issue is something else.
3. **Highest-EV next step**: try `pad probe` on the videoconvert_in src pad to intercept buffers directly. If buffers ARE flowing past videoconvert_in but appsink isn't seeing them, the appsink itself is broken in this pipeline shape. If buffers AREN'T flowing past videoconvert_in, the input chain has a stall before that point.
4. **Alternative architectural path**: split into two pipelines connected by an `mpsc` channel. Pipeline 1: filesrc → decodebin → videoconvert → appsink-with-pull-loop-on-thread. Pipeline 2: appsrc → videoconvert → encoder → muxer → filesink. The producer thread `pull_sample()`s from appsink and `push_buffer()`s to appsrc. Decouples state-change coordination, sidesteps any single-pipeline appsink/appsrc interaction issue.
5. **Pragmatic alternative**: prototype Phase 5 using GStreamer's native `compositor` element instead of wgpu. Gives up the "preview = export" parity benefit but proves the pipeline shape works; can swap in wgpu later when the bridge is understood.

## Time spent in this session

About an hour of investigation across the plan-write, adversarial-review, implementation, and 6+ debugging iterations. Findings worth keeping but the deadlock isn't cracking under rapid iteration.

## UPDATE — session 2 progress (still paused)

After web research + reading the canonical `gstreamer-rs/examples/src/bin/decodebin.rs`, three real fixes landed in `stash@{0}: phase-5-task-3-wip-debug-v3`:

1. **Missing `queue` element between decodebin's dynamic pad and videoconvert.** The canonical example explicitly inserts a queue here ("decodebin → queue → videoconvert → ..."). Without it, decodebin's internal multiqueue stalls waiting for a streaming-thread switch that never happens. Pad probes confirmed: ZERO buffers flow past videoconvert without the queue; ONE buffer flows past it with the queue.

2. **Missing `new_preroll` callback.** AppSink with decoded video DOES preroll the first buffer in PAUSED state. Without a `new_preroll` callback to drain it, the appsink stays in preroll forever and `new_sample` never fires. Adding `.new_preroll(|sink| { let _ = sink.pull_preroll(); Ok(...) })` made the preroll get consumed (logged "new_preroll consumed").

3. **`emit-signals=true` + `set_callbacks` are mutually exclusive.** Removing the `set_property("emit-signals", true)` was clean-up.

**Outstanding issue after all three fixes:** still only ONE buffer reaches appsink's sink pad. After `new_preroll` consumes it, no more buffers flow. The probes on videoconvert sink/src + appsink sink all show #0 only — upstream produces exactly one frame and stops.

**Best remaining hypothesis** — chicken-and-egg between INPUT and OUTPUT chains:

- Input chain produces preroll → appsink consumes it via new_preroll.
- Pipeline state machine wants to transition to PLAYING.
- For PLAYING, ALL sinks (appsink + filesink) must successfully preroll. filesink is downstream of appsrc → encoder. appsrc has never had a buffer pushed, so encoder produces nothing, so filesink hasn't prerolled.
- Pipeline state stuck because filesink hasn't prerolled. With pipeline not in PLAYING, the input side stops producing buffers after the first preroll.

If this hypothesis is right, the fix is structural: split into TWO pipelines connected by an `mpsc` channel. Pipeline A (input): decode → channel.send. Pipeline B (output): channel.recv → encode → file. Each pipeline is self-contained; neither blocks waiting for the other's state. This was the third option in the original investigation notes.

## Stashes

- `stash@{0}: phase-5-task-3-wip-debug-v3` — current best state with queue + new_preroll fixes
- `stash@{1}: phase-5-task-3-wip-debug-v2` — VideoToolbox-disabled variant (subsumed)
- `stash@{2}: phase-5-task-3-wip-debug` — original WIP (subsumed)
