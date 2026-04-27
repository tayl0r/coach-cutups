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
- Sandboxing / Mac App Store distribution (personal-use, signed for local run only).
- Picture-in-picture device pickers (defaults to built-in camera/mic; selectable in v2).

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
2. Click `Export Selected Tags` → progress sheet. One MP4 per checked row, written as `<tag> - <projectName>.mp4`.

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

`SourceRef.bookmark` is a security-scoped bookmark resolved on project open. If a bookmark fails to resolve, the UI surfaces a "Relink…" affordance (Final-Cut-style). This pays off if the user moves source videos between drives.

### Tag normalization

On every input: trim whitespace, lowercase. The comma is reserved as the input separator and stripped if the user types it inside a tag.

## Recording pipeline

### Capture session

- Single `AVCaptureSession`, configured once at app launch.
- Inputs: `.builtInWideAngleCamera`, `default(for: .audio)`.
- Output: one `AVCaptureMovieFileOutput` writing `.mov` (camera video + mic audio in one file).
- Preset: `.high` (1280×720 / 30fps) — small, low CPU, plenty for a corner PiP.

### Time anchoring

- `t = 0` = the moment `startRecording(to:recordingDelegate:)` is called.
- All subsequent event timestamps use `CACurrentMediaTime()` deltas — sub-millisecond, monotonic, no NTP drift.
- Startup latency between the call and the first sample is sub-frame and does not accumulate. Drift between event log and the recorded `.mov` at export is bounded to one frame.

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
- Coordinates stored as `(x/width, y/height)`; line width normalized to frame height. Strokes scale correctly at any export resolution.
- During the drag the partial stroke also renders live in the overlay so the user sees the line.

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

For each checked tag (plus the virtual `all-clips` row if checked) one HEVC MP4 is produced. Tags export sequentially.

### Per-tag composition build

```
let clipsForTag = project.clips
    .filter { $0.tags.contains(tag) }            // or all clips for "all-clips"
    .sorted(by: \.sortIndex)

let comp = AVMutableComposition()
let videoTrackSrc = comp.addMutableTrack(type: .video)   // source video segments
let videoTrackPiP = comp.addMutableTrack(type: .video)   // webcam PiP
let audioTrackSrc = comp.addMutableTrack(type: .audio)   // source video audio
let audioTrackMic = comp.addMutableTrack(type: .audio)   // commentary

var cursor = CMTime.zero        // running offset in the output composition

for (i, clip) in clipsForTag.enumerated() {
    let recAsset = AVAsset(url: project.recordingsDir/clip.recordingFilename)
    let srcAsset = AVAsset(url: project.sourceVideos[clip.sourceIndex].resolvedURL)

    // (1) Source video, walking the event log to build segments
    var sourceCursor = clip.startSourceSeconds
    var rate         = 1.0
    var lastEventT   = 0.0

    func emitSegment(fromRecord t0: Double, toRecord t1: Double, atRate r: Double) {
        let recordSpan = t1 - t0
        if recordSpan <= 0 { return }
        let outStart = cursor + sec(t0)
        if r == 1.0 {
            let srcRange = CMTimeRange(start: sec(sourceCursor), duration: sec(recordSpan))
            try videoTrackSrc.insertTimeRange(srcRange, of: srcAsset.videoTrack, at: outStart)
            try audioTrackSrc.insertTimeRange(srcRange, of: srcAsset.audioTrack, at: outStart)
            sourceCursor += recordSpan
        } else { // freeze: take a 1-frame slice and time-stretch it across the span
            let frameDur = CMTime(value: 1, timescale: 30)
            let frame = CMTimeRange(start: sec(sourceCursor), duration: frameDur)
            try videoTrackSrc.insertTimeRange(frame, of: srcAsset.videoTrack, at: outStart)
            videoTrackSrc.scaleTimeRange(
                CMTimeRange(start: outStart, duration: frameDur),
                toDuration: sec(recordSpan))
            // No audio during freeze — silence is the right behavior here.
        }
    }

    for ev in clip.events {
        emitSegment(fromRecord: lastEventT, toRecord: ev.recordTime, atRate: rate)
        switch ev.kind {
            case .play:           rate = 1.0
            case .pause:          rate = 0.0
            case .skip(let d):    sourceCursor = clamp(sourceCursor + d, 0, srcDur)
            case .stroke, .clearAll: break
        }
        lastEventT = ev.recordTime
    }
    emitSegment(fromRecord: lastEventT, toRecord: clip.recordingDuration, atRate: rate)

    // (2) Webcam PiP — recording's tracks placed into output at this clip's offset
    let recRange = CMTimeRange(start: .zero, duration: sec(clip.recordingDuration))
    try videoTrackPiP.insertTimeRange(recRange, of: recAsset.videoTrack, at: cursor)
    try audioTrackMic.insertTimeRange(recRange, of: recAsset.audioTrack, at: cursor)

    cursor = cursor + sec(clip.recordingDuration)
}
```

### Video composition

- `AVMutableVideoComposition.renderSize` from the **Resolution** dropdown.
- `frameDuration` = source frame rate (read from `srcAsset.tracks(.video).first.nominalFrameRate`).
- One `AVMutableVideoCompositionInstruction` per clip's compositional range:
  - Layer 0 (`videoTrackSrc`): identity transform (with letterbox if AR mismatch).
  - Layer 1 (`videoTrackPiP`): `CGAffineTransform` scaling to ~22% of frame width and translating to the bottom-right corner with a margin of `0.022 × frameHeight`.

### Audio mix

