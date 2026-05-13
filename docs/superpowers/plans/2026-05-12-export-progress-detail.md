# Per-video Export Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the export sheet's indeterminate spinner with a per-output-video list showing pending / active / done rows, plus a top run summary with live FPS, run-level ETA, and projected wall-clock done time.

**Architecture:** Domain logic (`RollingRate`, `projectRun`, data types) lives in `VideoCoachCore` as pure-Swift, unit-tested helpers. `CompilationExporter` gains an `onProgress` callback published from a `Task.detached` sampler. `ExportSheet` owns the run-level state machine, threads progress through the per-output loop, and renders the new UI.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation (`AVAssetExportSession.progress`), `Task.detached` for actor-isolation escape, `Date`/`DateFormatter` for clock-time display.

**Spec:** `docs/superpowers/specs/2026-05-12-export-progress-detail-design.md`

---

## File Structure

- **`apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`** (new) — `VideoExportItem`, `ExportProgress`, `RollingRate`, `RunProjection`, `projectRun(...)`. Pure value types and free functions; no SwiftUI, no AVFoundation.
- **`apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`** (new) — XCTest cases for `RollingRate` and `projectRun`.
- **`apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift`** (modify) — add trailing `onProgress: ((Float) -> Void)?` to `export(...)`; spawn `Task.detached` sampler with `defer { cancel() }`; remove now-unused `progress(of:)` AsyncStream method.
- **`apple/App/Export/ExportSheet.swift`** (modify) — add `@State items`, `@State runRate`, `@State runStartedAt`, `@State currentVideoStartedAt`, `@State projection`, `@State lastSnapshot`; build items at run start; add `handleSampleFromActiveVideo(_:)`; wire transitions around the per-output loop; replace `progressSection` with `runSummary` + `videoRow(_:)` + state-specific detail builders.

---

## Task 1: Skeleton types in `ExportProgress.swift`

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`

This task defines the data types `VideoExportItem`, `ExportProgress`, and `RunProjection`, plus an empty `RollingRate` struct and an empty `projectRun(...)` function that returns a zero `RunProjection`. Subsequent tasks fill in the logic via TDD.

- [ ] **Step 1: Create the file with the value-type contract**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift` with:

```swift
import Foundation

/// One output `.mp4` in a multi-video export run. The `id` is either a tag
/// key (e.g. `"shot"`) or the `all-clips` sentinel string supplied by the
/// caller — it just needs to be unique within the run.
public struct VideoExportItem: Sendable, Identifiable, Equatable {
    public enum Status: Sendable, Equatable {
        case pending
        case active(fractionCompleted: Float)
        case done(encodeWallSeconds: Double, averageFps: Double)
    }

    public let id: String
    public let displayName: String
    public let videoDurationSeconds: Double
    public var status: Status

    public init(
        id: String,
        displayName: String,
        videoDurationSeconds: Double,
        status: Status = .pending
    ) {
        self.id = id
        self.displayName = displayName
        self.videoDurationSeconds = videoDurationSeconds
        self.status = status
    }
}

/// Snapshot of the export run handed to the UI on every sampler tick or
/// status transition. All fields are derived; `ExportSheet` recomputes the
/// whole struct on each update.
public struct ExportProgress: Sendable, Equatable {
    public let items: [VideoExportItem]
    public let currentRenderingFps: Double?
    public let totalVideoSecondsRemaining: Double
    public let totalEtaSeconds: Double?
    public let projectedCompletionDate: Date?

    public init(
        items: [VideoExportItem],
        currentRenderingFps: Double?,
        totalVideoSecondsRemaining: Double,
        totalEtaSeconds: Double?,
        projectedCompletionDate: Date?
    ) {
        self.items = items
        self.currentRenderingFps = currentRenderingFps
        self.totalVideoSecondsRemaining = totalVideoSecondsRemaining
        self.totalEtaSeconds = totalEtaSeconds
        self.projectedCompletionDate = projectedCompletionDate
    }
}

/// Result of projecting the remaining run against a measured (or fallback)
/// encoding rate. Pure data; the UI reads it directly.
public struct RunProjection: Sendable, Equatable {
    /// Wall-time seconds remaining across active + pending items.
    public let totalSecondsRemaining: Double
    /// Per-item wall-time remaining, keyed by `VideoExportItem.id`. Pending
    /// items get their full duration ÷ rate; the active item gets the
    /// remaining fraction ÷ rate. Done items are absent.
    public let perItemRemaining: [String: Double]
    /// Per-item absolute clock time at which it's projected to finish,
    /// keyed by `VideoExportItem.id`. Includes done items at their actual
    /// finish time when supplied.
    public let perItemDoneDate: [String: Date]

    public init(
        totalSecondsRemaining: Double,
        perItemRemaining: [String: Double],
        perItemDoneDate: [String: Date]
    ) {
        self.totalSecondsRemaining = totalSecondsRemaining
        self.perItemRemaining = perItemRemaining
        self.perItemDoneDate = perItemDoneDate
    }

    public static let empty = RunProjection(
        totalSecondsRemaining: 0,
        perItemRemaining: [:],
        perItemDoneDate: [:]
    )
}

/// Rolling-window estimator of composition-seconds-per-wall-second. Used by
/// `ExportSheet` to drive the run-level rate. See spec for the sufficiency
/// gate (≥5 samples AND ≥2s wall time across surviving samples).
public struct RollingRate: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let wallTime: Double
        let encodedCompSeconds: Double
    }

    public let windowSeconds: Double
    var samples: [Sample] = []

    public init(windowSeconds: Double = 30) {
        self.windowSeconds = windowSeconds
    }

    /// Append a sample (clamped to non-decreasing encoded seconds) and evict
    /// samples older than `windowSeconds` from the front.
    public mutating func record(wallTime: Double, encodedCompSeconds: Double) {
        // Body implemented in Task 2.
        _ = wallTime
        _ = encodedCompSeconds
    }

    /// Composition seconds per wall second, or nil when the sample window
    /// hasn't reached the sufficiency gate.
    public func compositionSecondsPerWallSecond() -> Double? {
        // Body implemented in Task 2.
        return nil
    }
}

/// Project the remaining run forward at the given rate. See spec for math.
/// `rate` MUST be > 0; callers fall back to `1.0` (realtime) before a real
/// measurement is available.
public func projectRun(
    items: [VideoExportItem],
    rate: Double,
    now: Date
) -> RunProjection {
    // Body implemented in Task 3.
    _ = items
    _ = rate
    _ = now
    return .empty
}
```

