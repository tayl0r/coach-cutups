# Preview Playback Performance: Skip Coalescing + GPU Compositor

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Two-part fix for sluggish 4K-source clip preview: (1) coalesce rapid FF/RW skip presses into a single in-flight seek with keyframe-tolerant tracking and exact-frame settle on burst end; (2) replace the per-frame CPU `CIImage→CGImage→CGContext.draw` path in `PreviewCompositor` with a GPU-resident `CIContext.render(_:to:)` pipeline and clamp preview `renderSize`.

**Architecture:**
- New pure-logic `SkipCoordinator` in `VideoCoachCore` (no AVFoundation deps). Caller (`ContentView`) feeds it events, applies the returned commands to `AVPlayer`, owns a single debounce `Task`.
- `PreviewCompositor` rewritten to compose source + webcam as a `CIImage` graph and render directly into the output `CVPixelBuffer` via `CIContext.render(_:to:)`. No CGContext, no pixel-buffer locks, no per-frame allocations.
- `ClipPreviewBuilder` clamps `videoComposition.renderSize` for preview to a max of 1920×1080 (longest side preserved). Export path is untouched.
- `PreviewCompositor` and `PreviewInstruction` move from `App/Preview/` into `VideoCoachCore` so they're reachable from XCTest. App-side imports updated.

**Tech Stack:** Swift 5.9, macOS 14, AVFoundation, CoreImage, CoreVideo, XCTest, SwiftPM.

**Test commands:**
- `cd VideoCoachCore && swift test --filter SkipCoordinatorTests` — Phase 1 unit tests
- `cd VideoCoachCore && swift test --filter PreviewCompositorTests` — Phase 3 pixel tests
- `./scripts/run.sh` — manual smoke (Phase 2 + Phase 3 visual)

---

## Phase 1 — `SkipCoordinator` (pure, in `VideoCoachCore`)

### State machine (target behavior)

`SkipCoordinator` holds three pieces of state:

| Field        | Type      | Meaning                                                                 |
|--------------|-----------|-------------------------------------------------------------------------|
| `target`     | `Double?` | Latest user-intended position (seconds). nil ⇒ idle.                     |
| `flying`     | `Double?` | Position the in-flight `AVPlayer.seek` is heading to. nil ⇒ no seek out. |
| `flyingExact`| `Bool`    | Whether the in-flight seek was issued with `.zero` tolerance.            |
| `exactPending`| `Bool`   | Burst-ended while a coarse seek was in flight; settle exact on completion. |

Three event entry points, each returning a `SkipDecision`:

- `requestSkip(deltaSeconds:currentPlayerTimeSeconds:clipDurationSeconds:nowMonotonicSeconds:)` — user pressed FF/RW.
- `seekCompleted(nowMonotonicSeconds:)` — `AVPlayer.seek`'s completion handler fired (regardless of `finished`).
- `burstEnded(nowMonotonicSeconds:)` — the caller's debounce timer fired.

`SkipDecision` carries up to two side-effect commands the caller must perform:

```swift
public struct SkipDecision: Equatable, Sendable {
    public let seek: SeekParams?           // perform AVPlayer.seek with these
    public let armDebounceSeconds: Double? // cancel prior debounce, schedule new
}
public struct SeekParams: Equatable, Sendable {
    public let targetSeconds: Double
    public let exact: Bool                 // false ⇒ keyframe-tolerant
}
```

#### Transitions

`requestSkip(delta, current, dur, now)`:
1. `base = target ?? current`
2. `t = clamp(base + delta, 0, dur)`
3. `target = t`; `exactPending = false` *(burst is alive again)*
4. If `flying == nil`: `flying = t`; `flyingExact = false`; **return** `seek(t, exact: false) + armDebounce(burstWindow)`
5. Else *(seek already flying)*: **return** `armDebounce(burstWindow)` only

`burstEnded(now)`:
- If `flying == nil` and `target != nil`: `flying = target`; `flyingExact = true`; clear `target`; **return** `seek(flying!, exact: true)`
- Else if `flying != nil`: `exactPending = true`; **return** nothing
- Else: **return** nothing

