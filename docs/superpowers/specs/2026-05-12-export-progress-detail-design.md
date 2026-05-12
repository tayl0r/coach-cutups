# Per-video export progress with projections

## Goal

Replace the export sheet's indeterminate spinner with a structured
view: a top summary of the whole run, plus a list with one row per
output video showing live or projected stats based on each video's
state (pending / active / done).

User-visible behaviour during an export:

```
Exporting (1 of 4 videos done)             47 fps · 1:08 video left
                                            ETA 1:25 (3:42 PM)

Done    shot.mp4         ✓ 0:45 video · 0:29 encode · avg 48 fps
Active  on-goal.mp4      ────[=======          ]── 38%
                         47 fps · 0:18 video left · ETA 0:23 (3:18 PM)
Pending set-piece.mp4    0:33 video · ~0:22 to encode · done 3:42 PM
Pending all-clips.mp4    2:12 video · ~1:24 to encode · done 5:06 PM
```

## Concept

A "video" is one output `.mp4`. Each selected row in the export
sheet — a tag's compilation, or the `all-clips` synthetic — is one
video. The run exports them sequentially, one
`AVAssetExportSession` at a time.

## Scope

- Per-video state (pending / active / done) shown as rows.
- Top summary with `X/Y` videos done, current FPS, total video
  content remaining, run-level wall-clock ETA, and an absolute
  "estimated done" clock time.
- Live encoding-rate measurement (30s rolling window) feeds FPS,
  per-active ETA, and projections for pending rows.
- Projected absolute completion clock time per pending row,
  factoring videos ahead of it.

## Non-goals

- Per-clip-within-a-compilation granularity (the prior spec
  iteration). Each video is one row, regardless of how many clips
  it bundles.
- A cancel button. Same deferral as before — exporter doesn't
  expose a cancel hook today.
- Persisting the displayed stats after the export sheet closes.
- Estimating size of output files.
- Handling the corner case where the user opens a second export
  sheet during a running export (the UI gates this off today).

## Architecture

The exporter (`CompilationExporter`, in `VideoCoachCore`) gains an
optional `onProgress` callback. While `AVAssetExportSession.export()`
runs, a `Task.detached` polls `session.progress` at 5Hz, derives
the current row's fraction + rate, and emits an `ExportProgress`
snapshot.

The full run-level state lives in `ExportSheet`. It tracks the
ordered list of selected outputs, transitions their `Status` as
each export starts / completes, holds the latest `RollingRate`
across the whole run (so the rate survives between videos), and
re-projects pending rows on every snapshot.

The genuinely-tricky logic (rolling rate, per-row projection)
lives in `VideoCoachCore` as pure helpers so they're tested in
`VideoCoachCoreTests`.

## Data model (`apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`)

```swift
public struct VideoExportItem: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        case pending
        case active(fractionCompleted: Float)
        case done(encodeWallSeconds: Double, averageFps: Double)
    }
    public let id: String                  // tag key or all-clips sentinel
    public let displayName: String         // "shot.mp4"
    public let videoDurationSeconds: Double
    public var status: Status
}

public struct ExportProgress: Sendable {
    /// All output videos in queue order. First item is always the
    /// first one that started; done items appear before active /
    /// pending, in the order they finished (== queue order).
    public let items: [VideoExportItem]

    /// Current rendering rate measured by the active row. nil
    /// before the rate has stabilised (first ~2s of the first
    /// video).
    public let currentRenderingFps: Double?

    /// Sum of remaining composition seconds across active + pending.
    /// Used by the top summary's "video left" reading.
    public let totalVideoSecondsRemaining: Double

    /// Run-level wall-clock ETA (seconds from "now"). nil until
    /// the rate is known. Includes the pending queue.
    public let totalEtaSeconds: Double?

    /// Absolute clock time when the whole run is projected to
    /// finish. nil until the rate is known.
    public let projectedCompletionDate: Date?
}
```

### Helper: `RollingRate`