- [ ] **Step 2: Verify the package still builds**

Run: `cd apple/VideoCoachCore && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift
git commit -m "feat(export): add ExportProgress data-type skeleton"
```

---

## Task 2: `RollingRate` via TDD

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`

- [ ] **Step 1: Write the failing tests for `RollingRate`**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`:

```swift
import XCTest
@testable import VideoCoachCore

final class RollingRateTests: XCTestCase {
    func test_returnsNilWithFewerThanFiveSamples() {
        var r = RollingRate(windowSeconds: 30)
        // 4 samples spanning 4 seconds — count gate fails.
        for i in 0..<4 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i) * 1.5)
        }
        XCTAssertNil(r.compositionSecondsPerWallSecond())
    }

    func test_returnsNilBeforeTwoSecondsOfWallTimeElapsed() {
        var r = RollingRate(windowSeconds: 30)
        // 6 samples crammed into 1.0 seconds — sample-count gate passes
        // (≥5) but wall-time gate fails (<2s spread).
        for i in 0..<6 {
            r.record(wallTime: Double(i) * 0.2, encodedCompSeconds: Double(i) * 0.3)
        }
        XCTAssertNil(r.compositionSecondsPerWallSecond())
    }

    func test_returnsSteadyRateForEvenlySpacedSamples() {
        var r = RollingRate(windowSeconds: 30)
        // 10 samples, 1s apart, 1.5x rate (encoded grows 1.5 per wall sec).
        for i in 0..<10 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i) * 1.5)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 1.5, accuracy: 0.001)
    }

    func test_reflectsRateChangeAfterEvictionPastWindow() {
        var r = RollingRate(windowSeconds: 10)
        // 30 samples at 1s apart at 1.0x rate.
        for i in 0..<30 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i))
        }
        // 30 more samples at 1s apart at 3.0x rate. After these, samples
        // older than (current wallTime - 10) should evict.
        for i in 30..<60 {
            let prevEncoded = 30.0 + Double(i - 30) * 3.0
            r.record(wallTime: Double(i), encodedCompSeconds: prevEncoded)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        // Surviving window only has 3.0x-rate samples.
        XCTAssertEqual(rate!, 3.0, accuracy: 0.05)
    }

    func test_returnsZeroWhenEncodedSecondsConstant() {
        var r = RollingRate(windowSeconds: 30)
        // 10 samples over 10 seconds wall time; encoded stuck at 1.0.
        for i in 0..<10 {
            r.record(wallTime: Double(i), encodedCompSeconds: 1.0)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 0.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apple/VideoCoachCore && swift test --filter RollingRateTests`
Expected: 5 FAILS, all because `compositionSecondsPerWallSecond()` returns nil and `record(...)` is empty.

- [ ] **Step 3: Implement `RollingRate.record` and `compositionSecondsPerWallSecond`**

Replace the two method bodies in `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`:

