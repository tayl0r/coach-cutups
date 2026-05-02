# Video Zoom + Pan Design

**Status:** approved 2026-05-01. Implementation plan to follow in a sibling document.

**Goal:** Let the user zoom and pan into the source video while scanning, while recording clips, and at export. During recording, every zoom/pan adjustment is captured as a keyframe and replayed during preview and export, so the exported video shows the same zoom-and-follow behavior the user authored live.

**Branch:** `feat/video-zoom` (off `feat/source-playback-metal-direct` at `bf723ac`).

---

## D1 — Data model

A new `Zoom` struct in `VideoCoachCore`:

```swift
public struct Zoom: Codable, Hashable, Sendable {
    public var scale: Double      // 1.0 = full frame; floor 1.0; cap 10.0
    public var panX: Double       // fraction of source width; range varies with scale
    public var panY: Double       // fraction of source height; range varies with scale
    public static let identity = Zoom(scale: 1.0, panX: 0, panY: 0)
}
```

Captured during recording as a new variant of `CommentaryEvent.Kind`:

```swift
public enum Kind: Codable, Hashable, Sendable {
    case play
    case pause
    case skip(delta: Double)
    case stroke(Stroke)
    case clearAll
    case zoom(Zoom)        // NEW
}
```

This reuses the existing event-replay infrastructure: `recordTime`-stamped, codable, persists with the project, replays during preview and export.

**Ranges and clamping:**
- `scale ∈ [1.0, 10.0]` — hard floor at full-frame, soft cap at 10×.
- `panX, panY ∈ [-(scale - 1) / (2 · scale), +(scale - 1) / (2 · scale)]` — clamped so the visible viewport never extends beyond the source frame.
- At `scale == 1.0`, both pan components are forced to 0 (panning is meaningless at full-frame).

**State ownership during scanning (no recording):** live current state lives on `Workspace` as `currentZoom: Zoom = .identity`. Observed by `MPVRenderingNSView`, which feeds it to mpv via the runtime properties `video-zoom`, `video-pan-x`, `video-pan-y`. Ephemeral within a session; not persisted to the project; reset to `.identity` on workspace switch.

**State ownership during recording:** `RecordingController` snapshots `Workspace.currentZoom` at `recordTime=0` (the inherit-on-record behavior — see D5). Subsequent zoom adjustments append `.zoom(...)` events. On stop, the clip is persisted with all events.

---

## D2 — Input handling

`MPVRenderingNSView` gains four event handlers; routing is asymmetric per input device (Option Y from the brainstorm):

| Input | Gesture | Behavior |
|---|---|---|
| Mouse | scroll wheel rotation | zoom toward cursor (cursor-pivoted) |
| Mouse | left-click + drag (when zoomed in) | pan |
| Mouse | left-click without drag | grab first-responder (existing behavior) |
| Trackpad | pinch (`magnify(with:)`) | zoom toward gesture location |
| Trackpad | two-finger swipe (`scrollWheel` with precise deltas) | pan |

Routing logic inside `scrollWheel(with:)`:
- `event.hasPreciseScrollingDeltas == false` → coarse mouse wheel → zoom (`Δscale = scale · 0.1 · sign(deltaY)`).
- `event.hasPreciseScrollingDeltas == true` → trackpad two-finger swipe → pan (`panX += -deltaX / (drawableWidth · scale)`, same for Y).

Click-vs-drag threshold for `mouseDown` / `mouseDragged` / `mouseUp`:
- `mouseDown` records anchor location and current zoom; marks "drag candidate."
- `mouseDragged` with `hypot(dx, dy) > 4 px` → switch to "dragging-pan" mode.
- `mouseUp` after a confirmed drag → no first-responder grab.
- `mouseUp` without crossing the threshold → first-responder grab (existing behavior).
- When `scale == 1.0`, drag is silently a no-op.