`seekCompleted(now)`:
- Capture `landedTarget = flying`, `landedExact = flyingExact`.
- `flying = nil`.
- **If `exactPending`**:
  - Clear `exactPending` *(unconditional — never leave the flag stuck regardless of whether `target` is consumable).*
  - If `target != nil`: `flying = target`; `flyingExact = true`; clear `target`; **return** `seek(flying!, exact: true)`.
  - Else: **return** nothing *(defensive — should not normally happen; documented invariant: target is non-nil whenever exactPending is set, but we don't rely on it).*
- Else if `landedExact == false && target != nil && target != landedTarget` *(stale; new skips arrived during flight)*: `flying = target`; `flyingExact = false`; **return** `seek(flying!, exact: false)`.
- Else if `landedExact == true`: clear `target`; **return** nothing *(already settled)*.
- Else *(landed coarse on the right target, no new skips, no burst end yet — debounce will fire later)*: **return** nothing.

`burstWindow` is a constructor parameter, default 0.15s.

**Concurrency:** `SkipCoordinator` is annotated `@MainActor`. All callers (the SwiftUI `ContentView` handlers and the `Task { @MainActor }` wrappers around AVPlayer's seek-completion bounce) are already on the main actor. Tests in `SkipCoordinatorTests` annotate each test method `@MainActor`. This matches the existing `@Observable @MainActor` pattern used by `Workspace`.

---

### Task 1.1: Skeleton + first happy-path test

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/SkipCoordinator.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/SkipCoordinatorTests.swift`

**Step 1: Write the failing test.**

```swift
// SkipCoordinatorTests.swift
import XCTest
@testable import VideoCoachCore

@MainActor
final class SkipCoordinatorTests: XCTestCase {
    func test_singleSkip_firesCoarseSeekAndArmsDebounce() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        let d = c.requestSkip(
            deltaSeconds: 3.0,
            currentPlayerTimeSeconds: 10.0,
            clipDurationSeconds: 60.0,
            nowMonotonicSeconds: 100.0
        )
        XCTAssertEqual(d.seek, SeekParams(targetSeconds: 13.0, exact: false))
        XCTAssertEqual(d.armDebounceSeconds, 0.15)
    }
}
```

**Step 2: Run, expect compile failure / unknown symbol.**

```
cd VideoCoachCore
swift test --filter SkipCoordinatorTests/test_singleSkip_firesCoarseSeekAndArmsDebounce
```
Expected: build failure ("cannot find 'SkipCoordinator' in scope").

**Step 3: Implement minimal types + `requestSkip` happy path.**

```swift
// SkipCoordinator.swift
import Foundation

public struct SeekParams: Equatable, Sendable {
    public let targetSeconds: Double
    public let exact: Bool
    public init(targetSeconds: Double, exact: Bool) {
        self.targetSeconds = targetSeconds
        self.exact = exact
    }
}

public struct SkipDecision: Equatable, Sendable {
    public let seek: SeekParams?
    public let armDebounceSeconds: Double?
    public init(seek: SeekParams? = nil, armDebounceSeconds: Double? = nil) {
        self.seek = seek
        self.armDebounceSeconds = armDebounceSeconds
    }
    public static let none = SkipDecision()
}

@MainActor
public final class SkipCoordinator {
    private let burstWindow: Double
    private var target: Double?
    private var flying: Double?
    private var flyingExact: Bool = false
    private var exactPending: Bool = false

    public init(burstWindowSeconds: Double = 0.15) {
        self.burstWindow = burstWindowSeconds
    }

    public func requestSkip(
        deltaSeconds: Double,
        currentPlayerTimeSeconds: Double,
        clipDurationSeconds: Double,
        nowMonotonicSeconds: TimeInterval
    ) -> SkipDecision {
        let base = target ?? currentPlayerTimeSeconds
        let t = min(max(base + deltaSeconds, 0), clipDurationSeconds)
        target = t
        exactPending = false
        if flying == nil {
            flying = t
            flyingExact = false
            return SkipDecision(seek: .init(targetSeconds: t, exact: false),
                                armDebounceSeconds: burstWindow)
        }
        return SkipDecision(armDebounceSeconds: burstWindow)
    }

    public func seekCompleted(nowMonotonicSeconds: TimeInterval) -> SkipDecision { .none }
    public func burstEnded(nowMonotonicSeconds: TimeInterval) -> SkipDecision { .none }

    /// Used when the active player swaps; full reset.
    public func reset() {
        target = nil; flying = nil; flyingExact = false; exactPending = false
    }
}
```

**Step 4: Run, expect pass.**
```
cd VideoCoachCore && swift test --filter SkipCoordinatorTests/test_singleSkip_firesCoarseSeekAndArmsDebounce
```
Expected: 1 passing.

**Step 5: Commit.**
```bash
git add VideoCoachCore/Sources/VideoCoachCore/SkipCoordinator.swift \
        VideoCoachCore/Tests/VideoCoachCoreTests/SkipCoordinatorTests.swift
git commit -m "feat(core): SkipCoordinator skeleton with single-skip path"
```

---

### Task 1.2: Coalescing — second skip during in-flight is arm-only and accumulates

**Files:** Modify `SkipCoordinatorTests.swift` (add test).

**Step 1: Failing test.**
```swift
func test_secondSkipDuringFlight_accumulatesAndArmsOnly() {
    let c = SkipCoordinator(burstWindowSeconds: 0.15)
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 100)
    let d2 = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                          clipDurationSeconds: 60, nowMonotonicSeconds: 100.05)
    XCTAssertNil(d2.seek)                          // no new seek issued
    XCTAssertEqual(d2.armDebounceSeconds, 0.15)    // debounce re-armed
}

