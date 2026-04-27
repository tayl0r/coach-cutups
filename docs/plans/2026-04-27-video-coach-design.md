# Video Coach — Design

A native macOS app for building tagged compilations of clips from full-length soccer match videos. Each clip pairs a source-video segment with the user's webcam, voice commentary, and freehand drawings. Compilations are exported as one HEVC `.mov` per selected tag.

## Goals

- Fast scrub-and-mark workflow for chopping a 90-minute match into coachable moments.
- Natural commentary recording: webcam + mic + drawing on top of the source video.
- Per-tag export so each theme (e.g. `attacking-chance`, `transitions`) becomes its own video.
- Native and hardware-accelerated everywhere — no FFmpeg, no GStreamer, no third-party encoders.

## Out of scope (v1)

- Multi-user / cloud sync.
- Color/style picking for drawings (single fixed color, fixed stroke width).
- Re-trim of existing clip in/out points (defer to v2).
- Per-clip volume mixes (volumes are global preferences).
- Sandboxing / Mac App Store distribution (personal-use, hardened-runtime signed for local run only).
- Picture-in-picture device pickers (defaults to built-in camera/mic; selectable in v2).
- Fast-scrubbable proxy transcoding on import (defer; revisit if scanning a long-GOP HEVC match feels laggy in real use).

## User workflows

### Project setup

1. `File > New Project Folder…` → user picks/creates an empty folder. App writes `project.json` and `recordings/` inside.
2. `File > Add Source Video…` → pick 1 or 2 files. App stores security-scoped bookmarks and caches each file's duration.
3. Edit project name in left sidebar (used in export filenames).

### Scanning (Mode A)

- The player presents the source videos as a single virtually-concatenated timeline (`AVMutableComposition`).
- Scrub freely.
- `←` / `a` = −3s, `→` / `d` = +3s, `space` = play/pause.
- Volume slider controls source playback level (you hear it through headphones during recording too).

### Recording a clip (Mode B)

1. With the playhead where you want to begin, press `R` (or click `● Record Clip`).
2. App enters Mode B:
   - `AVPlayer.rate` = 1.0 from current playhead.
   - `AVCaptureSession` starts — webcam + mic both write to one `.mov` under `recordings/`.
   - A small webcam preview appears so you know you're framed.
   - A drawing toolbar appears: `[☑ Auto-clear (5s)] [Clear All]`.
3. Talk over the video. While recording you can:
   - `space` → pause/resume the source video. Your webcam and mic keep rolling so you can talk over a frozen frame.
   - `←` / `a` / `→` / `d` → skip the source ±3s.
   - Click + drag on the player → freehand-draw on the frame (in normalized coords so it survives any export resolution).
   - Toggle auto-clear / hit Clear All anytime.
4. Press `R`, `ESC`, or click `■ Stop` to end the recording.
5. New `Clip` is appended to the project's clip list. Player returns to Mode A; playhead stays where the source ended up.

### Editing metadata (Mode C, sort of)

- Click a clip in the left sidebar.
- Player switches to Clip Preview: composited playback of source-segment + webcam PiP + your commentary + replayed strokes.
- Right inspector exposes `name`, `notes`, `tags`. Tag input is comma-separated free text with autocomplete from `Set(allClips.flatMap(\.tags))`.
- Two extra sliders below the player: **Source Volume** / **Commentary Volume**. They live-update the preview mix and are also what export uses. They're stored as global project preferences, not per-clip.

### Exporting

1. Click `Export…` → modal sheet:
   - Project name (prefilled from folder name, editable).
   - Output folder picker.
   - Tag list with row format `[checkbox] <tag> — <count> clips, <total duration>`.
   - Virtual `all-clips` row at the top.
   - `Select All` / `Select None` buttons.
   - `Resolution` dropdown: Source / 1080p / 720p.
   - `Quality` dropdown: Low / Medium / High → HEVC bitrate.
2. Click `Export Selected Tags` → progress sheet. One `.mov` per checked row, written as `<tag> - <projectName>.mov`.

## Technology stack

- **Language / UI**: Swift, SwiftUI for the app shell, `NSViewRepresentable` for the AVPlayerLayer and the drawing-overlay `NSView`.
- **Minimum target**: latest stable macOS, Apple Silicon only.
- **Video frameworks** (all native, hardware-accelerated):
  - `AVFoundation` — playback, scrubbing, `AVCaptureSession`, `AVMutableComposition`, `AVMutableVideoComposition`, `AVMutableAudioMix`, `AVAssetWriter`.
  - `AVKit` — `AVPlayerView` for the scrubber surface.
  - `VideoToolbox` — H.265 hardware encode/decode (used implicitly through AVFoundation).
  - `Core Media` — `CMTime` for all time arithmetic.
  - `Core Animation` — `CAShapeLayer` for the live drawing overlay and Mode C stroke replay. Export draws strokes + text bar via Core Graphics + CoreText inside the custom compositor; we do **not** use `AVVideoCompositionCoreAnimationTool` (see Decision log).