```swift
public mutating func record(wallTime: Double, encodedCompSeconds: Double) {
    // Clamp encoded to non-decreasing — the AVFoundation `fractionCompleted`
    // briefly overshoots 1.0 near end-of-export and can also report stale
    // values immediately after the session transitions.
    let lastEncoded = samples.last?.encodedCompSeconds ?? 0
    let clampedEncoded = max(encodedCompSeconds, lastEncoded)
    samples.append(Sample(wallTime: wallTime, encodedCompSeconds: clampedEncoded))
    let cutoff = wallTime - windowSeconds
    while let first = samples.first, first.wallTime < cutoff {
        samples.removeFirst()
    }
}

public func compositionSecondsPerWallSecond() -> Double? {
    guard samples.count >= 5,
          let first = samples.first,
          let last = samples.last
    else { return nil }
    let wallSpan = last.wallTime - first.wallTime
    guard wallSpan >= 2.0 else { return nil }
    let encodedSpan = last.encodedCompSeconds - first.encodedCompSeconds
    return encodedSpan / wallSpan
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apple/VideoCoachCore && swift test --filter RollingRateTests`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift
git commit -m "feat(export): RollingRate window estimator with sufficiency gate"
```

---

## Task 3: `projectRun` via TDD

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`

- [ ] **Step 1: Write the failing tests for `projectRun`**

Append to `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift`:

```swift
final class ProjectRunTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_emptyItemsYieldEmptyProjection() {
        let p = projectRun(items: [], rate: 1.0, now: now)
        XCTAssertEqual(p.totalSecondsRemaining, 0)
        XCTAssertTrue(p.perItemRemaining.isEmpty)
        XCTAssertTrue(p.perItemDoneDate.isEmpty)
    }

    func test_allPendingQueueOrderMatchesProjectedDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(id: "a", displayName: "a.mp4", videoDurationSeconds: 10),
            VideoExportItem(id: "b", displayName: "b.mp4", videoDurationSeconds: 20),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 30),
        ]
        let p = projectRun(items: items, rate: 2.0, now: now)
        // Per-item wall time alone at rate 2.0× = duration / 2.
        XCTAssertEqual(p.perItemRemaining["a"]!, 5.0, accuracy: 0.001)
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        XCTAssertEqual(p.perItemRemaining["c"]!, 15.0, accuracy: 0.001)
        // Total = sum = 30.
        XCTAssertEqual(p.totalSecondsRemaining, 30.0, accuracy: 0.001)
        // Dates are cumulative — a finishes at +5, b at +15, c at +30.
        XCTAssertEqual(p.perItemDoneDate["a"]!, now.addingTimeInterval(5))
        XCTAssertEqual(p.perItemDoneDate["b"]!, now.addingTimeInterval(15))
        XCTAssertEqual(p.perItemDoneDate["c"]!, now.addingTimeInterval(30))
    }

    func test_oneActiveAndPendingHaveMonotonicDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(
                id: "a", displayName: "a.mp4",
                videoDurationSeconds: 10, status: .active(fractionCompleted: 0.5)
            ),
            VideoExportItem(id: "b", displayName: "b.mp4", videoDurationSeconds: 10),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 10),
        ]
        let p = projectRun(items: items, rate: 1.0, now: now)
        // Per-item wall time alone (NOT cumulative — see spec: "Sum of all
        // per-item remainings is `totalSecondsRemaining`").
        // active: (1-0.5)*10 / 1.0 = 5
        XCTAssertEqual(p.perItemRemaining["a"]!, 5.0, accuracy: 0.001)
        // b alone: 10 / 1.0 = 10
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        // c alone: 10 / 1.0 = 10
        XCTAssertEqual(p.perItemRemaining["c"]!, 10.0, accuracy: 0.001)
        // Total wall = 5 + 10 + 10 = 25
        XCTAssertEqual(p.totalSecondsRemaining, 25.0, accuracy: 0.001)
        // Dates are cumulative (a@+5, b@+15, c@+25) so they're monotonic.
        XCTAssertEqual(p.perItemDoneDate["a"]!, now.addingTimeInterval(5))
        XCTAssertEqual(p.perItemDoneDate["b"]!, now.addingTimeInterval(15))
        XCTAssertEqual(p.perItemDoneDate["c"]!, now.addingTimeInterval(25))
        XCTAssertLessThan(p.perItemDoneDate["a"]!, p.perItemDoneDate["b"]!)
        XCTAssertLessThan(p.perItemDoneDate["b"]!, p.perItemDoneDate["c"]!)
    }

    func test_doneItemsExcludedFromRemainingButKeptInDoneDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(
                id: "a", displayName: "a.mp4",
                videoDurationSeconds: 10,
                status: .done(encodeWallSeconds: 7, averageFps: 30)
            ),
            VideoExportItem(
                id: "b", displayName: "b.mp4",
                videoDurationSeconds: 10,
                status: .active(fractionCompleted: 0)
            ),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 10),
        ]
        let p = projectRun(items: items, rate: 1.0, now: now)
        XCTAssertNil(p.perItemRemaining["a"])
        // b active from 0 → (1-0)*10/1 = 10 alone
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        // c pending alone = 10
        XCTAssertEqual(p.perItemRemaining["c"]!, 10.0, accuracy: 0.001)
        XCTAssertEqual(p.totalSecondsRemaining, 20.0, accuracy: 0.001)
    }

    func test_rateZeroOrNegativeFallsBackToOne() {
        let items = [VideoExportItem(id: "a", displayName: "a.mp4", videoDurationSeconds: 10)]
        // rate of 0 would divide-by-zero; the function must guard.
        let pZero = projectRun(items: items, rate: 0, now: now)
        XCTAssertEqual(pZero.perItemRemaining["a"]!, 10.0, accuracy: 0.001)
        let pNeg = projectRun(items: items, rate: -5, now: now)
        XCTAssertEqual(pNeg.perItemRemaining["a"]!, 10.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apple/VideoCoachCore && swift test --filter ProjectRunTests`