func test_secondSkipDuringFlight_targetAccumulatesNotResetsToCurrent() {
    let c = SkipCoordinator()
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 100)
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 100.05)
    // Now in-flight seek lands; coordinator should refire to t=16, not t=13.
    let after = c.seekCompleted(nowMonotonicSeconds: 100.10)
    XCTAssertEqual(after.seek, SeekParams(targetSeconds: 16.0, exact: false))
}
```

**Step 2: Run, expect first test passes (skeleton already covers it), second test fails because `seekCompleted` returns `.none`.**

**Step 3: Implement `seekCompleted`'s stale-target refire branch.**

Replace the `seekCompleted` body with the full transition logic (omitting `exactPending` branches for now — leave a TODO; tests for those land in 1.4/1.5):

```swift
public func seekCompleted(nowMonotonicSeconds: TimeInterval) -> SkipDecision {
    let landedTarget = flying
    let landedExact = flyingExact
    flying = nil
    // Stale target → refire coarse to the latest.
    if !landedExact, let tgt = target, tgt != landedTarget {
        flying = tgt
        flyingExact = false
        return SkipDecision(seek: .init(targetSeconds: tgt, exact: false))
    }
    // Landed coarse on the same target the user wanted; debounce will fire exact.
    return .none
}
```

**Step 4: Run, expect both new tests pass.**

**Step 5: Commit.**
```bash
git commit -am "feat(core): coalesce in-flight skips and refire on stale completion"
```

---

### Task 1.3: Burst-end → exact settle when no seek is flying

**Files:** Modify `SkipCoordinatorTests.swift`.

**Step 1: Failing test.**
```swift
func test_burstEnded_afterSeekLanded_firesExactSeek() {
    let c = SkipCoordinator(burstWindowSeconds: 0.15)
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 100)
    _ = c.seekCompleted(nowMonotonicSeconds: 100.05) // coarse landed quickly
    let burst = c.burstEnded(nowMonotonicSeconds: 100.15)
    XCTAssertEqual(burst.seek, SeekParams(targetSeconds: 13.0, exact: true))
    XCTAssertNil(burst.armDebounceSeconds)
}
```

**Step 2: Run, expect failure (`burstEnded` still returns `.none`).**

**Step 3: Implement `burstEnded` no-flight branch.**
```swift
public func burstEnded(nowMonotonicSeconds: TimeInterval) -> SkipDecision {
    if flying == nil, let t = target {
        flying = t
        flyingExact = true
        target = nil
        return SkipDecision(seek: .init(targetSeconds: t, exact: true))
    }
    if flying != nil {
        exactPending = true
    }
    return .none
}
```

**Step 4: Run, expect pass.**
**Step 5: Commit.**
```bash
git commit -am "feat(core): SkipCoordinator burst-end exact settle when idle"
```

---

### Task 1.4: Burst ends mid-flight → `exactPending` causes exact refire on completion

**Files:** Modify `SkipCoordinatorTests.swift`.

**Step 1: Failing test.**
```swift
func test_burstEndedDuringFlight_thenSeekCompletes_firesExactSeek() {
    let c = SkipCoordinator(burstWindowSeconds: 0.15)
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 100)
    let mid = c.burstEnded(nowMonotonicSeconds: 100.15) // coarse seek still flying
    XCTAssertNil(mid.seek)
    let done = c.seekCompleted(nowMonotonicSeconds: 100.30)
    XCTAssertEqual(done.seek, SeekParams(targetSeconds: 13.0, exact: true))
}
```

**Step 2: Run, expect failure.**

**Step 3: Add the `exactPending` branch at the top of `seekCompleted`.** Crucially, clear `exactPending` *unconditionally* on entry to its branch so the flag never gets stuck if `target` happens to be nil (defensive — see review note in the state-machine section).

```swift
public func seekCompleted(nowMonotonicSeconds: TimeInterval) -> SkipDecision {
    let landedTarget = flying
    let landedExact = flyingExact
    flying = nil
    if exactPending {
        exactPending = false
        if let t = target {
            flying = t; flyingExact = true
            target = nil
            return SkipDecision(seek: .init(targetSeconds: t, exact: true))
        }
        return .none
    }
    if landedExact { target = nil; return .none }
    if let tgt = target, tgt != landedTarget {
        flying = tgt; flyingExact = false
        return SkipDecision(seek: .init(targetSeconds: tgt, exact: false))
    }
    return .none
}
```

**Step 4: Run, expect all SkipCoordinator tests pass.**
**Step 5: Commit.**
```bash
git commit -am "feat(core): SkipCoordinator settles exact when burst ended mid-flight"
```

---

### Task 1.5: Edge cases — clamping + reset

**Files:** Modify `SkipCoordinatorTests.swift`.

**Step 1: Failing tests.**
```swift
func test_skipBeforeZero_clampsToZero() {
    let c = SkipCoordinator()
    let d = c.requestSkip(deltaSeconds: -10, currentPlayerTimeSeconds: 3,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 0)
    XCTAssertEqual(d.seek?.targetSeconds, 0)
}

func test_skipPastDuration_clampsToDuration() {
    let c = SkipCoordinator()
    let d = c.requestSkip(deltaSeconds: 100, currentPlayerTimeSeconds: 50,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 0)
    XCTAssertEqual(d.seek?.targetSeconds, 60)
}

func test_reset_clearsAllStateAndAllowsFreshSeek() {
    let c = SkipCoordinator()
    _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                     clipDurationSeconds: 60, nowMonotonicSeconds: 0)
    c.reset()
    let after = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 20,
                             clipDurationSeconds: 60, nowMonotonicSeconds: 0)
    XCTAssertEqual(after.seek?.targetSeconds, 23) // base = current (20), not stale 13
}
```

**Step 2: Run.** Clamp tests should pass already (logic above already clamps); reset test should pass (skeleton has `reset()`). If anything fails, fix.

**Step 3: If tests pass — done. If reset doesn't fully clear, ensure all four state fields are nilled.**

**Step 4: Run all `SkipCoordinatorTests`.**

**Step 5: Commit (only if anything changed).**
```bash
git commit -am "test(core): SkipCoordinator clamping + reset coverage"
```

---

## Phase 2 — Wire `SkipCoordinator` into `ContentView`

### Task 2.1: Replace `handleSkip` body, add coordinator state and debounce task

**Files:**
- Modify: `App/ContentView.swift:434-439` (and add `@State`s near line 13-56)

**Step 1: Add state.** Near the existing `@State private var workspace = Workspace()` declarations (around line 13), add:

```swift
@State private var skipCoordinator = SkipCoordinator(burstWindowSeconds: 0.15)
@State private var skipDebounceTask: Task<Void, Never>?
/// Identity of the AVPlayer that the coordinator's current state belongs
/// to. When the active player changes (clip swap, preview close), reset.
@State private var skipCoordinatorPlayerID: ObjectIdentifier?
```

**Step 2: Rewrite `handleSkip` and add `applySkipDecision`.** Replace lines 434-439 with:

```swift
private func handleSkip(_ delta: Double) {
    guard let player = currentPlayer else { return }
    if appMode == .recording { recordingController?.appendSkip(delta: delta) }

    let pid = ObjectIdentifier(player)
    if skipCoordinatorPlayerID != pid {
        skipCoordinator.reset()
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        skipCoordinatorPlayerID = pid
    }

    let now = CACurrentMediaTime()
    let curr = player.currentTime().seconds
    let durRaw = player.currentItem?.duration.seconds ?? .infinity
    let dur = (durRaw.isFinite && durRaw > 0) ? durRaw : .greatestFiniteMagnitude

    let decision = skipCoordinator.requestSkip(
        deltaSeconds: delta,
        currentPlayerTimeSeconds: curr.isFinite ? curr : 0,
        clipDurationSeconds: dur,
        nowMonotonicSeconds: now
    )
    applySkipDecision(decision, on: player)
}

