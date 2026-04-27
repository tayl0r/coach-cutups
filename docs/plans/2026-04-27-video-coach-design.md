# Video Coach — Design

A native macOS app for building tagged compilations of clips from full-length soccer match videos. Each clip pairs a source-video segment with the user's webcam, voice commentary, and freehand drawings. Compilations are exported as one HEVC MP4 per selected tag.

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
  - `Core Animation` — `AVVideoCompositionCoreAnimationTool` for stroke + text-bar overlays at export.
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

struct Stroke: Codable {
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
- Output: one `AVCaptureMovieFileOutput` writing `.mov` (camera video + mic audio in one file).
- **Format selection**: explicitly pick a deterministic `AVCaptureDevice.Format` via `device.lockForConfiguration()` then `device.activeFormat = ...`. Prefer 1280×720 @ 30fps when available; otherwise fall back to whatever 720p-or-lower 16:9 30fps the device exposes.
- We do **not** rely on `sessionPreset = .high`. That preset is device-dependent; on Continuity Camera (iPhone-as-webcam) it resolves to 1920×1440 4:3, which would silently break the PiP aspect math.
- The export pipeline reads the actual recorded width/height/frame-rate from each clip's recorded `.mov` at export time, so even if a future user switches cameras between clips the math remains correct.

### Time anchoring

- `t = 0` is anchored at the moment `AVCaptureFileOutputRecordingDelegate.fileOutput(_:didStartRecordingTo:from:)` fires — i.e. when the capture pipeline has actually started writing samples. Camera warm-up between the `startRecording(to:)` call and the first sample is 80–300ms and varies per machine; anchoring at the delegate callback eliminates that drift.
- After `t = 0`, all subsequent event timestamps use `CACurrentMediaTime()` deltas — sub-millisecond accuracy, monotonic, no NTP drift.
- The R / space / arrow keys ignore presses until `didStartRecordingTo` has fired; this prevents a user from issuing skip/pause events before the recording actually begins.
- Verification: a clap-sync clip (visible clap on webcam, audible on mic, with one mid-clip skip) is part of the manual integration checklist (Phase 10) — webcam visual and mic audio must align within one frame in the exported output.

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
- AppKit's coordinate origin is bottom-left. We flip on capture: `ny = 1.0 − pointInView.y / bounds.height`, so the stored normalized origin is top-left — matching how the export compositor will denormalize for `CGContext` drawing. A single helper `denormalize(StrokePoint, into: CGSize) -> CGPoint` is shared between live overlay, Mode C preview, and export.
- Coordinates stored as `(x/width, y/height)`; `lineWidth` is normalized to frame height. The live overlay multiplies by `window.backingScaleFactor` so the stroke appears at the same on-screen thickness as in the export.
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

### The custom compositor

Implements `AVVideoCompositing`:

- **Source registration**: at `renderContextChanged(_:)` we cache the render context (size, pixel format).
- **Per output frame**: AVFoundation calls `startRequest(_ asyncRequest:)` once per output frame at the negotiated `frameDuration`. The request's `compositionTime` tells us where in the output timeline we are. We resolve which `Clip`/`PlaybackSegment` we're in via a precomputed `[CMTimeRange: CompositionEntry]` map (built from `playbackSegments`).
- **Frame production**:
  - For a `.play` segment: pull the source pixel buffer at the corresponding source time from the request's `sourceFrame(byTrackID:)` (the source video track is plumbed in for play segments only — see "Source video plumbing" below). Cache the most recent decoded buffer in case the next segment is a `.freeze`.
  - For a `.freeze` segment: emit the cached pixel buffer directly. PTS comes from `compositionTime`; AVFoundation handles the pacing.
  - **Composite the PiP**: read the webcam track via `sourceFrame(byTrackID:)` (always plumbed, since webcam runs continuously) and draw it scaled to ~22% of output width, bottom-right with a 2.2% margin.
  - **Draw strokes**: walk live strokes for this clip's current `recordTime` (= `compositionTime − clipStart`), build a `CGPath` per live stroke (clipped at the current per-point `t`), stroke into a `CGContext` over the buffer.
  - **Draw text bar**: translucent black rect across the bottom 8% with `"\(i+1)/N, \(clip.name), \(clip.tags.joined(separator: " "))"`.
- All drawing happens into a writable `CVPixelBuffer` obtained from the context's pixel buffer pool. We do **not** use `AVVideoCompositionCoreAnimationTool` at all in the v1 path.

### Source video plumbing

`AVMutableComposition` is still useful for the source video — it gives the compositor access to source frames at the right times. We do this:

- For each clip, walk `playbackSegments(sourceDuration:)`. For each `.play` segment, `insertTimeRange(...)` of the source video track into the composition at the right output offset. For each `.freeze` segment, **don't insert anything** — the compositor will emit cached frames into that range using only `compositionTime` (no source pull needed).
- The compositor is given the precomputed segment map keyed by output `CMTimeRange`, so it knows whether to pull source or emit cached.

### Audio (unchanged in spirit)

`AVMutableAudioMix` over `AVMutableComposition` with two audio tracks: source and mic. Volumes from `preferences.previewSourceVolume` and `preferences.previewCommentaryVolume`. Audio simply continues during `.freeze` segments — wait, actually no: source audio plays only during `.play` segments (it's only inserted there). Mic audio is one continuous insert per clip (it runs through pauses and skips, since the mic is always on). This matches the recording reality.

**AAC priming note**: `AVCaptureMovieFileOutput`-produced `.mov` files include an edit list that compensates for AAC priming samples (~44ms at 48kHz). `AVMutableComposition.insertTimeRange` honors that edit list. To verify, the manual integration checklist includes a clap-sync test (Phase 10).

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
- Per-tag progress bar driven by `AVAssetExportSession.progress` (KVO-observed).
- Tags export sequentially — keeps the UI responsive and avoids contention on the shared VideoToolbox encoder queue.

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
- **Time anchor at `didStartRecordingTo` callback, not `startRecording(to:)` call.** Camera warm-up is 80–300ms and varies per machine; anchoring at the delegate callback eliminates the drift between event log and recorded media.
- **Explicit `device.activeFormat`, not `sessionPreset = .high`.** `.high` resolves device-dependently (1920×1440 4:3 on Continuity Camera, 1280×720 16:9 on built-in FaceTime). Locking to a deterministic format keeps the PiP transform math stable.
- **Plain bookmarks, not security-scoped.** Security-scoped bookmarks are a sandbox feature; for our non-sandboxed hardened-runtime app they have no effect and `startAccessingSecurityScopedResource()` returns `false`. Plain bookmarks still give us relink-on-move.
- **Sequential tag export.** Avoids parallel-progress UI complexity; VideoToolbox saturates on one job anyway, so two in parallel wouldn't finish faster.

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