Expected: 5 FAILS, all asserting non-empty results when `projectRun` currently returns `.empty`.

- [ ] **Step 3: Implement `projectRun`**

Replace the `projectRun` body in `apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift`:

```swift
public func projectRun(
    items: [VideoExportItem],
    rate: Double,
    now: Date
) -> RunProjection {
    let safeRate = rate > 0 ? rate : 1.0
    var perItemRemaining: [String: Double] = [:]
    var perItemDoneDate: [String: Date] = [:]
    var cumulative = 0.0

    for item in items {
        switch item.status {
        case .done:
            continue
        case .active(let fraction):
            let frac = Double(max(0, min(1, fraction)))
            let wallRemaining = (1.0 - frac) * item.videoDurationSeconds / safeRate
            cumulative += wallRemaining
            perItemRemaining[item.id] = wallRemaining
            perItemDoneDate[item.id] = now.addingTimeInterval(cumulative)
        case .pending:
            let wallRemaining = item.videoDurationSeconds / safeRate
            cumulative += wallRemaining
            perItemRemaining[item.id] = wallRemaining
            perItemDoneDate[item.id] = now.addingTimeInterval(cumulative)
        }
    }

    return RunProjection(
        totalSecondsRemaining: cumulative,
        perItemRemaining: perItemRemaining,
        perItemDoneDate: perItemDoneDate
    )
}
```

Semantics:
- `perItemRemaining[id]` = wall-time this video alone takes (active = remaining encode, pending = full encode). Per spec, "Sum of all per-item remainings is `totalSecondsRemaining`".
- `perItemDoneDate[id]` = `now + cumulative` where cumulative includes all preceding active/pending wall time plus this item's own.
- Done items appear in neither map.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apple/VideoCoachCore && swift test --filter ProjectRunTests`
Expected: 5/5 PASS.

- [ ] **Step 5: Run the full VideoCoachCore test suite to catch regressions**

Run: `cd apple/VideoCoachCore && swift test`
Expected: all tests pass (≥124 with the 10 new ones).

- [ ] **Step 6: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/ExportProgress.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ExportProgressTests.swift
git commit -m "feat(export): projectRun pure-function for run-level projections"
```

---

## Task 4: `CompilationExporter.export` gets `onProgress` + detached sampler

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift`

- [ ] **Step 1: Add `onProgress` parameter to `export(...)` and remove `progress(of:)`**

In `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift`:

Replace the `export(...)` signature header (around line 82–92) with:

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
    onProgress: (@Sendable (Float) -> Void)? = nil
) async throws {
```

Then, in the same file, locate the section labeled `// ── Step 4: Configure and run the AVAssetExportSession.` (around line 402). Just before the `await exportSession.export()` call, insert the sampler:

```swift
        // Spawn the progress sampler. `Task.detached` (NOT `Task { }` or
        // `async let`) is required: `CompilationExporter` is a `public actor`,
        // and a non-detached child task would inherit actor isolation and
        // serialize with `exportSession.export()` instead of running in
        // parallel.
        //
        // `defer { samplerTask.cancel() }` guarantees the sampler stops on
        // every exit path (success, throw, status check failure), so a
        // stale tick can't land in `ExportSheet` after the next video has
        // already started.
        let samplerTask: Task<Void, Never>?
        if let onProgress {
            let session = exportSession
            samplerTask = Task.detached {
                while !Task.isCancelled {
                    let status = session.status
                    let value = session.progress
                    onProgress(value)
                    if status == .completed || status == .failed || status == .cancelled {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // 5Hz
                }
            }
        } else {
            samplerTask = nil
        }
        defer { samplerTask?.cancel() }
```

Then, remove the now-unused `progress(of:)` method entirely (it currently lives around lines 459–480 — the whole `public nonisolated func progress(of session:...) -> AsyncStream<Float>` declaration and body).

Also update the doc-comment block at the top of the file (around lines 38–43) — strike the paragraph about `progress(of:)` since it's gone:

Replace:

```swift
/// `export(...)` runs to completion and throws on failure. Callers that want
/// progress observation should call ``progress(of:)`` in parallel after
/// retrieving the underlying `AVAssetExportSession` — but for v1 the API
/// hides the session and the smoke test does not need progress.
```