private func applySkipDecision(_ decision: SkipDecision, on player: AVPlayer) {
    if let s = decision.seek {
        let t = CMTime(seconds: s.targetSeconds, preferredTimescale: 600)
        let tol: CMTime = s.exact ? .zero : .positiveInfinity
        let pid = ObjectIdentifier(player)
        player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) { _ in
            // AVPlayer fires the completion on a private queue. Bounce
            // back to the main actor before mutating coordinator state.
            Task { @MainActor in
                // If the active player changed since this seek was issued,
                // ignore the late completion — coordinator was reset already.
                guard self.skipCoordinatorPlayerID == pid else { return }
                let next = self.skipCoordinator.seekCompleted(
                    nowMonotonicSeconds: CACurrentMediaTime()
                )
                self.applySkipDecision(next, on: player)
            }
        }
    }
    if let after = decision.armDebounceSeconds {
        skipDebounceTask?.cancel()
        let pid = ObjectIdentifier(player)
        skipDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            if Task.isCancelled { return }
            guard self.skipCoordinatorPlayerID == pid else { return }
            let next = self.skipCoordinator.burstEnded(
                nowMonotonicSeconds: CACurrentMediaTime()
            )
            self.applySkipDecision(next, on: player)
        }
    }
}
```

**Step 3: Build & run.**
```bash
./scripts/run.sh
```
Expected: app launches; loading a clip preview and pressing arrow keys produces motion; rapid mashing of the FF key responds without visible "decode pause" lockup. (No automated test; the coordinator unit tests cover correctness.)

**Step 4: Commit.**
```bash
git add App/ContentView.swift
git commit -m "feat(app): coalesced FF/RW with keyframe-tolerant burst, exact-frame settle"
```

---

### Task 2.2: Reset coordinator + cancel debounce on every clip-selection change (close, A→B swap, A→B→A round-trip)

**Files:** Modify `App/ContentView.swift`.

**Why this matters:** `Workspace._previewCache` keeps an `AVPlayer` per clip ID across selections. Switching A→B→A returns the *same* `player_A` instance the second time. The `handleSkip` player-id guard would *not* detect that visit as a "player change" and would consume any leftover `target`/`flying` state from the first A visit — silently dropping or misrouting the user's first new keypress. The fix is to reset on every `selectedClipID` change, not only on explicit close.

**Step 1: Extract a reset helper.** Near the new state declarations:
```swift
/// Cancels any in-flight debounce, resets coordinator state, and clears
/// the player-id guard. Idempotent. Call on close, sidebar selection
/// change, recording-state changes — anywhere the active preview player
/// might have flipped.
private func resetSkipState() {
    skipDebounceTask?.cancel()
    skipDebounceTask = nil
    skipCoordinator.reset()
    skipCoordinatorPlayerID = nil
}
```

**Step 2: Update `handleClosePreview` (around line 466) to call it.**
```swift
private func handleClosePreview() {
    resetSkipState()
    workspace.previewPlayer(for: selectedClipID ?? UUID())?.pause()
    selectedClipID = nil
}
```

**Step 3: Add an `.onChange(of: selectedClipID)` handler on `body`.** Right where the existing `.modifier(...)` chain lives, append:
```swift
.onChange(of: selectedClipID) { _, _ in
    // Even if the user navigates A → B → A, the cache may return the
    // *same* AVPlayer for A — `handleSkip`'s pid-equality check would
    // not detect that as a swap. Reset unconditionally on selection.
    resetSkipState()
}
```

**Step 4: Manual test matrix.**
- Skip A, then close preview (Esc) → no crash, no late seek.
- Skip A, sidebar-select B, sidebar-select A → first skip on the second A visit issues a fresh seek (not a no-op).
- Skip A while a coarse seek is in flight, sidebar-select B → in-flight completion fires into a reset coordinator and is a safe no-op.

**Step 5: Commit.**
```bash
git commit -am "fix(app): reset skip coordinator on every selection change, not just close"
```

---

### Task 2.3: Freeze `StrokeReplayLayer` updates while a coarse seek is in flight

**Why:** Pre-rewrite skips were exact-frame, so `player.currentTime()` was decoder-truthful and the stroke overlay stayed in sync with the displayed video. The new flow uses keyframe-tolerant seeks during a burst — AVPlayer reports the *target* of the in-flight seek immediately, so `StrokeReplayLayer.tick` will redraw strokes for `recordSeconds = target` while the actually-displayed frame is still at the prior keyframe. For clips where strokes change over time, the user sees strokes flash to the wrong position for 50–500 ms after each coarse skip — a visible regression.

**Files:**
- Modify: `App/Preview/StrokeReplayLayer.swift` — add a frozen-mode toggle.
- Modify: `App/ContentView.swift` — toggle from `applySkipDecision`.

**Step 1: Add a frozen flag to `StrokeReplayLayer`.** New public method:
```swift
/// Pauses periodic stroke recomputation. While frozen, `tick` early-returns
/// so the overlay holds its last drawn state regardless of `player.currentTime()`.
/// Used by ContentView to mask the keyframe-decode window during a coarse seek
/// burst — the overlay would otherwise flash to wrong stroke positions.
func setReplayFrozen(_ frozen: Bool) {
    replayFrozen = frozen
}
private var replayFrozen: Bool = false
```

In `tick(at:)`, add `guard !replayFrozen else { return }` at the top.

**Step 2: Plumb a flag from ContentView.** Add `@State private var coarseSeekInFlight: Bool = false`. In `applySkipDecision`:
- When issuing a coarse seek (`s.exact == false`): set `coarseSeekInFlight = true`.
- In the seek-completion `Task @MainActor`: set `coarseSeekInFlight = false`.
- In `resetSkipState`: set `coarseSeekInFlight = false`.

**Step 3: Pipe the flag into `StrokeReplayLayer`.** The view sits inside a SwiftUI representable; pass `coarseSeekInFlight` as a value into the representable, and in `updateNSView(_:context:)` call `nsView.setReplayFrozen(value)`.

**Step 4: Manual test.** Load a clip with strokes. Mash D (3s skip) repeatedly. Strokes should hold position during the burst and snap to the correct frame after the 150 ms exact-settle lands. Without this fix, strokes flicker to wrong positions during each press.

**Step 5: Commit.**
```bash
git commit -am "fix(app): reset skip coordinator on every selection change, not just close"
```

---

## Phase 3 — `PreviewCompositor` GPU rewrite

### Task 3.1: Move `PreviewCompositor` + `PreviewInstruction` into `VideoCoachCore`

These need to be reachable from the test target. They have no App-only dependencies (`PlaybackSegment` is already in core).

**Files:**
- Move: `App/Preview/PreviewCompositor.swift` → `VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift`
- Move: `App/Preview/PreviewInstruction.swift` → `VideoCoachCore/Sources/VideoCoachCore/PreviewInstruction.swift`
- Modify: `App/Preview/ClipPreviewBuilder.swift` (drop the now-unneeded `import` paths if any; `import VideoCoachCore` already present)

**Step 1: Move the files.**
```bash
git mv App/Preview/PreviewCompositor.swift VideoCoachCore/Sources/VideoCoachCore/
git mv App/Preview/PreviewInstruction.swift VideoCoachCore/Sources/VideoCoachCore/
```

**Step 2: Mark the types `public`.**

In the moved `PreviewCompositor.swift`:
- Change `final class PreviewCompositor` → `public final class PreviewCompositor`
- `override init()` → `public override init()`
- All four protocol methods (`renderContextChanged`, `cancelAllPendingVideoCompositionRequests`, `startRequest`, plus the property accessors for `sourcePixelBufferAttributes` / `requiredPixelBufferAttributesForRenderContext`) → `public`
- Remove the unused `import Foundation` only if XCTest doesn't need it (keep — harmless).

In the moved `PreviewInstruction.swift`:
- `final class PreviewInstruction` → `public final class PreviewInstruction`
- All ivars and `make`/`segmentIndex` methods → `public`
- Drop `import VideoCoachCore` (we *are* VideoCoachCore now).

**Step 3: Build.**
```bash
cd VideoCoachCore && swift build
```
Expected: clean build.

**Step 4: Regenerate the Xcode project** (project.yml lists `App/` as a source root; moved files now live under `VideoCoachCore` which is already a package dependency, so the App target picks them up automatically through the package import — but project file must be regenerated).
```bash
xcodegen generate
./scripts/run.sh
```
Expected: app builds, clip preview still plays correctly (functional regression check before any logic change).

**Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(preview): move PreviewCompositor/Instruction into VideoCoachCore"
```

