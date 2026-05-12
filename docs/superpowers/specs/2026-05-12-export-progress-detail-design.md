# Richer export progress UI

## Goal

The export sheet currently shows "Exporting <tag> (N of M)…" with an
indeterminate spinner. Add per-clip granularity, a determinate
progress bar, a rendering-FPS readout, and ETAs so the user can see
how the current tag's compilation is progressing and how long is
left.

User-visible changes during a running export:

```
Exporting shot (1 of 3 tags)…
[========================            ]   ← determinate
Clip 4 of 12 — "shot-2-12:34"
0:18 of clip remaining · 1:42 of tag remaining     ← composition (video) time
Rendering at 47 fps · ETA 2:08 (wall time)         ← wall-clock prediction
0:21 ETA this clip (wall time)                     ← wall-clock prediction
```

The two unit families are deliberately separated by line so the user
can read them without confusing video-content-remaining (stable,
monotonic) with wall-clock prediction (volatile, rate-driven).

## Scope

Per-tag granularity within a multi-tag export run. The existing
"Exporting <tag> (N of M tags)…" headline stays. The new lines
report position WITHIN the currently-running compilation:

- **Clip i of N** — which clip in the compilation is currently
  being encoded (derived from session progress).
- **Clip / tag remaining** — composition (video) seconds remaining
  in the active clip's range and in the whole compilation. Labeled
  "of clip remaining" / "of tag remaining" so the unit is clear.
- **Rendering FPS** — encoded-frame throughput averaged over the
  last ~30s of wall time.
- **ETA** — wall-clock seconds until the active tag finishes
  encoding. Labeled "(wall time)" to distinguish from the
  composition-time lines.
- **Per-clip ETA** — wall-clock seconds until the active clip
  finishes encoding. Also labeled "(wall time)."

## Non-goals

- ETA across the whole multi-tag run. Each tag is a separate export
  session; tags later in the queue won't have a measured rate yet.
- A cancel button. ExportSheet's comment already calls this out as
  deferred; not part of this feature.