With:

```swift
/// `export(...)` runs to completion and throws on failure. Callers that want
/// live progress pass an `onProgress` closure; the exporter polls
/// `AVAssetExportSession.progress` at 5Hz from a detached task and forwards
/// the fraction to the closure on whatever queue the closure was created on
/// (typically MainActor via `await MainActor.run { … }` in the closure body).
```

- [ ] **Step 2: Verify the package still builds and existing tests pass**

Run: `cd apple/VideoCoachCore && swift test`
Expected: all tests pass. The exporter changes are additive; the existing `CompilationExporterTests` and `CompilationExporterE2ETests` don't pass `onProgress` and should continue working unchanged.

- [ ] **Step 3: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift
git commit -m "feat(export): onProgress callback with detached 5Hz sampler"
```

---

## Task 5: ExportSheet — state machine wiring

**Files:**
- Modify: `apple/App/Export/ExportSheet.swift`

This task introduces the new state fields, builds the `items` list at run start, transitions item statuses around each `export(...)` call, and computes a fresh `ExportProgress` snapshot on every sampler tick. The UI itself still uses the existing (now visibly inadequate) `progressSection`; Task 6 rewrites it.

- [ ] **Step 1: Add the new state fields and supporting properties**

In `apple/App/Export/ExportSheet.swift`, immediately after the existing `@State private var summary: Summary?` declaration (around line 44), insert:

```swift
    // New per-run state for the per-video progress UI.
    @State private var items: [VideoExportItem] = []
    @State private var runRate = RollingRate(windowSeconds: 30)
    @State private var runStartedAt: Date? = nil
    @State private var currentVideoStartedAt: Date? = nil
    @State private var projection: RunProjection = .empty
    @State private var lastSnapshot: ExportProgress? = nil

    /// Frame rate of the export's video composition. Read once per run from
    /// the exporter's internal `videoComp.frameDuration` (currently 1/30).
    /// Hard-coded here because the exporter doesn't expose it, and the value
    /// is stable across today's code. If the exporter ever varies frame rate
    /// per export, surface it via the `onProgress` closure or a separate
    /// callback.
    private static let outputFrameRate: Double = 30
```

- [ ] **Step 2: Build the `items` list when the run starts**

In the `startExport()` method, locate the line that initializes the `RunState` (around line 381):

```swift
        run = RunState(totalCount: chosenTags.count, completedCount: 0, currentTag: chosenTags.first)
```

Insert immediately before that line:

```swift
        // Build the per-video item list now so the UI has rows from the
        // very first frame. Each entry's `videoDurationSeconds` comes from
        // the plan that will be built inside the Task. We pre-compute it
        // here from the project state — it's a sum we already know how to
        // compute, and it's cheap.
        let plans: [(key: String, plan: CompilationPlan)] = chosenTags.compactMap { tagKey -> (String, CompilationPlan)? in
            // Empty plans get skipped in the loop; mirror that here so they
            // don't appear as zero-second items.
            let plan: CompilationPlan
            if tagKey == Self.allClipsKey {
                plan = workspace.project.allClipsCompilationPlan(
                    sourceDurations: workspace.project.sourceDurationsMap
                )
            } else {
                plan = workspace.project.compilationPlan(
                    for: tagKey,
                    sourceDurations: workspace.project.sourceDurationsMap
                )
            }
            return plan.entries.isEmpty ? nil : (tagKey, plan)
        }

        items = plans.map { tagKey, plan in
            VideoExportItem(
                id: tagKey,
                displayName: "\(sanitizeFilename(displayLabel(forKey: tagKey)))",
                videoDurationSeconds: plan.totalDurationSeconds
            )
        }
        runRate = RollingRate(windowSeconds: 30)
        runStartedAt = Date()
        currentVideoStartedAt = nil
        projection = .empty
        lastSnapshot = nil
```

This references `workspace.project.sourceDurationsMap`. If that helper doesn't exist on `Project`, build the dictionary inline instead:

```swift
        let sourceDurations: [Int: Double] = Dictionary(
            uniqueKeysWithValues: workspace.project.sourceVideos.enumerated().map { i, ref in
                (i, ref.durationSeconds)
            }
        )
```

…and substitute `sourceDurations` for `workspace.project.sourceDurationsMap` in the two `compilationPlan(...)` calls above. Use whichever already exists in the codebase — `Project.swift` will reveal it on inspection. (If both exist, prefer the typed helper.)

- [ ] **Step 3: Add the per-sample state updater**

Add this method to `ExportSheet` (next to the other private methods, e.g., right before `// MARK: - Asset wiring` around line 467):