---

### Task 3.2: Pixel-test the existing PreviewCompositor (baseline)

Before rewriting, lock the current visual contract with a pixel test. The test renders a short composition through `AVAssetExportSession` with `PreviewCompositor` set, samples specific pixels, and asserts that source + webcam ended up where they belong. This becomes the gate for the rewrite.

**Files:**
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/PreviewCompositorTests.swift`

**Step 1: Write the failing test.**

```swift
import AVFoundation
import CoreMedia
import XCTest
@testable import VideoCoachCore

final class PreviewCompositorTests: XCTestCase {
    /// Synthesizes a 1280x720 GREEN source + a 320x240 RED webcam, runs them
    /// through PreviewCompositor via AVAssetExportSession, then asserts:
    ///   * a pixel near the center is GREEN (source occupies the full frame)
    ///   * a pixel inside the bottom-right PiP is RED (webcam was composited)
    /// Tolerances are generous to absorb HEVC chroma compression.
    ///
    /// **Coverage gap:** AVAssetExportSession preserves the
    /// AVMutableVideoCompositionInstruction subclass, so this test exercises
    /// the path where `inst as? PreviewInstruction` succeeds. Production
    /// preview *playback* on macOS 26 strips the subclass (per the comment
    /// in PreviewCompositor.startRequest) — that path uses default track-IDs
    /// and cannot read `frozenFrames`, so freeze segments render black during
    /// playback by design. This test does NOT cover the freeze-frame render.
    /// Smoke-verify freeze behavior manually after Phase 3.3 lands: record a
    /// clip with at least one pause, preview it, confirm the pause segment
    /// renders black (matching pre-rewrite behavior — not regressed).
    func test_compositesSourceAndWebcamPiP() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let srcURL = tmp.appendingPathComponent("preview-src-\(UUID()).mov")
        let camURL = tmp.appendingPathComponent("preview-cam-\(UUID()).mov")
        let outURL = tmp.appendingPathComponent("preview-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
            try? FileManager.default.removeItem(at: camURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try SyntheticAsset.write(to: srcURL, duration: 1.0, hasAudio: false,
                                 width: 1280, height: 720,
                                 videoColor: (r: 0, g: 0xFF, b: 0))
        try SyntheticAsset.write(to: camURL, duration: 1.0, hasAudio: false,
                                 width: 320, height: 240,
                                 videoColor: (r: 0xFF, g: 0, b: 0))

        let comp = AVMutableComposition()
        let srcAsset = AVURLAsset(url: srcURL)
        let camAsset = AVURLAsset(url: camURL)
        let srcDur = try await srcAsset.load(.duration)
        let srcTrack = try await srcAsset.loadTracks(withMediaType: .video).first!
        let camTrack = try await camAsset.loadTracks(withMediaType: .video).first!
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let w = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1000)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: srcTrack, at: .zero)
        try w.insertTimeRange(CMTimeRange(start: .zero, duration: srcDur), of: camTrack, at: .zero)

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = CGSize(width: 1280, height: 720)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.customVideoCompositorClass = PreviewCompositor.self
        let inst = PreviewInstruction.make(
            sourceTrackID: 1,
            webcamTrackID: 1000,
            compositionStart: .zero,
            clipDuration: srcDur,
            segments: [PlaybackSegment(kind: .play, sourceStart: 0, outDuration: 1.0)],
            frozenFrames: [:]
        )
        videoComp.instructions = [inst]