- Per-clip ETA broken out as its own readout (the "0:18 left in
  clip" line already covers it indirectly via rate × remaining).
- Configurable smoothing window. 30s is hardcoded.
- Frame counter (e.g., "1234 / 5678 frames"). The fps + time-left
  cover the same information without the awkward big number.

## Architecture

The exporter (`CompilationExporter`, in `VideoCoachCore`) gains an
optional `onProgress` callback. While `AVAssetExportSession.export()`
runs, a sibling `Task` polls `session.progress` at 5Hz, derives an
`ExportProgress` snapshot, and calls `onProgress` on the main actor.
The derivation is pulled into two pure helpers in a new
`ExportProgress.swift` so the genuinely-tricky parts (clip lookup
from composition time, rolling-window rate) are unit-tested in
`VideoCoachCoreTests`.

The UI (`ExportSheet`) accepts `ExportProgress` snapshots into a new
`@State currentProgress` and renders the new lines. The
indeterminate `ProgressView()` becomes determinate, driven by
`fractionCompleted`.

## Data model (`apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`)

```swift
public struct ExportProgress: Sendable {
    public let fractionCompleted: Float           // 0…1 from session
    public let currentClipIndex: Int              // 1-based
    public let totalClipCount: Int                // plan.entries.count
    public let currentClipName: String?
    public let remainingInCurrentClipSeconds: Double
    public let remainingInTagSeconds: Double
    public let renderingFramesPerSecond: Double?  // nil until rate stabilises
    public let etaCurrentClipSeconds: Double?     // nil until rate known
    public let etaTagSeconds: Double?
}
```

### Helper 1: `locate(compositionTime:in:)`

Given a composition time in seconds and a `CompilationPlan`,
returns `(clipIndex: Int, entry: CompilationPlan.Entry)?` or nil
if the time falls outside any entry's range.

- Entry range is `[compositionStart, compositionStart + duration)`.
- `clipIndex` is 1-based for direct display.
- Returns nil only when compositionTime > totalDuration (encoder
  reports progress beyond the composition end during finalisation).

### Helper 2: `RollingRate`

```swift
struct RollingRate {
    let windowSeconds: Double   // 30 by default
    private var samples: [(wallTime: Double, fraction: Double)]

    mutating func record(wallTime: Double, fraction: Double)
    func compositionSecondsPerWallSecond(totalDuration: Double) -> Double?
}
```

- `record` appends a sample, then evicts samples older than
  `windowSeconds` from the front. The sufficiency gate below is
  evaluated AFTER eviction — so a stale-only window correctly
  surfaces as nil even if many samples accumulated earlier.
- Returns nil until at least 5 samples are present AND ≥2s of wall
  time has elapsed since the oldest surviving sample (avoids
  spurious early-rate readings).
- When the rate is computed: `(latest.fraction − oldest.fraction)
  * totalDuration / (latest.wallTime − oldest.wallTime)`.
- When all samples have the same `fraction` (encoder stalled),
  returns 0.0 — caller must treat 0 as "ETA unknown."

Rendering FPS is `compSecPerWallSec * outputFrameRate`, where
`outputFrameRate` is read from `videoComp.frameDuration` in the
exporter (currently hardcoded `1/30`; we read it back so changing
the frame rate later doesn't require updating two places).

ETA is `remainingSeconds / compSecPerWallSec` when the rate is > 0,
else nil.

## Exporter changes (`CompilationExporter.swift`)

`export(...)` gets one new trailing arg:

```swift
public func export(
    plan: CompilationPlan,
    clipsByID: [UUID: Clip],
    sourceAssets: [Int: AVURLAsset],
    clipWebcamAssets: [UUID: AVURLAsset],
    outputURL: URL,
    resolution: Resolution,
    quality: Quality,
    sourceVolume: Double,
    commentaryVolume: Double,
    onProgress: ((ExportProgress) -> Void)? = nil
) async throws
```

Inside `export`, **before** `await exportSession.export()`, spawn the
sampler as a `Task.detached` (NOT `async let`, NOT a plain `Task { }`).
`CompilationExporter` is a `public actor`, so a child task without
detachment would inherit actor isolation and could serialize with the
export call. `Task.detached` runs off-actor so the sampler's polling
never contends with `export()`.

The sampler's closure captures by value:
- `plan` (Sendable struct)
- `clipsByID` (Dictionary of Sendable values)
- `totalDuration = plan.totalDurationSeconds`
- `outputFrameRate = Double(videoComp.frameDuration.timescale) / Double(videoComp.frameDuration.value)`
- A reference to the `AVAssetExportSession` (its `progress`/`status` properties are thread-safe per Apple docs)
- `onProgress` (`@Sendable` closure parameter)

Sampler body:

1. Initializes a `RollingRate(windowSeconds: 30)`.
2. Loops at 5Hz while `session.status == .exporting` and
   `!Task.isCancelled`:
   - Reads `(progress, wallTime)`, records into the rolling rate.
   - Computes `compositionTime = progress * totalDuration`.
   - Looks up the active clip via `locate`.
   - Builds `ExportProgress` and dispatches `onProgress(snapshot)`
     via `await MainActor.run { … }` so the SwiftUI consumer sees
     state changes on the main actor.
3. Exits when session status leaves `.exporting` or the task is
   cancelled.

After `await exportSession.export()` returns, `export` MUST
`cancel()` the sampler task explicitly before returning, even on
success. The status-transition exit at the loop top runs at most
200ms later than the export's actual completion; a stale snapshot
could otherwise land in `ExportSheet` after the sheet has moved on
to the next tag. Use a `defer { samplerTask.cancel() }` immediately
after spawning the task so the cancellation also runs on error
paths.

The existing `progress(of:)` AsyncStream method is removed (no
internal or external callers after this change).

## UI changes (`ExportSheet.swift`)

State additions on the sheet:

```swift
@State private var currentProgress: ExportProgress? = nil
```

Cleared when the export run starts (so old values don't bleed into
the next tag).

`progressSection` is restructured. Replace the existing
implementation with:

```swift
private var progressSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        guard let run = run else { return AnyView(EmptyView()) }

        // Headline: unchanged — tag-of-tags + active tag display.
        Text(headlineText(for: run))
            .font(.headline)

        // Determinate progress bar driven by the latest snapshot.
        ProgressView(value: Double(currentProgress?.fractionCompleted ?? 0))
            .progressViewStyle(.linear)

        if let p = currentProgress {
            // Clip i of N — "clipname"
            if let name = p.currentClipName {
                Text("Clip \(p.currentClipIndex) of \(p.totalClipCount) — \"\(name)\"")
                    .font(.callout)
            } else {
                Text("Clip \(p.currentClipIndex) of \(p.totalClipCount)")
                    .font(.callout)
            }

            // Composition (video) time remaining. Stable — ticks
            // down monotonically as encoding progresses.
            //   "0:18 of clip remaining · 1:42 of tag remaining"
            Text(contentRemainingLine(p))
                .font(.callout)
                .foregroundStyle(.secondary)

            // Wall-time ETA for the active tag.
            //   "Rendering at 47 fps · ETA 2:08 (wall time)"
            if let fps = p.renderingFramesPerSecond, let eta = p.etaTagSeconds {
                Text("Rendering at \(Int(fps.rounded())) fps · ETA \(formatDuration(eta)) (wall time)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Wall-time ETA for the active clip. Same nil guard as
            // the rendering FPS — both depend on a measured rate.
            //   "0:21 ETA this clip (wall time)"
            if let etaClip = p.etaCurrentClipSeconds {
                Text("\(formatDuration(etaClip)) ETA this clip (wall time)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
```

(The pseudocode wraps in `AnyView` for the guard short-circuit; in
practice we use the existing `if let run` pattern that the file
already follows.)

`contentRemainingLine(_:)` is a small private helper that returns
`"\(formatDuration(p.remainingInCurrentClipSeconds)) of clip remaining · \(formatDuration(p.remainingInTagSeconds)) of tag remaining"`.
Both durations use the existing `formatDuration` from
`ClipSidebar.swift` (same target). The phrasing ("of clip
remaining" / "of tag remaining") is chosen so the unit reads as
*video content*, not as wall-clock time — the wall-clock ETAs
live on the lines below.

The "Tags export sequentially. This may take several minutes…"
informational line is removed — the real numbers replace it.

The `ExportSheet` wiring that calls `CompilationExporter.export(...)`
passes `onProgress: { snap in self.currentProgress = snap }` so each
sample lands in `@State`. SwiftUI re-renders the section.

## Edge cases

- **Stalled encoder.** `RollingRate` returns 0 when fraction hasn't
  moved; the UI omits the FPS/ETA line (because the `if let` guard
  on both nil values fails).
- **Rate jitter at start.** The "≥5 samples and ≥2s of wall time"
  gate suppresses early-rate noise. The line appears within ~3s of
  starting any export of nontrivial length.
- **Composition time at exact entry boundary.** `locate` uses
  half-open `[start, start+duration)`. The last clip's terminal
  edge is inclusive (`compositionTime == totalDuration` maps to
  the last entry, not nil).
- **CMTime/Double drift across the plan.** `CompilationExporter`
  tracks its actual composition cursor in CMTime (timescale 600);
  the `CompilationPlan.Entry.compositionStart` field is a Double
  cumulative sum that can drift by sub-millisecond amounts per
  entry — up to roughly 10ms over a long compilation. `locate`
  uses the Double values, so at a clip boundary the converted
  `session.progress * totalDuration` may briefly fall in a gap of
  a few ms and `locate` returns nil. This is cosmetically
  acceptable: at 5Hz polling, the worst case is a single 200ms
  sample where the UI omits the clip name + per-clip lines.
- **Multi-tag run between tags.** Each tag's export creates a fresh
  session; `currentProgress` is cleared between tags so the bar
  jumps to 0 at the start of each tag rather than appearing to
  rewind from 100%.
- **Encoder reports progress > 1.0.** AVFoundation occasionally
  bumps progress just past 1.0 during finalisation; the UI clamps
  the linear bar at 1.0 visually (SwiftUI's `ProgressView(value:)`
  clamps automatically).

## Testing

New unit tests in
`apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`:

- `locate(compositionTime:in:)`:
  - returns clip 1 for time 0
  - returns clip 1 for time just before entry 1's end
  - returns clip 2 for time at entry 1's end (boundary belongs to
    next clip)
  - returns last clip for `time == totalDuration`
  - returns nil for `time > totalDuration`
  - returns nil for a plan with zero entries

- `RollingRate`:
  - returns nil with fewer than 5 samples
  - returns nil before 2s of wall time elapsed
  - returns a steady rate for evenly-spaced samples
  - returns the *recent* rate when oldest samples are evicted
    (changing throughput is reflected)
  - returns 0 when all samples have the same fraction

UI behaviour (snapshot rendering, determinate bar, conditional FPS
line) is verified manually during a real export.

## File changes summary

- `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`
  (new) — struct, `locate`, `RollingRate`.
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`
  (new) — TDD coverage.
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift` —
  add `onProgress` parameter, spawn the sampler task, remove the
  obsolete `progress(of:)` method.
- `apple/App/Export/ExportSheet.swift` — add
  `@State currentProgress`, restructure `progressSection`, wire the
  callback into the export call site.