```swift
    /// Updates the active item's fraction, records a rate sample, recomputes
    /// the projection, and rebuilds `lastSnapshot`. Called from the
    /// `onProgress` callback on MainActor.
    private func handleSampleFromActiveVideo(_ fraction: Float) {
        guard let activeIdx = items.firstIndex(where: { isActive($0.status) }) else {
            return
        }
        let clamped = max(0, min(1, fraction))
        items[activeIdx].status = .active(fractionCompleted: clamped)

        let activeDur = items[activeIdx].videoDurationSeconds
        let doneEncoded = items.reduce(0.0) { acc, item in
            if case .done = item.status {
                return acc + item.videoDurationSeconds
            }
            return acc
        }
        let activeEncoded = Double(clamped) * activeDur
        let encodedSoFar = doneEncoded + activeEncoded
        let wallNow = Date().timeIntervalSince1970
        runRate.record(wallTime: wallNow, encodedCompSeconds: encodedSoFar)

        rebuildSnapshot()
    }

    private func isActive(_ status: VideoExportItem.Status) -> Bool {
        if case .active = status { return true } else { return false }
    }

    /// Recompute `projection` and `lastSnapshot` from current `items` +
    /// `runRate`. Separate from `handleSampleFromActiveVideo` so transition
    /// points (start of a video, end of a video) can refresh the UI without
    /// inventing a fake sample.
    private func rebuildSnapshot() {
        let measured = runRate.compositionSecondsPerWallSecond()
        let rate = measured ?? 1.0
        let now = Date()
        let proj = projectRun(items: items, rate: rate, now: now)
        let fps = measured.map { $0 * Self.outputFrameRate }
        // Composition-seconds remaining is rate-INDEPENDENT — it's the
        // remaining video content the encoder still has to chew through.
        // Use it for the "X video left" reading.
        let compSecondsRemaining: Double = items.reduce(0.0) { acc, item in
            switch item.status {
            case .done:                       return acc
            case .pending:                    return acc + item.videoDurationSeconds
            case .active(let frac):           return acc + (1.0 - Double(frac)) * item.videoDurationSeconds
            }
        }
        let etaSecs = measured == nil ? nil : proj.totalSecondsRemaining
        let doneDate = measured == nil ? nil : now.addingTimeInterval(proj.totalSecondsRemaining)
        projection = proj
        lastSnapshot = ExportProgress(
            items: items,
            currentRenderingFps: fps,
            totalVideoSecondsRemaining: compSecondsRemaining,
            totalEtaSeconds: etaSecs,
            projectedCompletionDate: doneDate
        )
    }
```

- [ ] **Step 4: Wire transitions and `onProgress` into the per-output loop**

In `startExport()`, find the per-tag loop (currently around lines 395–441). Replace its body with the transition-aware version. The *outer* shape of the loop stays the same:

```swift
                for (i, tagKey) in chosenTags.enumerated() {
                    await MainActor.run {
                        run = RunState(
                            totalCount: chosenTags.count,
                            completedCount: i,
                            currentTag: tagKey
                        )
                    }

                    let plan: CompilationPlan
                    if tagKey == Self.allClipsKey {
                        plan = workspace.project.allClipsCompilationPlan(
                            sourceDurations: context.sourceDurations
                        )
                    } else {
                        plan = workspace.project.compilationPlan(
                            for: tagKey,
                            sourceDurations: context.sourceDurations
                        )
                    }

                    guard !plan.entries.isEmpty else { continue }

                    let label = displayLabel(forKey: tagKey)
                    let filename = "\(sanitizeFilename(label)) - \(sanitizeFilename(projectNameChoice)).mp4"
                    let outputURL = outFolder.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: outputURL)

                    // Transition the matching item to .active and record
                    // its start time. The item index in `items` may differ
                    // from `i` because empty-plan tags don't appear in
                    // `items`; find it by id.
                    await MainActor.run {
                        if let idx = items.firstIndex(where: { $0.id == tagKey }) {
                            items[idx].status = .active(fractionCompleted: 0)
                        }
                        currentVideoStartedAt = Date()
                        rebuildSnapshot()
                    }

                    try await exporter.export(
                        plan: plan,
                        clipsByID: context.clipsByID,
                        sourceAssets: context.sourceAssets,
                        clipWebcamAssets: context.clipWebcamAssets,
                        outputURL: outputURL,
                        resolution: resolutionChoice,
                        quality: qualityChoice,
                        sourceVolume: workspace.project.preferences.previewSourceVolume,
                        commentaryVolume: workspace.project.preferences.previewCommentaryVolume,
                        onProgress: { fraction in
                            Task { @MainActor in
                                handleSampleFromActiveVideo(fraction)
                            }
                        }
                    )

                    // Transition .active → .done with the measured wall
                    // time and the (post-hoc) average FPS for this video.
                    await MainActor.run {
                        if let idx = items.firstIndex(where: { $0.id == tagKey }),
                           let startedAt = currentVideoStartedAt {
                            let wall = Date().timeIntervalSince(startedAt)
                            let dur = items[idx].videoDurationSeconds
                            // avgFps = (composition seconds / wall seconds) * frame rate
                            let avgFps = wall > 0 ? (dur / wall) * Self.outputFrameRate : 0
                            items[idx].status = .done(encodeWallSeconds: wall, averageFps: avgFps)
                        }
                        currentVideoStartedAt = nil
                        rebuildSnapshot()
                    }
                }
```