Same shape as the prior iteration. Lives in
`ExportProgress.swift`. Holds the last ~30s of
`(wallTime, fractionCompleted, compositionDuration)` samples for
the active video and reports `compositionSecondsPerWallSecond`
once the sample window satisfies the sufficiency gate.

```swift
struct RollingRate {
    let windowSeconds: Double           // 30 by default
    private var samples: [Sample]       // (wallTime, encodedCompSeconds)

    mutating func record(wallTime: Double, encodedCompSeconds: Double)
    func compositionSecondsPerWallSecond() -> Double?
}
```

- `record` appends a sample, then evicts samples older than
  `windowSeconds` from the front. The sufficiency gate below is
  evaluated AFTER eviction.
- Returns nil until at least 5 samples are present AND ≥2s of wall
  time has elapsed since the oldest surviving sample.
- Rate = `(latest.encoded − oldest.encoded) / (latest.wallTime − oldest.wallTime)`.
- The rate persists across video boundaries: the run-level
  `RollingRate` is not reset when one video finishes, so the rate
  carries forward to inform projections for the next video. The
  sampler resets only the wall-time baseline when re-attached.

Rendering FPS for display = `compSecPerWallSec × outputFrameRate`,
where `outputFrameRate = videoComp.frameDuration.timescale / value`
(currently `1/30`, read at runtime so future changes don't drift).

### Helper: `projectRun`

```swift
struct RunProjection {
    let totalSecondsRemaining: Double       // active + pending
    let perItemRemaining: [String: Double]  // by item id, wall-time remaining
    let perItemDoneDate: [String: Date]     // by item id, absolute clock time
}

func projectRun(
    items: [VideoExportItem],
    rate: Double,            // compSecPerWallSec; > 0
    now: Date
) -> RunProjection
```

Pure function, easily tested. Behaviour:

- For each `.done` item: not included in the remaining sums; date
  for that item is omitted from `perItemDoneDate` (or set to the
  actual finish time — see Section "Subtleties" below).
- For the (at most one) `.active` item: wall remaining =
  `(1 − fraction) × video.duration / rate`. Its date =
  `now + wallRemaining`.
- For each `.pending` item N (in queue order after the active):
  cumulative wall remaining = active remaining + Σ pending[1..N−1]
  duration / rate + pending[N].duration / rate. Date =
  `now + cumulative`.
- Sum of all per-item remainings is `totalSecondsRemaining`.

Rate fallback when no measured rate yet (caller decides — see
`ExportSheet` section): use `1.0` (realtime). Projections still
display so the user has something to look at, with the
understanding that they'll refine once a real rate is known.

## Exporter changes (`CompilationExporter.swift`)

`export(...)` signature gains one trailing arg:

```swift
public func export(
    ...,
    onProgress: ((Float) -> Void)? = nil
) async throws
```

Note: the exporter publishes ONLY the active session's
`fractionCompleted`. The run-level state (item list, projections)
lives in `ExportSheet` because the exporter doesn't know about the
queue of videos — it only sees one at a time.

Inside `export`:

- Configure the session as today.
- Before `await exportSession.export()`, spawn the sampler as a
  `Task.detached` (NOT `async let`, NOT plain `Task { }`).
  `CompilationExporter` is a `public actor`, so child tasks without
  detachment would inherit actor isolation and could serialize
  with the export call.
- The detached task captures by value: the session reference (its
  `progress`/`status` are thread-safe per Apple docs) and the
  `onProgress` closure.
- Sampler loop at 5Hz while `session.status == .exporting` and
  `!Task.isCancelled`: read `session.progress`, dispatch
  `onProgress(progress)` via `await MainActor.run { … }`.
- Immediately after spawning the task, `defer { samplerTask.cancel() }`
  so the cancellation also fires on error paths and prevents a stale
  late callback from landing in `ExportSheet` after the next video
  has started.

The exporter's existing public `progress(of:)` AsyncStream is
removed (no callers; superseded by `onProgress`).

## ExportSheet changes

### State additions

```swift
@State private var items: [VideoExportItem] = []
@State private var runRate = RollingRate(windowSeconds: 30)
@State private var runStartedAt: Date? = nil
@State private var currentVideoStartedAt: Date? = nil
@State private var projection: RunProjection? = nil
@State private var lastSnapshot: ExportProgress? = nil
```

The existing `Run` model already enumerates outputs in queue order;
`items` is initialised from it when the user presses Export. Status
starts `.pending` for all entries.

### State machine

- **On run start:** `items` populated, all `.pending`. `runStartedAt = Date()`.
- **On video N start:** flip `items[N].status` to
  `.active(fractionCompleted: 0)`. `currentVideoStartedAt = Date()`.
- **On `onProgress(fraction)`:** update the active item's
  `fractionCompleted`. Compute `encodedComp = fraction × video.duration`,
  `runRate.record(wallTime: Date().timeIntervalSince1970, encodedCompSeconds: encodedSoFar)`
  where `encodedSoFar = Σ done videos' durations + active's
  encodedComp`. Rebuild the `ExportProgress` snapshot and
  `projection` for the UI.
- **On video N completion (returned from `export(...)`):** flip
  `items[N].status` to
  `.done(encodeWallSeconds: Date().timeIntervalSince(currentVideoStartedAt!),
   averageFps: averageFpsForThisVideo)`. Average FPS is computed as
  `video.duration / encodeWallSeconds × outputFrameRate`. Then
  proceed to video N+1.
- **On final completion:** `projection = nil`, transition to the
  existing summary sheet.

`averageFpsForThisVideo` is independent of the rolling rate — it's
a single end-of-video calculation, so a video that ran slowly then
fast still shows its truthful average.

### `progressSection` rewrite

Replace the existing implementation entirely:

```swift
private var progressSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        runSummary
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                videoRow(item)
            }
        }
    }
}

@ViewBuilder
private var runSummary: some View {
    let doneCount = items.filter {
        if case .done = $0.status { return true } else { return false }
    }.count
    HStack {
        Text("Exporting (\(doneCount) of \(items.count) videos done)")
            .font(.headline)
        Spacer()
        if let snapshot = lastSnapshot,
           let fps = snapshot.currentRenderingFps {
            Text("\(Int(fps.rounded())) fps")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
    let totalLeft = lastSnapshot?.totalVideoSecondsRemaining ?? 0
    let etaSecs = lastSnapshot?.totalEtaSeconds
    let doneDate = lastSnapshot?.projectedCompletionDate
    Text(runSummaryLine(totalLeft: totalLeft, etaSecs: etaSecs, doneDate: doneDate))
        .font(.callout)
        .foregroundStyle(.secondary)
}

@ViewBuilder
private func videoRow(_ item: VideoExportItem) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(item.displayName)
            .font(.callout.weight(.medium))
            .frame(width: 160, alignment: .leading)
            .lineLimit(1).truncationMode(.middle)
        VStack(alignment: .leading, spacing: 2) {
            switch item.status {
            case .pending:
                pendingDetail(item)
            case .active(let frac):
                ProgressView(value: Double(frac))
                    .progressViewStyle(.linear)
                activeDetail(item, fraction: frac)
            case .done(let wall, let avgFps):
                doneDetail(item, encodeWall: wall, avgFps: avgFps)
            }
        }
    }
}
```

Each detail builder produces one or two `Text` lines with the
required wording:

- **Pending:** `"\(formatDuration(item.videoDurationSeconds)) video · ~\(formatDuration(projection.perItemRemaining[item.id])) to encode · done \(clockTime(projection.perItemDoneDate[item.id]))"`
- **Active:** `"\(Int(fps.rounded())) fps · \(formatDuration(videoLeft)) video left · ETA \(formatDuration(wallLeft)) (\(clockTime(doneDate)))"`
- **Done:** `"✓ \(formatDuration(item.videoDurationSeconds)) video · \(formatDuration(encodeWall)) encode · avg \(Int(avgFps.rounded())) fps"`

`clockTime(_:)` uses `DateFormatter` with `.short` time style for
the user's locale (e.g., "3:42 PM" in en_US).

### `Run` aggregator wiring

`ExportSheet` already drives the multi-output loop. Within that
loop, before each `CompilationExporter.export(...)` call, transition
the matching item to `.active`. Pass `onProgress: { fraction in
self.handleSampleFromActiveVideo(fraction) }`. After the call
returns, transition the item to `.done` with the measured
wall-time + average FPS, then continue to the next video.

`handleSampleFromActiveVideo(_:)` is the central state update:

1. Update `items[active].status = .active(fraction)`.
2. `runRate.record(...)` — wall time `now`, encoded comp seconds
   = sum of `.done` items' durations + `fraction × active.duration`.
3. Compute `rate = runRate.compositionSecondsPerWallSecond() ?? 1.0`.
4. Compute `currentRenderingFps = rate × outputFrameRate` (nil when
   `runRate` returns nil).
5. `projection = projectRun(items: items, rate: rate, now: Date())`.
6. `lastSnapshot = ExportProgress(items: items, currentRenderingFps:, …)`.

## Subtleties

- **`outputFrameRate` is read once per export call** from the
  current `videoComp.frameDuration`. It's the same `1/30` across
  all of today's exports; reading it (rather than hardcoding 30)
  keeps the code honest if the frame rate ever changes.
- **Rate persistence across video boundaries** — `runRate` is run-
  scoped (one per export run, not one per video). When a video
  finishes, the sampler stops; the next video's first sample
  pushes onto the existing window. After ~30s of total encoding
  time, samples from the previous video age out naturally.
- **The very first projection** (no rate yet) uses the 1.0 fallback.
  The estimates show but visibly snap when the first real rate
  arrives — that's acceptable UX (better than no estimate at all
  for ~2s).