- `AVMutableAudioMix` with two `AVMutableAudioMixInputParameters`:
  - `videoTrackSrc` audio at `preferences.previewSourceVolume`.
  - `audioTrackMic` at `preferences.previewCommentaryVolume`.
- These mirror the Mode C preview sliders one-for-one.

### Drawings + text bar overlay

`AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:in:parentLayer:)` rasterizes a `CALayer` hierarchy per frame at export.

- **Per clip**, attach a sub-layer at `beginTime = clipCompositionStart` covering its `recordingDuration`, holding:
  - **One `CAShapeLayer` per stroke**:
    - `path` = `CGMutablePath` traced through the stroke's `points` (denormalized to renderSize).
    - `strokeColor`, `lineWidth` (×renderSize.height), `lineCap = .round`, `lineJoin = .round`.
    - `CAKeyframeAnimation(keyPath: "strokeEnd")` from 0 to 1 with `keyTimes` derived from each `StrokePoint.t / strokeDuration` — preserves natural drawing tempo.
    - `CABasicAnimation(keyPath: "opacity")` 1→0 over 0.25s starting at the stroke's effective `cleared` time (auto-clear, `clearAll`, or never if it persists to clip end).
  - **Bottom text bar**:
    - Translucent black `CALayer` pinned to bottom 8% of frame.
    - `CATextLayer` content `"\(i+1)/\(N), \(clip.name), \(clip.tags.joined(separator: " "))"`.
    - Static for the duration of the clip's compositional range.

### Encode

`AVAssetWriter` (not `AVAssetExportSession`) for explicit control over HEVC settings.

Video output settings:

```
AVVideoCodecKey: .hevc
AVVideoWidthKey, AVVideoHeightKey: from Resolution dropdown
AVVideoCompressionPropertiesKey:
    AVVideoAverageBitRateKey: bitrateForQuality
    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
    AVVideoExpectedSourceFrameRateKey: sourceFps
```

Bitrate table (1080p baseline, scales linearly for 720p):

| Quality | 1080p | 720p |
|---------|-------|------|
| Low     | 6 Mbps | 3 Mbps |
| Medium  | 12 Mbps | 6 Mbps |
| High    | 24 Mbps | 12 Mbps |

Audio output: AAC, 192 kbps, stereo, 48 kHz.

Container: `.mp4` (HEVC in MP4 plays in QuickTime, Safari, VLC, iOS — most portable choice for HEVC).

### Filenames + progress

- Output: `<outputFolder>/<tag> - <projectName>.mp4`. The virtual tag becomes `all-clips - <projectName>.mp4`.
- Per-tag progress bar driven by `AVAssetWriter.outputQueue`'s `mediaTimeProcessed / totalDuration`.
- Tags export sequentially. VideoToolbox already saturates the encoder for one job; serial avoids contention and keeps the UI responsive.

## Decision log

The non-obvious calls made during design, with their rationale.

- **Swift + AVFoundation, not Rust + FFmpeg.** AVFoundation gives hardware H.264/H.265 encode + decode, capture, composition, and Core Animation overlays out of the box. A Rust path would mean wrapping FFmpeg or GStreamer plus calling AVFoundation through objc bridges for capture — roughly 3–5× more code, with sharper edges. Rust remains the right call when AVFoundation can't do something; for v1 it can do everything.
- **Non-destructive clip storage.** Clips reference source-video time ranges and event logs, not pre-rendered video files. Clips stay editable, recording stop is instant, disk usage during a session stays low. The compositional render only happens at export time.
- **Project = a folder, not a library.** Transparent in Finder, easy to back up / move / Dropbox / share. Project file format is plain JSON, debuggable and diffable.
- **Single `.mov` per recording (camera + mic together).** AVCaptureMovieFileOutput natively writes both tracks; AVAssetReader extracts each track at export. Avoids syncing two files.
- **Unified `CommentaryEvent` log.** One event stream replaces what could have been three separate lists (skip events, pause events, stroke events). Drives both Mode C live preview and export compositing through the same fold.
- **60Hz capture cap on stroke points.** Plenty for visually smooth lines on any display; halves storage vs 120Hz; well above the rate of perceivable hesitation. ~7KB max for a 5-second stroke.
- **Vector strokes, not rasterized canvases.** Resolution-independent — the same data renders crisply at 720p preview and 1080p export. Rendered through `CAShapeLayer` + `CAKeyframeAnimation` at export with `keyTimes` from each point's `t`, preserving natural drawing tempo.
- **Time-stretched single frame for source freeze.** AVMutableComposition has no native "freeze" insert. Inserting a 1-frame slice of source and `scaleTimeRange`-ing it to the freeze duration produces a freeze frame using only built-in APIs.
- **Volume sliders are global, not per-clip.** Tracks user intent — they tune source vs commentary balance once and want it applied across the project. Per-clip overrides can be added later if needed.
- **`AVAssetWriter`, not `AVAssetExportSession`, for export.** Direct control over HEVC bitrate, profile level, and the audio mix. Export presets hide too much.
- **Sequential tag export.** VideoToolbox saturates on one HEVC job; running multiple in parallel would not be faster and would steal CPU from the UI.

## Open items (post-v1)

- Re-trim a clip's start/end after creation.
- Color/width pickers for drawings.
- Camera + mic device selection in Preferences.
- Per-clip volume overrides.
- Bookmark relink UI for moved source videos.
- Crash-safe partial-recording recovery.
- Configurable PiP corner / size.
- Tag rename / merge across all clips at once.
- Export preview thumbnail + duration estimate before running encode.