- **Persistence**: plain `Codable` + JSON. Single `project.json` per project folder. No SQLite for v1.
- **Build**: Xcode project, single macOS app target. No third-party Swift packages required for v1.

Things explicitly *not* used: FFmpeg, GStreamer, Tauri, Electron, Rust, Metal shaders, Core Image filters.

## App structure

Single main window. Three modes share the same player surface.

| Mode | Trigger | Player content | Primary control |
|------|---------|----------------|-----------------|
| A — Scanning | default | source videos as virtual concat | `● Record Clip` |
| B — Recording | press `R` in A | source plays at 1×; webcam preview overlay; drawing overlay | `■ Stop` |
| C — Clip Preview | click a clip in sidebar | composited preview (source + PiP + audio + strokes) | inspector for metadata |

### Window layout

- **Left sidebar (~240px)**: project name (editable), clip list (drag to reorder = compilation order).
- **Center**: AVPlayerView + transport (play/pause, timecode, scrubber, volume; in Mode C also the two mix sliders).
- **Right inspector (~280px)**: clip metadata when a clip is selected; otherwise scanning info / source video list.
- **Toolbar**: New Project, Open Project, Add Source Video, Export…

### Keyboard shortcuts

Active in Modes A and B (and `space`/arrows passive in C):

- `←` / `a` → seek source −3s
- `→` / `d` → seek source +3s
- `space` → play/pause source (in B this freezes the source while webcam/mic continue)
- `R` → start/stop recording
- `esc` → stop recording

## Data model

Project folder layout:

```
2026-04-27-vs-Cobras/
├── project.json
└── recordings/
    └── clip-{uuid}.mov     ← AVCaptureMovieFileOutput (camera + mic in one file)
```

`project.json` (Swift `Codable`):

```swift
struct Project {
    var formatVersion: Int                 // for forward migration
    var name: String                        // used as export filename suffix
    var sourceVideos: [SourceRef]           // 1 or 2, ordered = match order
    var clips: [Clip]
    var preferences: Preferences
}

struct SourceRef {
    var bookmark: Data                      // security-scoped bookmark to the file
    var displayName: String                 // original filename, for UI
    var durationSeconds: Double             // cached for virtual-concat math
}

struct Clip: Identifiable {
    var id: UUID
    var name: String
    var notes: String
    var tags: [String]                      // normalized lowercase, trimmed

    var sourceIndex: Int                    // 0 or 1 (which file)
    var startSourceSeconds: Double          // source-time when Record was pressed
    var recordingDuration: Double           // length of the .mov file

    var recordingFilename: String           // relative path under recordings/
                                            // convention: "clip-<id-uuid>.mov" — derived at clip construction time

    var events: [CommentaryEvent]           // everything that happened during recording
    var sortIndex: Int                      // drag-to-reorder
    var createdAt: Date
}

struct CommentaryEvent: Codable {
    var recordTime: Double                  // seconds into the recording
    var kind: Kind

    enum Kind: Codable {
        case play                           // source resumes/starts at 1×
        case pause                          // source freezes
        case skip(delta: Double)            // ±3 typically; future-proof for any value
        case stroke(Stroke)                 // one finished freehand stroke
        case clearAll                       // wipes all currently-live strokes
    }
}

struct Stroke: Codable, Identifiable {
    var id: UUID                            // assigned at mouseDown; identifies the stroke
                                            // across replay diffs in StrokeReplayLayer
    var color: RGBA                         // fixed for v1; pickable later
    var lineWidth: Double                   // normalized to frame height
    var points: [StrokePoint]
    var autoClearAfterSeconds: Double?      // nil = persist until clearAll or end
}

struct StrokePoint: Codable {
    var x: Double                           // 0...1 of frame width
    var y: Double                           // 0...1 of frame height
    var t: Double                           // seconds since stroke start (stroke-relative)
}

struct Preferences {
    var scanVolume: Double                  // 0...1, used in Modes A and B (you hear the source while recording)
    var previewSourceVolume: Double         // used in Mode C and at export
    var previewCommentaryVolume: Double     // used in Mode C and at export
    var lastExportResolution: Resolution    // .source / .r1080 / .r720
    var lastExportQuality: Quality          // .low / .medium / .high
}
```

### Time encoding

JSON uses `Double` seconds for portability. In-memory the app converts to `CMTime` (`preferredTimescale: 600`, divisible by 24/25/30/60 fps) at boundaries. All composition math uses `CMTime`.

### Stroke timing semantics

The `.stroke(_)` event is emitted at `mouseUp` (end of drawing); its `recordTime` is the END of the stroke, not the start. Per-point `t` is relative to `mouseDown`. So:

- **`firstPointRecordTime` = `event.recordTime − stroke.points.last.t`** (record-time of the first point).
- A point P is **visible at output recordTime `R`** iff `firstPointRecordTime + p.t ≤ R`.
- A stroke is **visible at `R`** iff `firstPointRecordTime ≤ R` AND (`stroke.autoClearAfterSeconds == nil` OR `R < firstPointRecordTime + autoClearAfterSeconds`) AND no `.clearAll` event lies in `(firstPointRecordTime, R)`.
- A `.clearAll` at record-time `C` clears every stroke whose `firstPointRecordTime < C` and whose auto-clear (if set) hasn't already fired by `C`.

The export compositor (Section "The custom compositor") and Mode C `StrokeReplayLayer` both use these formulas — implement them once in `VideoCoachCore` as a pure function `func visibleStrokes(in clip: Clip, atRecordTime: Double) -> [(Stroke, drawnPointCount: Int)]` and call it from both sites.

### Source-time reconstruction

At any `recordTime` `t`, the source-time the user was looking at:

```
sourceTime = clip.startSourceSeconds
recordCursor = 0
rate = 1.0
for event in clip.events where event.recordTime <= t:
    sourceTime += (event.recordTime - recordCursor) * rate
    recordCursor = event.recordTime
    apply event:
        .play   → rate = 1.0
        .pause  → rate = 0.0
        .skip(d)→ sourceTime += d   (clamp to [0, sourceDuration])
        .stroke / .clearAll → no source-time effect
sourceTime += (t - recordCursor) * rate
```

Same loop drives Mode C live preview and the export compositor.

### Source video robustness

`SourceRef.bookmark` is a **plain** (non-security-scoped) bookmark — we run unsandboxed under hardened runtime, so security-scoped bookmarks have no meaningful effect and `startAccessingSecurityScopedResource()` returns `false` anyway. The bookmark is purely a relink-on-move convenience: if the user moves a source video, the bookmark can re-resolve via Spotlight metadata. If resolution fails, the UI surfaces a "Relink…" affordance (Final-Cut-style).

### Tag normalization

On every input: split by comma, trim whitespace per fragment, lowercase per fragment, drop empties. The comma is purely the input separator — fragments are clean by construction.

## Recording pipeline

### Capture session

- Single `AVCaptureSession`, configured once at app launch.
- Inputs: default video device (built-in camera or Continuity Camera if paired) + `default(for: .audio)`.
- Outputs:
  - **`AVCaptureMovieFileOutput`** — writes the `.mov` (camera video + mic audio).
  - **`AVCaptureVideoDataOutput`** companion — exists solely to deliver per-frame `CMSampleBuffer`s so we can capture the first frame's host-time PTS as the recording's `t = 0` anchor. Its sample-buffer delegate runs on a serial queue and discards every buffer except the first one after each `startRecording(to:)` call.
