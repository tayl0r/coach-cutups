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
0:18 left in clip · 1:42 left in tag
Rendering at 47 fps · ETA 2:08
```

## Scope

Per-tag granularity within a multi-tag export run. The existing
"Exporting <tag> (N of M tags)…" headline stays. The new lines
report position WITHIN the currently-running compilation:

- **Clip i of N** — which clip in the compilation is currently
  being encoded (derived from session progress).
- **Time left in clip** — encode time remaining for the active
  clip's composition range.
- **Time left in tag** — encode time remaining for the whole
  compilation.
- **Rendering FPS** — encoded-frame throughput averaged over the
  last ~30s of wall time.
- **ETA** — wall time remaining for the active tag.

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

- `record` appends a sample and evicts samples older than
  `windowSeconds` from the front.
- Returns nil until at least 5 samples are present AND ≥2s of wall
  time has elapsed since the oldest sample (avoids spurious
  early-rate readings).
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

Inside `export`, after the export session is configured and
`exportSession.export()` is launched, run a sibling task with
`async let` or `Task.detached` that:

1. Captures `totalDuration = plan.totalDurationSeconds`, the plan
   itself, `clipsByID`, and the videoComp's frame rate.
2. Initializes a `RollingRate(windowSeconds: 30)`.
3. Loops at 5Hz while `session.status` is `.exporting`:
   - Reads `(progress, wallTime)`, records into the rolling rate.
   - Computes `compositionTime = progress * totalDuration`.
   - Looks up the active clip via `locate`.
   - Builds `ExportProgress` and calls `onProgress` on the main
     actor.
4. Exits when session status leaves `.exporting`.

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

            // 0:18 left in clip · 1:42 left in tag
            Text(timeLeftLine(p))
                .font(.callout)
                .foregroundStyle(.secondary)

            // Rendering at 47 fps · ETA 2:08  (omitted while rate is unknown)
            if let fps = p.renderingFramesPerSecond, let eta = p.etaTagSeconds {
                Text("Rendering at \(Int(fps.rounded())) fps · ETA \(formatDuration(eta))")
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

`timeLeftLine(_:)` is a small private helper that returns
`"\(formatDuration(p.remainingInCurrentClipSeconds)) left in clip · \(formatDuration(p.remainingInTagSeconds)) left in tag"`. Both
durations use the existing `formatDuration` from `ClipSidebar.swift`
(same target).

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