**Cursor-pivot zoom math:** when the user scrolls/pinches at view-relative position `(cx, cy)` (normalized 0..1), the source point that was under the cursor before the zoom must remain under the cursor after. Standard zoom-to-cursor derivation; explicit formula in the implementation plan.

After every input event, the resolved `Zoom` is clamped per D1's ranges and pushed onto `Workspace.currentZoom`. This propagates to mpv via three property writes (`video-zoom`, `video-pan-x`, `video-pan-y`). No throttling at the playback layer — mpv handles its own present timing.

---

## D3 — Recording capture + preview replay

**Capture during recording:**

`RecordingController` observes `Workspace.currentZoom` and emits keyframes into the in-progress clip:

```swift
private var lastCaptured: Zoom = .identity
private var lastCaptureTime: TimeInterval = -.infinity

func onZoomChanged(_ new: Zoom) {
    guard isRecording else { return }
    let now = clipClock.elapsed
    // If gap > 100ms since last keyframe, anchor the previous value at
    // (now - 1ms) so the next lerp produces a snap rather than drifting
    // backward across a quiet period.
    if now - lastCaptureTime > 0.1 {
        events.append(.init(recordTime: now - 0.001, kind: .zoom(lastCaptured)))
    }
    events.append(.init(recordTime: now, kind: .zoom(new)))
    lastCaptured = new
    lastCaptureTime = now
}
```

The first keyframe at `recordTime=0` is the **inherit snapshot** — emitted automatically when recording starts because the start-of-recording fires a synthetic "current value" event from `Workspace.currentZoom`.

**No throttle at capture time.** Continuous gestures fire ~60–120 events/sec; storage budget for a 30s clip is ~144KB worst case. Acceptable.

**Lerp at lookup time:**

```swift
extension Clip {
    /// Return the active Zoom at recordTime t, linearly interpolating between
    /// adjacent keyframes. Empty/before-first → identity; after-last → last
    /// value.
    public func zoomAt(recordTime t: Double) -> Zoom { ... }
}
```

Continuous pinch over 1 second → 60+ keyframes → smooth lerp at any output frame rate.

Discrete events naturally produce two keyframes 1ms apart (the anchor pattern), so lerp produces an effectively-instant transition — feels like a snap.

**Preview replay (Mode C — `PreviewCompositor`):** the existing per-frame compositor already iterates events for stroke overlays. It gains `let zoom = clip.zoomAt(recordTime: presentationTime)` and applies the corresponding affine transform to the source frame before drawing strokes on top.

**Scrubbing the preview** works by construction — `zoomAt(recordTime:)` is a stateless lookup, so jumping to any time replays the correct zoom.

---

## D4 — Export integration

The existing `CompilationCompositor` (`apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`) is a custom `AVVideoCompositing` already pulling per-frame source pixels and iterating events for stroke overlays.

**Per-frame addition inside `startRequest(_:)`:**
1. Get the source frame (unchanged).
2. **NEW:** `let zoom = clip.zoomAt(recordTime: recordTime)`.
3. Compute the affine transform (D5 below) from `zoom`, `sourceSize`, `outputSize`.
4. Draw the source frame with that transform into the destination CGContext.
5. Existing stroke / text-bar overlays draw on top — unchanged.

`CompilationInstruction` (the `AVMutableVideoCompositionInstruction` subclass) already carries the events needed to compute zoom-at-time; no new payload required.

`PreviewCompositor` shares the same affine-transform helper.

**Affine transform** (`Zoom.transform(sourceSize:destSize:)` extension method):

```swift
public func transform(sourceSize: CGSize, destSize: CGSize) -> CGAffineTransform {
    let baseScale = min(destSize.width / sourceSize.width,
                        destSize.height / sourceSize.height)  // letterbox fit
    let s = scale * baseScale
    let dx = (destSize.width - sourceSize.width * s) / 2
    let dy = (destSize.height - sourceSize.height * s) / 2
    let tx = dx - panX * sourceSize.width * s
    let ty = dy - panY * sourceSize.height * s
    return CGAffineTransform(scaleX: s, y: s).translatedBy(x: tx / s, y: ty / s)
}
```