- **Configuration sequence** (the canonical AVCam pattern — order matters):

  1. `session.beginConfiguration()`
  2. `session.sessionPreset = .inputPriority` (so the preset doesn't override our format selection).
  3. Add the video input, audio input, movie output, and data output.
  4. `device.lockForConfiguration()` → set `device.activeFormat`, `activeVideoMinFrameDuration`, `activeVideoMaxFrameDuration` → `unlockForConfiguration()`.
  5. `session.commitConfiguration()`
  6. `session.startRunning()`

  Setting `activeFormat` *before* `addInput` would be silently undone by `addInput` resetting the device to the preset's default (notably 1920×1440 4:3 on Continuity Camera). Setting `activeFormat` *after* `commitConfiguration` would race with the session's startup. The `.inputPriority` preset preserves whatever format we then set on the device.
- **Format choice**: prefer 1280×720 @ 30fps 16:9; otherwise the closest 720p-or-lower 16:9 30fps the device exposes.
- The export pipeline reads the actual recorded width/height/frame-rate from each clip's `.mov` at export time, so even if the user switches cameras between clips the math remains correct.

### Time anchoring

- `t = 0` is anchored at **the host-time PTS of the first `CMSampleBuffer` delivered by the `AVCaptureVideoDataOutput` companion AFTER `fileOutput(_:didStartRecordingTo:from:)` has fired**. Two-stage gating is required: (a) the `t0` continuation is registered on the data-output queue *before* `startRecording(to:)` is called, but (b) `awaitingFirstSample` only flips to `true` inside `didStartRecordingTo`, so any sample buffers in flight from before the file actually opened are correctly ignored. The first buffer that lands after both conditions is, by definition, the first frame in the recorded file.
- `AVCaptureSession.synchronizationClock` is asserted to equal `CMClockGetHostTimeClock()` before recording starts. On the standard built-in / Continuity Camera path this is the case; if a future external capture device produces a different master clock, `startRecording` throws `CaptureError.unsynchronizedClock` rather than silently producing misaligned timestamps. (v2 can convert via `CMSyncConvertTime` instead of refusing.)
- After `t = 0`, subsequent event timestamps are `CACurrentMediaTime() − t0Seconds` — sub-millisecond, monotonic.
- A 2-second timeout protects the UI from hanging forever if the camera fails (e.g. another app holds exclusive access). On timeout, `startRecording` throws `CaptureError.firstSampleTimeout`, the data output is disarmed, and the UI returns to scanning mode.
- The R / space / arrow keys ignore presses until the first sample buffer has been observed (the `RecordingController` doesn't exist yet) AND the controller refuses re-entry (`alreadyRecording`) if a recording is pending.
- Verification: a clap-sync clip (visible clap on webcam + audible on mic + one mid-clip skip) is part of the manual integration checklist (Phase 10). Visual and audio claps must align within one frame.

### During recording

- `AVPlayer.rate = 1.0` from `clip.startSourceSeconds`. Audio routes to default output device (headphones expected).
- Spacebar toggles `rate` 1.0 ↔ 0.0; emits `.play` / `.pause` event with current `t`.
- `←`/`a`/`→`/`d` → `AVPlayer.seek(to:, toleranceBefore: .zero, toleranceAfter: .zero)`; emits `.skip(delta: ±3)`.
- `Clear All` button → emits `.clearAll`.
- Mouse drag on the player overlay → strokes (see below).

### Drawing capture

- An `NSView` overlay (wrapped in `NSViewRepresentable`) sits on top of `AVPlayerLayer`.
- `mouseDown:` opens a new in-memory `Stroke`. `mouseDragged:` may append a new `StrokePoint`. `mouseUp:` finalizes and emits the `.stroke(...)` event.
- **60Hz capture cap, locked**: a new point is committed iff `now − lastPointTime ≥ 1/60s` AND the cursor has moved at least 1 device pixel from the last committed point. Worst-case storage is ~7KB for a 5-second stroke; typical clips total well under 100KB of stroke data.
- AppKit's view origin is bottom-left. We flip on capture: `ny = 1.0 − pointInView.y / bounds.height`, so the stored normalized origin is top-left.
- The two render call sites have **different** coordinate systems and therefore pass different `flipY` values to the shared `Denormalize.point(_:_:into:flipY:)` helper:
  - **Live overlay** (`NSView` with `isFlipped = false`): the view has bottom-left origin. Drawing a top-left-stored stroke point requires `flipY: true` (converts top-left → bottom-left).
  - **Export compositor** (`CGContext` over `CVPixelBuffer`): the compositor applies `cg.translateBy(0, h); cg.scaleBy(1, -1)` BEFORE drawing — this transform makes user-space `(0, 0)` correspond to the top-left of the image (it's the standard CV/CG cookbook fix that lets `cg.draw(img, in:)` render the source CGImage right-side-up). After this transform the user-space is **already** top-left. So drawing a top-left-stored stroke point uses the stored coordinates directly: `flipY: false`.
- **Misuse warning**: passing `flipY: true` in the export compositor double-flips the stroke and renders it upside-down. The Phase 9.0 spike includes a vertically-asymmetric stroke check (one stroke at `y ≈ 0.1`) — if it appears at the bottom of the export, this is the regression to suspect.
- Coordinates stored as `(x/width, y/height)`; `lineWidth` is normalized to frame height (e.g. `0.005`). The live overlay sets `CAShapeLayer.lineWidth = 0.005 × bounds.height` directly — `lineWidth` is in points and Core Animation handles the Retina backing-store upscale automatically. We do **not** multiply by `window.backingScaleFactor` (that would render at 2× thickness on Retina).
- The live overlay renders each stroke as a dedicated `CAShapeLayer` whose `path` extends as new points are committed. This avoids `setNeedsDisplay(bounds)` repainting the entire overlay 60×/sec and lets Core Animation composite on the GPU.

### Stop & finalize

1. `stopRecording()` resolves file finalization (a few hundred ms).
2. Read `recordingDuration` from the resulting `AVAsset`.
3. Construct the new `Clip`, append to project, atomically rewrite `project.json` (write-to-temp + rename).
4. Return to Mode A.

### Crash safety (post-v1 polish)

- Hold partial event logs in a sidecar `.recovering.json` during a recording.
- On launch, detect orphan `.mov` + sidecar and offer "Recover unsaved clip?".
- Implement after the v1 baseline is working.

## Export pipeline

For each checked tag (plus the virtual `all-clips` row if checked) one HEVC `.mov` is produced. Tags export sequentially.

### Architecture: `AVAssetExportSession` + custom `AVVideoCompositing`

We use **`AVAssetExportSession`** with HEVC presets, parameterized by:

- a **custom `AVVideoCompositing` compositor** that owns per-frame video output (handling source frames for `.play` segments, cached frames for `.freeze` segments, the PiP transform, the strokes overlay, and the text bar — all in one place);
- an **`AVMutableComposition`** that carries audio tracks (source + mic) and a "tag track" carrying just enough information for the compositor to know which segment each output frame belongs to;
- an **`AVMutableAudioMix`** carrying the source/commentary volumes.

Why this shape and not the alternatives:

- **vs. `scaleTimeRange` freeze trick (rejected)**: `scaleTimeRange` is a time-mapping edit, not a frame-duplicator. With a 1-frame source range and a long destination range the rendered output is undefined — typical results are the held frame *sometimes*, B-/P-frame garbage when the source frame isn't an IDR (likely on long-GOP match footage), or black at segment boundaries. A custom compositor that explicitly emits the cached pixel buffer per output frame is the only reliable approach.
- **vs. `AVVideoCompositionCoreAnimationTool` for the overlay (rejected as primary)**: the CA tool has known fragility in non-export-session pipelines (`beginTime` must be `AVCoreAnimationBeginTimeAtZero` not `0`; parent layer needs `isGeometryFlipped = true`; behavior with `AVAssetReader`-backed pipelines is undocumented). Drawing the strokes + text bar directly in the custom compositor uses Core Graphics with no surprises and renders perfectly into our output buffers.
- **vs. raw `AVAssetReader`/`AVAssetWriter` pipeline (rejected as primary)**: ~3–5× the code, and we'd be re-implementing what `AVAssetExportSession` already gives us (progress, lifecycle, queue management). Reserve as the fallback if HEVC bitrate/profile control through the export session proves insufficient.

### Track ID strategy

`AVMutableComposition.addMutableTrack` returns the assigned `CMPersistentTrackID` after the call, so we never use `kCMPersistentTrackID_Invalid`. We instead pass explicit IDs and verify they came back unchanged:

- **Source video** track ID: a stable `1` (one shared track; segments per clip).
- **Source audio** track ID: a stable `2`.
- **Webcam video** track IDs: `1000 + clipIndex` per clip (one webcam track per clip insertion — easier than re-using one shared track because the webcam content varies per clip and `requiredSourceTrackIDs` is per-instruction).
- **Mic audio** track IDs: `2000 + clipIndex`.

The compositor receives per-instruction metadata (clip index, segment list, stroke list, source/webcam track IDs, text bar string) via a **subclass** of `AVMutableVideoCompositionInstruction`:

```swift
final class CompilationInstruction: AVMutableVideoCompositionInstruction {
    var clipIndex: Int = 0
    var indexInOutput: Int = 0
    var totalClips: Int = 0
    var sourceTrackID: CMPersistentTrackID = 1
    var webcamTrackID: CMPersistentTrackID = 1000
    var clipCompositionStart: CMTime = .zero
    var segments: [PlaybackSegment] = []
    var strokes: [Stroke] = []
    var textBarLine: String = ""
}
```

**Critical setup per instruction**: every instruction MUST have its `timeRange` set to the clip's compositional range, otherwise AVFoundation rejects the composition (default value is `kCMTimeRangeInvalid`):

```swift
let inst = CompilationInstruction()
inst.timeRange = CMTimeRange(start: clipCompositionStart, duration: clipDuration)
inst.requiredSourceTrackIDs = [
    NSNumber(value: inst.sourceTrackID),
    NSNumber(value: inst.webcamTrackID)
]
```

`requiredSourceTrackIDs` is `[NSValue]`-typed (`NSNumber` is the conventional boxing for `CMPersistentTrackID`) — passing raw `Int32`s won't compile.

**Source track without coverage during freeze segments**: a clip's source-video track has gaps inside the instruction's range (the freeze segments). Listing the source track in `requiredSourceTrackIDs` does NOT prevent the compositor from being called over those ranges — AVFoundation provides whatever segments exist and `request.sourceFrame(byTrackID: sourceTrackID)` simply returns nil during a freeze. The compositor's `lastSourceFrame` cache fills in.

AVFoundation passes our subclass through unchanged. The compositor casts `request.videoCompositionInstruction as? CompilationInstruction` and `fatalError`s on cast failure (the cast can only fail if a future macOS regresses subclass-passthrough — better to crash visibly than to silently render black).

### The custom compositor

Implements `AVVideoCompositing`:

- **Source registration**: at `renderContextChanged(_:)` we cache the render context (size, pixel format, pool).
- **Per output frame**: AVFoundation calls `startRequest(_ asyncRequest:)` once per output frame. We:
  1. Resolve the `CompilationInstruction` and the `compositionTime`.
  2. Compute `recordTime = compositionTime − clipCompositionStart`.
  3. **At every clip boundary, reset `lastSourceFrame = nil`** so a leading `.freeze` in clip N never displays clip N−1's last source frame.
  4. Decide the **base buffer**:
     - `.play` segment → call `request.sourceFrame(byTrackID: instruction.sourceTrackID)`. Cache it in `lastSourceFrame`.
     - `.freeze` segment → use `lastSourceFrame` if set; otherwise emit a black frame (clip starts paused — rare).
  5. Get an output `CVPixelBuffer` from `request.renderContext.newPixelBuffer()`.
  6. Wrap output buffer in a `CGContext`, flip Y to top-left origin (CG default for CVPixelBuffer is bottom-left).
  7. Draw the base buffer full-frame.
  8. Pull the webcam frame via `request.sourceFrame(byTrackID: instruction.webcamTrackID)`, scale to 22% of output width, place bottom-right with `0.022 × outputHeight` margin.
  9. **Draw strokes**: call `visibleStrokes(in: clip, atRecordTime: recordTime)` (the shared helper from plan Task 3.3), then for each returned `VisibleStroke` build a `CGPath` from `stroke.points` up to `drawnPointCount`, and stroke into the CG context at `vs.stroke.lineWidth × outputHeight`. The helper handles auto-clear, `.clearAll`, and partial-draw point counts uniformly.
  10. **Draw text bar via CoreText**: translucent black rect across the bottom 8%; `CTFramesetterCreateWithAttributedString` over `NSAttributedString("\(i+1)/N, \(name), \(tags joined by space)")` for proper emoji + RTL + CJK shaping. Plain `CGContext.draw(text:)` would mis-render emoji.
  11. `request.finish(withComposedVideoFrame: outputBuffer)`.

The compositor is the single source of truth for the export's per-frame visual. We do **not** use `AVVideoCompositionCoreAnimationTool` at all.

### Source video plumbing

`AVMutableComposition` carries the source frames so the compositor can pull them via `sourceFrame(byTrackID:)`:

- For each clip, walk `playbackSegments(sourceDuration:)`. For each `.play` segment, `insertTimeRange(...)` of the source video track into the composition at the right output offset. For each `.freeze` segment, **don't insert anything** — the compositor emits cached frames into that range from `lastSourceFrame`.
- Each `CompilationInstruction` is built with `requiredSourceTrackIDs` listing the source track ID (covering only `.play` ranges) and the per-clip webcam track ID (always covering the whole clip range).
- AVFoundation calls our compositor for **every** output frame — including ranges with no source coverage — as long as we add an instruction for that range. So we add one instruction per clip covering its full output range; the compositor handles `.freeze` from cache when the source pull returns nil.

### Audio

`AVMutableAudioMix` over `AVMutableComposition`:

- **Source audio**: inserted into the source-audio track (ID `2`) only during `.play` segments — gaps during `.freeze` ranges (intentional silence from the source side).
- **Mic audio**: inserted continuously per clip into the per-clip mic track (ID `2000 + i`) — the mic runs through pauses and skips since the user is always talking.
- Volumes from `preferences.previewSourceVolume` and `preferences.previewCommentaryVolume`.
- **Boundary ramps**: at every transition between source-audio segments (i.e. each `.play → .freeze` and `.freeze → .play` boundary, plus clip starts and ends) we apply a **5ms volume ramp** via `AVMutableAudioMixInputParameters.setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`. This prevents AAC click artifacts at internal cut boundaries (priming samples don't exist for interior slices, so a hard cut at non-zero amplitude clicks). **Clamp the ramp start at zero** — if a boundary is within 5ms of zero (clip starts with a near-instant freeze), the unclamped start would go negative, which AVFoundation handles inconsistently across macOS versions. If the clamped duration is non-positive, skip the ramp.

**AAC priming note**: `AVCaptureMovieFileOutput`-produced `.mov` files include an edit list compensating for the file-start AAC priming. `AVMutableComposition.insertTimeRange` honors the edit list at the file's start. The boundary-ramp strategy above handles the *interior* slicing concern, which is where priming compensation does not apply. The clap-sync manual test (Phase 10) verifies start-of-clip alignment; an additional "two pause boundaries inside one clip" check verifies no clicks at internal seams.

### Encode

`AVAssetExportSession` with `presetName = AVAssetExportPresetHEVCHighestQuality` (or `.HEVC1920x1080` / `.HEVC3840x2160` if we want to clamp dimensions). For finer bitrate control we use `AVAssetExportSession.outputFileType = .mov` and `videoComposition = ourCustomComposition` and `audioMix = ourMix`.

If the export-session bitrate is too high or too low for our **Quality** dropdown, the **fallback** is a raw `AVAssetReader` → `AVAssetWriter` pipeline using the same custom compositor's output as the writer's input. We pick the right path based on a **Phase 9 spike** (Plan Task 9.0).

Bitrate target table (we'll match these via export-session preset selection or via writer settings if we drop down):

| Quality | 1080p | 720p |
|---------|-------|------|
| Low     | 6 Mbps | 3 Mbps |
| Medium  | 12 Mbps | 6 Mbps |
| High    | 24 Mbps | 12 Mbps |

Audio output: AAC, 192 kbps, stereo, 48 kHz.

Container: **`.mov`** (HEVC in `.mov` is Apple's documented preference and plays in QuickTime, Safari, VLC, iOS without the `hvc1`/`hev1` sample-entry confusion that `.mp4` HEVC sometimes triggers).

### Filenames + progress

- Output: `<outputFolder>/<tag> - <projectName>.mov`. The virtual tag becomes `all-clips - <projectName>.mov`.
- Per-tag progress driven by polling `AVAssetExportSession.progress` (a `Float`, exposed via `AsyncStream<Float>`) at 5Hz on a `Task`. KVO compliance for `progress` has historically been inconsistent across macOS versions; polling is reliable.
- Tags export sequentially — keeps the UI responsive and avoids contention on the shared VideoToolbox encoder queue.

## Mode C clip preview

Preview must run at native 30fps, which the export compositor (Core Graphics + CoreText per frame) cannot sustain in real-time. Mode C uses a **layered preview** in the AppKit view hierarchy. It is intentionally not pixel-identical to the export — stroke widths and text rendering may differ slightly — but it plays at full rate.

### Layer hierarchy (top to bottom)

1. **Text bar** — a plain `NSTextField` (or SwiftUI `Text`) pinned to the bottom 8% of the player container. Updates per clip but is otherwise static.
2. **Stroke replay** — a `CALayer` overlay containing one `CAShapeLayer` per "currently live" stroke. A periodic time observer on the player (60Hz via `AVPlayer.addPeriodicTimeObserver(forInterval:queue:using:)`) walks the clip's events at the current `recordTime`, adds/removes child layers as strokes appear and clear, and updates each layer's `path` for in-progress portions (matching the original drawing tempo).
3. **AVPlayerLayer** — backing an `AVPlayer` that plays an `AVPlayerItem` of an `AVMutableComposition` carrying:
   - The source video track (with `.play` segments only)
   - The webcam track (continuous)
   - Source audio (`.play` segments only) + mic audio (continuous), with the same boundary ramps as the export.
   - An `AVMutableVideoComposition` that sets up:
     - A **lightweight preview compositor** (separate class, much smaller than the export's): handles `.freeze` segments by re-emitting the cached pixel buffer. Does NOT draw strokes, text, or PiP.
     - Built-in `AVMutableVideoCompositionLayerInstructions` for the PiP transform — geometry handled by AVFoundation's standard layer compositing, no per-frame CG code for the PiP.
   - An `AVMutableAudioMix` reflecting the source/commentary volume sliders.

### Volume slider live update

When either volume slider changes, build a fresh `AVMutableAudioMix` and assign to `player.currentItem?.audioMix`. Mutating the parameters of an existing `audioMix` on a playing item does not take effect; reassignment does. Debounce slider changes at ~60Hz to avoid thrash.

### Why this preview is NOT pixel-identical to export

- **Strokes**: rendered as `CAShapeLayer`s at view-coordinate scale; the export draws via Core Graphics into the actual output buffer. Anti-aliasing and sub-pixel positioning differ.
- **Text bar**: rendered by AppKit's text system in the view hierarchy; the export renders via CoreText into the buffer. Font metrics may differ by 1px.
- **PiP**: rendered by AVFoundation's built-in layer instruction; the export composites in CG. Result is visually equivalent but path-different.

This trade-off was made deliberately: the preview's job is "show me what this clip will be," not "show me an exact pixel preview." For the latter, the user exports and watches the result.

## Decision log

The non-obvious calls made during design, with their rationale.

- **Swift + AVFoundation, not Rust + FFmpeg.** AVFoundation gives hardware H.264/H.265 encode + decode, capture, composition, and per-frame compositors out of the box. A Rust path would mean wrapping FFmpeg or GStreamer plus calling AVFoundation through objc bridges for capture — roughly 3–5× more code, with sharper edges. Rust remains the right call when AVFoundation can't do something; for v1 it can do everything.
- **Non-destructive clip storage.** Clips reference source-video time ranges and event logs, not pre-rendered video files. Clips stay editable, recording stop is instant, disk usage during a session stays low. The compositional render only happens at export time.
- **Project = a folder, not a library.** Transparent in Finder, easy to back up / move / Dropbox / share. Project file format is plain JSON, debuggable and diffable.
- **Single `.mov` per recording (camera + mic together).** AVCaptureMovieFileOutput natively writes both tracks; AVAssetReader extracts each track at export. Avoids syncing two files.
- **Unified `CommentaryEvent` log.** One event stream replaces what could have been three separate lists (skip events, pause events, stroke events). Drives both Mode C live preview and export compositing through the same fold.
- **60Hz capture cap on stroke points.** Plenty for visually smooth lines on any display; halves storage vs 120Hz; well above the rate of perceivable hesitation. ~7KB max for a 5-second stroke.
- **Vector strokes, not rasterized canvases.** Resolution-independent — the same data renders crisply at 720p preview and 1080p export. Rendered as `CGPath`s clipped at each point's `t`, preserving natural drawing tempo.
- **Custom `AVVideoCompositing` compositor for both freeze frames and overlays.** Avoids the unreliable `AVMutableComposition.scaleTimeRange` freeze trick (time-mapping edit, not frame duplication — produces black/garbage on long-GOP HEVC) and avoids `AVVideoCompositionCoreAnimationTool`'s known fragility (`AVCoreAnimationBeginTimeAtZero` requirement, `isGeometryFlipped` requirement, undocumented behavior with reader-backed pipelines). Drawing strokes + text bar in a Core Graphics pass over each output buffer is simpler and predictable.
- **`AVAssetExportSession` first, `AVAssetReader`/`AVAssetWriter` only as fallback.** ExportSession + custom compositor + custom audio mix covers the bitrate range we need (6–24 Mbps HEVC) without the lifecycle complexity of a hand-driven reader/writer pipeline. Phase 9 includes a spike to confirm before committing.
- **Volume sliders are global, not per-clip.** Tracks user intent — they tune source vs commentary balance once and want it applied across the project. Per-clip overrides can be added later if needed.
- **HEVC in `.mov`, not `.mp4`.** Apple's documented recommendation. Avoids the `hvc1`/`hev1` sample-entry compatibility quirks that `.mp4` HEVC occasionally triggers. Plays everywhere we care about (QuickTime, Safari, VLC, iOS).
- **Time anchor at the first `AVCaptureVideoDataOutput` sample buffer's PTS, not at the `didStartRecordingTo` callback.** The delegate callback fires when the file handle is opened (50–150ms before the first sample is actually captured); the data output's first sample buffer is, by definition, the first frame in the recorded file. Sub-frame accurate anchoring with no retroactive offset math.
- **AVCaptureVideoDataOutput companion alongside AVCaptureMovieFileOutput.** Costs essentially nothing — its sample buffer delegate runs on a background queue and discards every buffer except the first one per recording. Worth it for the time anchor.
- **Explicit `device.activeFormat`, not `sessionPreset = .high`.** `.high` resolves device-dependently (1920×1440 4:3 on Continuity Camera, 1280×720 16:9 on built-in FaceTime). Locking to a deterministic format keeps the PiP transform math stable.
- **Plain bookmarks, not security-scoped.** Security-scoped bookmarks are a sandbox feature; for our non-sandboxed hardened-runtime app they have no effect and `startAccessingSecurityScopedResource()` returns `false`. Plain bookmarks still give us relink-on-move.
- **Sequential tag export.** Avoids parallel-progress UI complexity; VideoToolbox saturates on one job anyway, so two in parallel wouldn't finish faster.
- **Mode C clip preview is layered (separate `AVPlayerLayer` + `CAShapeLayer` overlay + text-bar view) rather than reusing the export's full compositor.** Per-frame Core Graphics + CoreText drawing inside an `AVPlayer` compositor would not sustain 30fps live playback. The preview compositor handles only freeze frames; strokes + text bar are AppKit overlays. Trade-off: preview is not pixel-identical to export, but it plays in real time at any clip duration.
- **Track IDs explicit, per-instruction context via `CompilationInstruction` subclass.** `kCMPersistentTrackID_Invalid` returns AVFoundation-assigned IDs that aren't known to the compositor. Subclassing `AVMutableVideoCompositionInstruction` lets us thread per-clip metadata (segment list, strokes, track IDs, text bar string) through AVFoundation unchanged — the standard pattern for custom compositors.
- **5ms volume ramps at every internal source-audio segment boundary.** AAC priming compensation only applies at file start; interior slices created by `insertTimeRange` produce hard cuts that click. A short fade-in/out via `setVolumeRamp` eliminates the artifacts.
- **Text bar rendered via CoreText (`CTFramesetter`).** Tags + clip names may contain emoji (⚽ is plausible for soccer), CJK, or RTL text. CoreText handles glyph shaping; primitive `CGContext.draw(text:)` would mis-render.

## Spike outcomes

(populated as Phase 9.0 runs)

- **AVAssetExportSession + custom compositor + custom audioMix + HEVC preset combination**: ☐ verified working / ☐ falling back to AVAssetReader/Writer (Task 9.6).

## Open items (post-v1)

- Re-trim a clip's start/end after creation.
- Color/width pickers for drawings.
- Camera + mic device selection in Preferences.
- Per-clip volume overrides.
- Bookmark relink UI for moved source videos.
- Crash-safe partial-recording recovery (sidecar event log written during recording).
- Configurable PiP corner / size.
- Tag rename / merge across all clips at once.
- Export preview thumbnail + duration estimate before running encode.
- Delete-clip command (Cmd-Delete in the sidebar).
- Fast-scrubbable proxy transcoding on import (revisit if scanning long-GOP HEVC matches feels laggy).
- Move clip stroke rendering to per-stroke `CAShapeLayer` in Mode C preview (it's already that way in the recording overlay; verify preview matches).
- Sidecar `clip-{uuid}.events.json` per clip if `project.json` size becomes a concern (>1MB).
- Async load modernization on any remaining synchronous `AVAsset.duration` accessors.