- **`done` items' clock time in `perItemDoneDate`** — keep the
  actual finish time (i.e., the time the snapshot was taken when
  the transition fired) so the UI can show "done at 3:18 PM" if
  ever wanted. Today's UI doesn't show it, but the data is cheap.
- **Encoder reports progress > 1.0 briefly.** `ProgressView(value:)`
  clamps automatically. `runRate.record` clamps `fraction` to
  `[0, 1]` before computing `encodedComp` so a spurious 1.01 doesn't
  pollute the rate.
- **Clip in multiple tags appears in multiple output rows.** This
  is correct — `shot.mp4` and `on-goal.mp4` are separate outputs
  that legitimately include the same source clip. No dedup.
- **Sheet height** — with 1–6 videos this fits without scrolling.
  For dozens of selected tags, the list scrolls; the sheet's
  existing `ScrollView` for the tag picker is precedent.

## Testing

New unit tests in
`apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`:

- `RollingRate`:
  - returns nil with fewer than 5 samples
  - returns nil before 2s of wall time elapsed
  - returns a steady rate for evenly-spaced samples
  - reflects rate change when oldest samples are evicted past
    `windowSeconds`
  - returns 0 when all samples report the same `encodedCompSeconds`

- `projectRun`:
  - empty items → empty projection (zero remaining, no dates)
  - all-pending: queue order matches projected dates
  - one active + several pending: cumulative dates are monotonic
  - rate fallback (`1.0`) when called with rate ≤ 0 (sanity guard)
  - mixing done + active + pending: only active + pending sum into
    `totalSecondsRemaining`

UI behaviour (row transitions, top summary aggregation, clock-time
rendering) is verified manually during a real export.

## File changes summary

- `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`
  (new) — `VideoExportItem`, `ExportProgress`, `RollingRate`,
  `RunProjection`, `projectRun(...)`.
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`
  (new) — TDD coverage of `RollingRate` and `projectRun`.
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift` —
  add `onProgress: ((Float) -> Void)?` parameter; spawn detached
  sampler with deferred cancel; remove obsolete `progress(of:)`.
- `apple/App/Export/ExportSheet.swift` — significant rewrite of
  `progressSection`; new `@State items / runRate / projection /
  lastSnapshot`; per-snapshot state updater
  `handleSampleFromActiveVideo`; transition-on-start /
  transition-on-complete around the existing per-output loop.