Notes for the implementer:
- The `Task { @MainActor in handleSampleFromActiveVideo(fraction) }` form bounces the detached sampler's fraction back to the main actor so the `@State` mutations stay safe. Sub-millisecond ordering across ticks isn't important; the most recent fraction always wins.
- `context.sourceDurations` is supplied by `buildExportContext(...)` — already in scope inside the Task. The Step 2 code uses a different source-durations dictionary (built from `workspace.project.sourceVideos`) because Step 2 runs on the main actor before the Task starts and doesn't have `context` yet. Both maps contain the same data; they're built from the same project state.

- [ ] **Step 5: Verify the app still builds and existing exports still run**

Run: `cd apple && xcodebuild -scheme App -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

If any compile error references `sourceDurationsMap` not existing on `Project`, use the inline `sourceDurations` dictionary from Step 2's note.

- [ ] **Step 6: Commit**

```bash
git add apple/App/Export/ExportSheet.swift
git commit -m "feat(export): per-video item state machine in ExportSheet"
```

---

## Task 6: ExportSheet — UI rewrite

**Files:**
- Modify: `apple/App/Export/ExportSheet.swift`

- [ ] **Step 1: Replace `progressSection` with the per-video list**

In `apple/App/Export/ExportSheet.swift`, replace the entire current `progressSection` computed property (around lines 258–273) with:

```swift
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            runSummary
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    videoRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var runSummary: some View {
        let doneCount = items.reduce(0) { acc, item in
            if case .done = item.status { return acc + 1 }
            return acc
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exporting (\(doneCount) of \(items.count) videos done)")
                    .font(.headline)
                Spacer()
                if let fps = lastSnapshot?.currentRenderingFps {
                    Text("\(Int(fps.rounded())) fps")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(runSummaryLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The "1:08 video left · ETA 1:25 (3:42 PM)" line under the headline.
    /// Falls back gracefully when the rate hasn't stabilized yet — just the
    /// total video remaining, no ETA, no clock.
    private var runSummaryLine: String {
        let totalLeft = lastSnapshot?.totalVideoSecondsRemaining ?? items.reduce(0.0) { acc, item in
            switch item.status {
            case .done: return acc
            case .active, .pending: return acc + item.videoDurationSeconds
            }
        }
        var parts: [String] = ["\(formatDuration(totalLeft)) video left"]
        if let etaSecs = lastSnapshot?.totalEtaSeconds,
           let doneDate = lastSnapshot?.projectedCompletionDate {
            parts.append("ETA \(formatDuration(etaSecs)) (\(Self.clockFormatter.string(from: doneDate)))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func videoRow(_ item: VideoExportItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Status pill — small, fixed-width label so rows align.
            Text(statusPill(item.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(item.displayName)
                .font(.callout.weight(.medium))
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
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

    private func statusPill(_ status: VideoExportItem.Status) -> String {
        switch status {
        case .pending: return "Pending"
        case .active:  return "Active"
        case .done:    return "Done"
        }
    }

    @ViewBuilder
    private func pendingDetail(_ item: VideoExportItem) -> some View {
        // `perItemRemaining[id]` is this video's encode time alone (per-item,
        // not cumulative — see Task 3 spec). Use it directly.
        let encodeOnly = projection.perItemRemaining[item.id] ?? item.videoDurationSeconds
        let doneDateString: String
        if let date = projection.perItemDoneDate[item.id], lastSnapshot?.currentRenderingFps != nil {
            doneDateString = " · done \(Self.clockFormatter.string(from: date))"
        } else {
            doneDateString = ""
        }
        Text("\(formatDuration(item.videoDurationSeconds)) video · ~\(formatDuration(encodeOnly)) to encode\(doneDateString)")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func activeDetail(_ item: VideoExportItem, fraction: Float) -> some View {
        let videoLeft = max(0, (1.0 - Double(fraction)) * item.videoDurationSeconds)
        let wallLeft = projection.perItemRemaining[item.id] ?? 0
        let fpsText: String
        if let fps = lastSnapshot?.currentRenderingFps {
            fpsText = "\(Int(fps.rounded())) fps · "
        } else {
            fpsText = ""
        }
        let etaText: String
        if let date = projection.perItemDoneDate[item.id], lastSnapshot?.currentRenderingFps != nil {
            etaText = " · ETA \(formatDuration(wallLeft)) (\(Self.clockFormatter.string(from: date)))"
        } else {
            etaText = ""
        }
        Text("\(fpsText)\(formatDuration(videoLeft)) video left\(etaText)")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func doneDetail(_ item: VideoExportItem, encodeWall: Double, avgFps: Double) -> some View {
        Text("✓ \(formatDuration(item.videoDurationSeconds)) video · \(formatDuration(encodeWall)) encode · avg \(Int(avgFps.rounded())) fps")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Short, locale-sensitive clock-time formatter (e.g., "3:42 PM" in
    /// en_US, "15:42" in fr_FR). One per type — recreating a DateFormatter
    /// per row would be wasteful.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
```

Note: the existing `formatDuration(_:)` lives module-internal in `apple/App/Views/ClipSidebar.swift` and renders `M:SS`. We reuse it as-is (same module).

- [ ] **Step 2: Verify the app builds**

Run: `cd apple && xcodebuild -scheme App -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual smoke test — run an export and watch the sheet**

The user runs the freshly built binary directly via DerivedData:

```bash
ls -1t ~/Library/Developer/Xcode/DerivedData/App-*/Build/Products/Debug/App.app 2>/dev/null | head -1
```

Then launches the produced `App.app`. Open a project with ≥2 tags, click Export, check all tags, click Export. Verify:
- Each video starts as Pending with `<duration> video · ~<estimate> to encode` (clock time may be absent for ~2s).
- One video transitions to Active with a moving progress bar and `<fps> fps · <video-left> video left · ETA <wall-left> (<clock>)`.
- Pending rows update their projected clock times as the rate stabilizes.
- Finished videos flip to Done with `✓ <video-duration> · <encode-wall> encode · avg <fps>`.
- Top summary's `X of Y videos done` and the `<total-left> video left · ETA <wall> (<clock>)` line update on every tick.

If any reading is wildly wrong (negative durations, NaN ETAs, clock time in the wrong format), inspect the relevant `*Detail(_:)` builder.

- [ ] **Step 4: Commit**

```bash
git add apple/App/Export/ExportSheet.swift
git commit -m "feat(export): per-video progress UI with summary + ETA + clock"
```

---

## Task 7: Remove the now-stale doc comment on `ExportSheet`

**Files:**
- Modify: `apple/App/Export/ExportSheet.swift:14-20`

The class-level doc comment claims live progress is deferred and `progress(of:)` exists. Both statements are now wrong after Tasks 4 and 6.

- [ ] **Step 1: Replace the outdated doc paragraph**

In `apple/App/Export/ExportSheet.swift`, replace the comment block (around lines 14–20):

```swift
/// **Live progress is deferred.** ``CompilationExporter.progress(of:)`` takes
/// an `AVAssetExportSession`, but `export(...)` doesn't expose the underlying
/// session, so we'd need a wider API change to wire a real progress bar. For
/// v1 we show "Exporting <tag> (N of M)…" with an indeterminate spinner; if
/// users want a real bar we'll change the exporter API in a follow-up.
```

with:

```swift
/// **Live progress.** ``CompilationExporter.export(...)`` accepts an
/// `onProgress: (Float) -> Void` closure that fires at ~5Hz from a detached
/// task during each export. `ExportSheet` threads each tick through
/// ``handleSampleFromActiveVideo(_:)`` to update the active item's
/// fraction, feed the run-level ``RollingRate``, and re-project the run.
```

- [ ] **Step 2: Verify the app builds**

Run: `cd apple && xcodebuild -scheme App -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add apple/App/Export/ExportSheet.swift
git commit -m "docs(export): refresh ExportSheet header now that progress is live"
```

---

## Self-Review

**Spec coverage check** — each spec section maps to:
- Data model (`VideoExportItem`, `ExportProgress`, `RunProjection`) → Task 1.
- `RollingRate` (5-sample + 2s gate, eviction) → Task 2.
- `projectRun` (active/pending/done branches, rate fallback) → Task 3.
- Exporter `onProgress` + detached sampler + removal of `progress(of:)` → Task 4.
- ExportSheet state additions (`items`, `runRate`, `runStartedAt`, etc.) → Task 5 Step 1.
- Run-start initialization of `items` → Task 5 Step 2.
- `handleSampleFromActiveVideo` → Task 5 Step 3.
- Transitions on video start/complete around `export(...)` → Task 5 Step 4.
- `progressSection` rewrite, `runSummary`, `videoRow`, three detail builders → Task 6 Step 1.
- Clock-time formatter → Task 6 Step 1 (`clockFormatter`).
- Unit tests for both helpers → Tasks 2 & 3.
- Manual UI verification → Task 6 Step 3.
- Stale doc cleanup → Task 7.

**Type-name consistency**: `VideoExportItem`, `ExportProgress`, `RollingRate`, `RunProjection`, `projectRun`, `handleSampleFromActiveVideo`, `rebuildSnapshot`, `outputFrameRate`, `clockFormatter` — all used identically across tasks.

**No placeholders**: every step has either runnable Swift, a concrete shell command, or a clearly-bounded edit instruction with the surrounding context to find it.