        let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        exp.outputURL = outURL
        exp.outputFileType = .mp4
        exp.videoComposition = videoComp
        await exp.export()
        XCTAssertEqual(exp.status, .completed, "export failed: \(String(describing: exp.error))")

        // Sample at frame ~0.5s.
        let outAsset = AVURLAsset(url: outURL)
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(value: 15, timescale: 30))

        // Center 10% box should be GREEN. PixelSampling normalizedRect uses
        // the codebase's top-down y convention (y=0 → top of image, y=1 →
        // bottom — see CompilationCompositorTests for the precedent).
        let center = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        )
        XCTAssertLessThan(center.r, 0.20, "center should be green, was \(center)")
        XCTAssertGreaterThan(center.g, 0.75, "center should be green, was \(center)")
        XCTAssertLessThan(center.b, 0.20, "center should be green, was \(center)")

        // PiP center: bottom-right at 22% width, 2.2% margin. PiP aspect is
        // 320×240 (the synthetic webcam), so pipH/pipW = 0.75. Sample a 4%
        // box inside the PiP so the box stays well clear of the PiP edges
        // even with HEVC chroma blur.
        let pipFracW = 0.22
        let pipFracH = pipFracW * 240.0 / 320.0
        let marginFrac = 0.022
        let pipCenterX = 1.0 - marginFrac - pipFracW / 2
        let pipCenterY = 1.0 - marginFrac - pipFracH / 2 // y=1 is bottom
        let sampleHalf = 0.02
        let pip = PixelSampling.averageRGB(
            in: cg,
            normalizedRect: CGRect(
                x: pipCenterX - sampleHalf,
                y: pipCenterY - sampleHalf,
                width: 2 * sampleHalf,
                height: 2 * sampleHalf
            )
        )
        XCTAssertGreaterThan(pip.r, 0.75, "PiP center should be red, was \(pip)")
        XCTAssertLessThan(pip.g, 0.25, "PiP center should be red, was \(pip)")
        XCTAssertLessThan(pip.b, 0.25, "PiP center should be red, was \(pip)")
    }
}
```

**Step 2: Run.**
```bash
cd VideoCoachCore && swift test --filter PreviewCompositorTests
```
Expected: PASS. (We're testing the *current* compositor before any rewrite.)

**Step 3: If it fails:** the existing compositor's orientation handling may differ from `CompilationCompositor` (e.g. no CIImage Y-flip in `makeCGImage`). If a flip is missing, the PiP RED would land in the *top-right* not bottom-right, and the test would catch it. **Stop and verify** by inspecting the exported `outURL` visually before adjusting the test thresholds.

**Step 4: Commit (only on green).**
```bash
git add VideoCoachCore/Tests/VideoCoachCoreTests/PreviewCompositorTests.swift
git commit -m "test(preview): pixel-level coverage for source + webcam PiP composite"
```

---

### Task 3.3: Rewrite `startRequest` to render via `CIContext.render(_:to:)`

**Files:** Modify `VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift`.

**Step 1:** The Phase 3.2 test is the gate. Run it first; it must currently pass.

**Step 2: Hoist the colorspace constant** to a static let on the compositor (avoid `CGColorSpaceCreateDeviceRGB()` in the per-frame path):

```swift
private static let outputColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
```

**Step 3: Replace `startRequest` body.** New implementation. Key choices:
- The base scale uses **non-uniform scale** (`scaleX = outW/srcW`, `scaleY = outH/srcH`) to *exactly* match the old `cg.draw(img, in: rect)` stretch behavior. This preserves visual parity for any source aspect that may slip past the v1 "landscape only" assumption (rotated phone capture etc.); changing the policy would be a separate decision.
- Orientation: `CIImage(cvPixelBuffer:)` plus `CIContext.render(_:to:)` *should* preserve the source buffer's row order without manual flipping; this is the contract Apple's video-filter pipeline relies on. The Phase 3.2 pixel test is the gate. **Failure modes to expect:**
  - Image upside-down (PiP RED appears in *top-right* instead of bottom-right) → apply a Y-flip transform to each source CIImage before compositing: `image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)).transformed(by: CGAffineTransform(translationX: 0, y: image.extent.height))`. Same pattern as `CompilationCompositor.makeCGImage` lines 340-343.
  - Image stretched the wrong way → the `scaleX/scaleY` order is swapped; flip them.
  - PiP at wrong corner → the `translate` math interpreted CI's bottom-left origin incorrectly; in CI space, "bottom-right" with margin is `(outW - margin - pipW, margin)`; "top-right with margin" is `(outW - margin - pipW, outH - margin - pipH)`. Pick the one that lands the test's PiP red sample inside the bottom-right normalized box (test convention: `normalizedRect.y → 1` means the *bottom* of the displayed image; see Phase 3.2 below).

```swift
public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    let inst = request.videoCompositionInstruction as? PreviewInstruction
    let sourceTrackID = inst?.sourceTrackID ?? 1
    let webcamTrackID = inst?.webcamTrackID ?? 1000

    // 1. Pick base buffer (freeze | live | nil) — same selection logic as before.
    let base: CVPixelBuffer?
    if let inst {
        let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
        let segIndex = inst.segmentIndex(forRecordTime: recordTime)
        let segment = inst.segments.indices.contains(segIndex) ? inst.segments[segIndex] : nil
        if let segment, segment.kind == .freeze {
            base = inst.frozenFrames[segIndex]
        } else if let live = request.sourceFrame(byTrackID: sourceTrackID) {
            base = live
        } else {
            base = nil
        }
    } else {
        base = request.sourceFrame(byTrackID: sourceTrackID)
    }

    guard let renderContext, let out = renderContext.newPixelBuffer() else {
        request.finishCancelledRequest()
        return
    }
    let outW = CGFloat(CVPixelBufferGetWidth(out))
    let outH = CGFloat(CVPixelBufferGetHeight(out))
    let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

    // 2. Black background only when there's no base. Old code black-filled
    // unconditionally even when base would cover the whole frame; that fill
    // is wasted work and we drop it.
    var composite: CIImage = CIImage(color: .black).cropped(to: outRect)

    if let base {
        let baseCI = CIImage(cvPixelBuffer: base)
        // Non-uniform stretch — matches old `cg.draw(img, in: outRect)`.
        let baseScale = CGAffineTransform(
            scaleX: outW / max(baseCI.extent.width, 1),
            y: outH / max(baseCI.extent.height, 1)
        )
        composite = baseCI.transformed(by: baseScale).composited(over: composite)
    }

    if let webcam = request.sourceFrame(byTrackID: webcamTrackID) {
        let camCI = CIImage(cvPixelBuffer: webcam)
        let camW = camCI.extent.width
        let camH = camCI.extent.height
        let pipW = outW * 0.22
        let pipH = pipW * camH / max(camW, 1)
        let margin = outH * 0.022
        // PiP geometry. CI coordinate origin is bottom-left; if the test in
        // Phase 3.2 finds the PiP rendered at top-right instead of bottom-right,
        // swap `margin` here for `outH - margin - pipH` (see Step 3 notes).
        let scale = CGAffineTransform(
            scaleX: pipW / max(camW, 1),
            y: pipH / max(camH, 1)
        )
        let translate = CGAffineTransform(
            translationX: outW - margin - pipW,
            y: margin
        )
        composite = camCI.transformed(by: scale)
            .transformed(by: translate)
            .composited(over: composite)
    }

    // 3. Single GPU render straight into the output buffer. No CGContext,
    // no pixel-buffer lock, no per-frame CGImage allocation.
    ciContext.render(
        composite,
        to: out,
        bounds: outRect,
        colorSpace: Self.outputColorSpace
    )
    request.finish(withComposedVideoFrame: out)
}
```

**Step 4: Run the pixel test.**
```bash
cd VideoCoachCore && swift test --filter PreviewCompositorTests
```
Expected: PASS. If failing, diagnose using the failure modes listed in Step 3.

**Step 5: Smoke test with the actual 4K file.**
```bash
./scripts/run.sh
# Open a project with a clip referencing /Users/taylor/Downloads/VID_20260425_090418_01_01.mp4
# Select the clip → preview should play smoothly. Compare against the
# pre-rewrite branch by checking out and toggling.
```

**Step 6: Commit.**
```bash
git commit -am "perf(preview): GPU CIContext.render path replaces CPU CGImage roundtrip"
```

---

### Task 3.4: Clamp preview `renderSize` to ≤1920×1080

**Files:** Modify `App/Preview/ClipPreviewBuilder.swift:191-200`.

**Step 1: Add a renderSize clamp.** Replace lines 191-198:

```swift
let srcNatural = try await srcVideoTrack.load(.naturalSize)
let nativeRender = CGSize(
    width: abs(srcNatural.width),
    height: abs(srcNatural.height)
)
// Preview is shown in a window — the source's full native dimensions
// (often 4K) inflate every per-frame composite/output buffer with no
// visible benefit. Cap the longer side to 1920px and preserve aspect.
// Export keeps native (CompilationExporter has its own composition).
let maxLongSide: CGFloat = 1920
let longest = max(nativeRender.width, nativeRender.height)
let renderSize: CGSize
if longest > maxLongSide {
    let scale = maxLongSide / longest
    renderSize = CGSize(
        width: (nativeRender.width * scale).rounded(),
        height: (nativeRender.height * scale).rounded()
    )
} else {
    renderSize = nativeRender
}
```

**Step 2: Build & smoke-run.** Open the 4K test clip; preview plays, looks correct, and is smooth.

**Step 3: Optional — add an assertion in the existing PreviewCompositorTests** that confirms a freshly-built composition for a synthetic 4K source produces a `renderSize` ≤1920×1080.

**Step 4: Commit.**
```bash
git commit -am "perf(preview): cap renderSize to 1920px longest side for clip preview"
```

---

## Phase 4 — Adversarial review (two passes completed; findings patched into above tasks)

### Pass 1 — `feature-dev:code-reviewer`

| Finding | Where it lives now |
|---------|-------------------|
| `exactPending` could persist when `target` becomes nil → permanent stuck state. | `seekCompleted` clears `exactPending` unconditionally on entry (Task 1.4). |
| `SkipCoordinator` not isolated → Swift concurrency hazard. | Class is now `@MainActor`; tests are `@MainActor`. |
| `scaledToFill` (uniform max-scale) crops from CI bottom-left, doesn't match old `cg.draw(_:in:)` stretch. | Compositor uses non-uniform `scaleX/scaleY` (Task 3.3). |
| Pixel test referenced nonexistent `PixelSampling.rgbAt(x:y:in:)`. | Rewritten using `PixelSampling.averageRGB(in:normalizedRect:)` (Task 3.2). |
| Plan predicted "likely fix is a Y-flip" without verifying. | Replaced with explicit failure-mode diagnostic table (Task 3.3). |

### Pass 2 — `superpowers:code-reviewer`

| Finding | Where it lives now |
|---------|-------------------|
| `Workspace._previewCache` returns same `AVPlayer` for A→B→A; `pid` guard wouldn't catch it → stale `target`/`flying` consumed for a fresh A visit. | Added Task 2.2: reset on every `selectedClipID` change, not only on close. |
| `StrokeReplayLayer` will draw to phantom positions during keyframe-tolerant seeks (AVPlayer reports the seek *target* immediately, before decoder catches up). | Added Task 2.3: freeze stroke replay while a coarse seek is in flight. |
| Pixel test only exercises export path (subclass preserved); production playback strips subclass and renders freeze segments black. | Documented as a coverage-gap comment on the test (Task 3.2) plus a manual smoke-verify step for freeze segments. |
| Decoder cost is `O(source pixels)`; renderSize clamp + GPU compositor don't address it. Verification checklist treated "smooth" as binary. | Verification checklist reframed: "noticeably smoother" is the bar; proxy generation is the next axis if it isn't enough. |

**Considered, judged not actionable:**

- *F1 (`@State` of reference type + closure-captured `self.skipCoordinatorPlayerID`):* `@State`'s wrapper holds a stable storage reference across struct copies, so reads through a captured `self` *are* live. Reviewer over-reached on the snapshot semantics. The deeper concern (re-allocation on view re-init) is mitigated by `@State` retaining the first allocation and discarding subsequent re-evaluations.
- *F3 (debounce-vs-completion Task ordering race):* walked the @MainActor scheduling carefully — `flying` is set synchronously in `requestSkip` when the seek is issued and is non-nil from then until `seekCompleted` clears it. The reviewer's "burstEnded sees `flying == nil` while AVPlayer is mid-seek" premise doesn't hold. Idempotent `exactPending` writes also make the late-debounce path safe. Skipping the in-flight token mechanism unless a test surfaces an actual ordering bug.
- *F7 (alpha pre-multiplied vs straight in CIContext.render):* webcam buffers are opaque (alpha=1 everywhere); the composite is opaque end-to-end; both forms produce identical output for opaque inputs. Adding a one-line "opaque-only" comment near the composited(over:) call would be defensive but is optional.

**Items left as runtime concerns (no plan changes; document in commit messages or code comments when encountered):**

- **Color-space drift:** preview render pins `outputColorSpace = CGColorSpaceCreateDeviceRGB()`, matching CompilationCompositor's CI context spaces. Visually verify preview vs. exported frame do not diverge in saturation.
- **`renderSize` clamp interaction with frozen frames:** `gen.maximumSize = 1280×720` pre-shrinks freeze frames; after clamp, render can be up to 1920×1080. Freeze frames upscale ~1.5× — acceptable for a paused frame. Re-tune only if visibly soft.
- **Debounce window choice:** 0.15 s is a starting guess. Feel-test 0.10/0.15/0.20 with the 4K test file.
- **Recording/replay parity:** `appendSkip` fires per-keystroke; the export path replays each event independently and is unchanged.
- **Black background CIImage layer:** rendered every frame even when the base fully covers `outRect`. CI may optimize this internally; if not, dropping the black layer when `base != nil` is a minor perf win.

---

## Verification checklist (post-execution)

- [ ] `cd VideoCoachCore && swift test` — all tests pass
- [ ] `./scripts/run.sh` — app builds clean
- [ ] Load `/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4` as a source, record a clip, preview it: playback is materially smoother than pre-change (compare against the prior commit by checking it out and toggling).
- [ ] In the preview, mash the `D` key (3s skip) 5× rapidly: motion is responsive each press; ~150 ms after the last press, the playhead snaps to a precise frame; **strokes do not flicker to wrong positions during the burst** (Task 2.3 gate).
- [ ] In the preview, press `D` once: motion lands within a few frames; ~150 ms later snaps to exact frame.
- [ ] Esc out of a preview while a debounce/seek is in flight: no crash, no console error.
- [ ] Sidebar A→B→A round-trip with a skip on each visit: each new skip issues a real seek (no silent first-keypress drop after returning to A).
- [ ] Export a clip that exercises a `.freeze` segment: visual parity with pre-change export (export path is untouched, but verify).

### If preview is still not smooth after both phases

Don't read the perf goal as binary. Decoder cost is `O(source pixels)` regardless of `renderSize` — the renderSize clamp + GPU compositor only shrink **composite/output bandwidth**, not decode bandwidth. Long-GOP HEVC at 4K30 should be real-time on Apple silicon, but if the user's source has unusually long GOP or high bitrate, decoder bandwidth alone can dominate. The next axis past this plan is a **preview proxy**: transcode each clip's source range to 1080p once at recording time and route preview playback through that proxy. That's a separate plan, not a failure of this one. Treat "noticeably smoother" as the success bar; treat "buttery smooth" as proxy-blocked.