At identity (`scale=1, panX=0, panY=0`), this produces today's letterbox-fit transform — bit-identical to current export output.

**No changes needed to `CompilationExporter` or `CompilationPlan`.** Zoom rides along inside `Clip.events`.

**Edge cases:**
- The PiP webcam track does NOT zoom (it's its own track, composited at a corner). Confirmed by D1's data model: `Zoom` modifies the source viewport only.
- Letterbox/pillarbox handling preserved: at `scale=1`, output is identical to today.

---

## D5 — Inherit-on-record behavior

When the user starts recording while zoomed, the new clip inherits the current `Workspace.currentZoom` as its first keyframe at `recordTime=0`:

```swift
// RecordingController.startRecording(...)
events.append(.init(
    recordTime: 0,
    kind: .zoom(workspace.currentZoom)
))
```

This means the export will start at the inherited zoom, which is what the user wants when their workflow is "scrub → spot a moment → zoom in to the action → record while narrating."

If the user wants the recording to start at full frame, they zoom out (or hit ⌘0 — see D6) before pressing record.

---

## D6 — Reset shortcut

A keyboard shortcut for "reset zoom" — `⌘0`. Wired through `KeyCommandView` (the existing key-handling overlay): on `⌘0`, set `Workspace.currentZoom = .identity`, which triggers the same observation chain as a scroll/pinch event. During recording, this also lands as a keyframe (so the exported video resets at the same time).

---

## D7 — Testing strategy

Unit tests in `VideoCoachCoreTests`:
- `ZoomTests` — identity, clamping, cursor-pivot math (load-bearing).
- `ClipZoomLookupTests` — empty/single/multi-keyframe lerp, anchor-pattern snap, edge times.
- `RecordingZoomCaptureTests` — inherit-at-recordTime-0, continuous-gesture density, discrete-change anchoring.

Integration tests in `VideoCoachCoreTests` (export pipeline):
- `CompilationCompositorZoomTests` — synthetic-source export with zoom keyframes; pixel-sampling assertions via the existing `SyntheticAsset.swift` + `PixelSampling.swift` helpers.

XCUITest:
- `MPVZoomPlaybackTests/testScrollZoomsBringUpWindow` — synthesize a `scrollWheel` event via `NSEvent.event(...).cgEvent?.post(...)`, capture screenshot, assert visible content shifted.
- Trackpad pinch and two-finger swipe are not synthesizable from XCUITest; verified manually.

---

## D8 — Things this design does NOT cover

- **Tweening curves other than linear** — easing (ease-in-out, etc.) for zoom transitions could be a follow-up. Linear is the right v1 default and matches what users author by holding a steady pinch.
- **Per-keyframe interpolation hint** — the data model has no per-event `easing` field. Snap behavior is implemented via the anchor pattern (two keyframes 1ms apart), not a hint flag.
- **Zoom on the PiP webcam track.** Out of scope; webcam stays unzoomed at its corner.
- **Reset-on-workspace-switch persistence policy** — `Workspace.currentZoom` is in-memory; switching projects resets it. If users want last-zoom-state to persist across sessions, that's a follow-up via `UserDefaults` but probably not desirable (transient navigation aid).

---

## D9 — Open questions deferred to implementation

- The exact scroll-wheel `Δscale` step size and pinch sensitivity multiplier — tune empirically during Phase 1 of the implementation plan.
- Whether to emit a single combined `mpv_command(...)` with all three properties or three separate `mpv_set_property` calls — measure, default to the latter unless visible flicker.
- mpv's `video-zoom` is logarithmic (`zoom = 2 ** value`); our `Zoom.scale` is linear. Conversion: `mpvZoom = log2(scale)`. Range `[0, log2(10)] ≈ [0, 3.32]`.
