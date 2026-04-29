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

1. `git stash pop` to restore the WIP debug code, OR start fresh from skeleton.
2. Read the `gstreamer-rs` examples/appsink.rs path and diff the structure.
3. If still stuck, try the pad probe approach — it removes appsink as a variable.
