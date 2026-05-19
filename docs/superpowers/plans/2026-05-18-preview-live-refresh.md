# Preview Live-Refresh on showPiP Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Toggling `clip.showPiP` from the inspector flips the PiP overlay within one frame instead of the current ~100–800 ms full preview rebuild.

**Architecture:** Split `ClipPreviewBuilder.buildPreviewItem` into two phases. Phase A is heavy (asset loads, composition track inserts, source-layer instruction with zoom keyframes, webcam-layer instruction with geometry). Phase B is light (build the `AVMutableVideoComposition` with the appropriate `layerInstructions` array — `[webcamLayer, sourceLayer]` when `showPiP`, `[sourceLayer]` otherwise — and the appropriate `webcamTrackID` sentinel in `PreviewInstruction.make`). Phase A's outputs live on a new `PreviewCacheEntry` struct stored in `Workspace._previewCache` alongside the `AVPlayer`. Adding `Workspace.setShowPiP(_:for:)` runs Phase B against the cached entry and reassigns `playerItem.videoComposition` in place — the `AVPlayer`, the `AVMutableComposition`, the asset reads, and every track insertion stay intact. The `ContentView.onChange(of: showPiP)` clear-and-reselect dance from Task 9 is dropped; the inspector toggle and the undo/redo path now drive the visual sync directly.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, XCTest, `xcodebuild`.

**Predecessor:** `docs/superpowers/plans/2026-05-17-hide-pip.md` (Task 9 shipped the clear-and-reselect approach this plan supersedes).

**Working branch:** `hide-pip` (this plan continues the hide-pip work — it is the right design that Task 9 deferred).

**Canonical test commands:**

- Core package: `swift test --package-path apple/VideoCoachCore`
- App unit tests: `cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test`
- App full build: `apple/scripts/run.sh`

---

## Task 1: Split `ClipPreviewBuilder` into Phase A + Phase B, cache geometry on a `PreviewCacheEntry`

**Files:**

- Modify: `apple/App/Preview/ClipPreviewBuilder.swift`
- Modify: `apple/App/Models/Workspace.swift`
- Modify: `apple/Tests/AppTests/ClipPreviewBuilderTests.swift`

This task is the structural refactor. Behavior is unchanged at this step: `buildPreviewItem` still returns an `AVPlayerItem` that draws PiP exactly as today (or omits it exactly as today, based on initial `clip.showPiP`). What changes is that `Workspace` now caches enough state to rebuild Phase B on demand without re-running Phase A.

- [ ] **Step 1: Define `PreviewCacheEntry` at the top of `ClipPreviewBuilder.swift`**

Place the struct above `ClipPreviewBuilderError` in `apple/App/Preview/ClipPreviewBuilder.swift`. The struct lives here (not in `Workspace.swift`) because: (a) it's the direct output of Phase A, (b) `ClipPreviewBuilder.swift` already imports `AVFoundation` / `CoreMedia` / `CoreGraphics` (its only deps), (c) it's already in `VideoCoachTests.sources` in `project.yml` so the test bundle sees it for free, and (d) the file is 454 lines today — adding a 9-line struct doesn't make it overgrown, and the project's convention is to keep small builder-output types in the builder file (cf. `ClipPreviewBuilderError`).

Putting it in `Workspace.swift` would force `App/Models/Workspace.swift` into `VideoCoachTests.sources`, which transitively requires `MPVKit` and `ProjectStore` in the test bundle — a heavy dependency for a 9-line data carrier.

```swift
/// Cached preview state for a single clip. Phase A of `ClipPreviewBuilder`
/// (asset loads, composition track inserts, source/webcam layer instructions
/// with their geometry baked in) produces this entry once; Phase B
/// re-runs whenever `showPiP` toggles to rebuild just the
/// `AVMutableVideoComposition` (cheap — no asset I/O).
struct PreviewCacheEntry {
    let player: AVPlayer
    let renderSize: CGSize
    let clipDuration: CMTime
    let sourceTrackID: CMPersistentTrackID
    let webcamTrackID: CMPersistentTrackID
    let sourceLayer: AVMutableVideoCompositionLayerInstruction
    let webcamLayer: AVMutableVideoCompositionLayerInstruction
}
```

- [ ] **Step 2: Change `Workspace._previewCache` to `[Clip.ID: PreviewCacheEntry]`**

```swift
private var _previewCache: [Clip.ID: PreviewCacheEntry] = [:]
```

Update `Workspace.previewPlayer(for:)` to return `_previewCache[id]?.player` instead of the cached raw player.

`Workspace.invalidatePreviewCache(for:)` continues to remove by id — its body needs no change because the key type is unchanged.

`Workspace.updatePreviewVolumes(for:)` already accesses `_previewCache[id]` — update it to `.player` to fetch the inner `AVPlayer`.

- [ ] **Step 3: Refactor `ClipPreviewBuilder` to expose Phase B**

In `apple/App/Preview/ClipPreviewBuilder.swift`, restructure `buildPreviewItem` so it:

1. Does all current Phase A work (asset loads, composition track inserts, freeze-segment math, source layer with zoom keyframes, webcam layer with PiP geometry).
2. Builds **both** `sourceLayer` and `webcamLayer` regardless of `clip.showPiP` — the webcam layer is cheap to compute eagerly (one `await webcamVideoTrack.load(.naturalSize)` plus a transform). We always-build because the user may toggle PiP back on later, and we don't want a second asset hit.
3. Calls a new internal helper `makeVideoComposition(...)` to construct the `AVMutableVideoComposition` from the layer instructions + the desired `showPiP` value.
4. Returns a tuple `(AVPlayerItem, PreviewCacheEntry)` instead of just `AVPlayerItem`.

The new helper:

```swift
nonisolated static func makeVideoComposition(
    renderSize: CGSize,
    clipDuration: CMTime,
    sourceTrackID: CMPersistentTrackID,
    webcamTrackID: CMPersistentTrackID,
    sourceLayer: AVMutableVideoCompositionLayerInstruction,
    webcamLayer: AVMutableVideoCompositionLayerInstruction,
    showPiP: Bool
) -> AVMutableVideoComposition {
    let videoComp = AVMutableVideoComposition()
    videoComp.renderSize = renderSize
    videoComp.frameDuration = CMTime(value: 1, timescale: 30)
    let inst: PreviewInstruction
    if showPiP {
        inst = PreviewInstruction.make(
            sourceTrackID: sourceTrackID,
            webcamTrackID: webcamTrackID,
            compositionStart: .zero,
            clipDuration: clipDuration,
            segments: [],
            frozenFrames: [:],
            events: []
        )
        // AVFoundation layer order: first instruction is on TOP, so the
        // webcam (PiP) goes first to overlay the full-frame source.
        inst.layerInstructions = [webcamLayer, sourceLayer]
    } else {
        // PiP suppressed: drop the webcam track from `requiredSourceTrackIDs`
        // (via the invalid sentinel) so AVPlayer doesn't decode it, and
        // omit the webcam layer instruction.
        inst = PreviewInstruction.make(
            sourceTrackID: sourceTrackID,
            webcamTrackID: kCMPersistentTrackID_Invalid,
            compositionStart: .zero,
            clipDuration: clipDuration,
            segments: [],
            frozenFrames: [:],
            events: []
        )
        inst.layerInstructions = [sourceLayer]
    }
    videoComp.instructions = [inst]
    return videoComp
}
```

Phase A's epilogue (the section currently around lines 312–370 that emits the NSLog, builds the layer instructions, and constructs `inst`) becomes:

```swift
let actualSourceID = sourceVideoComp.trackID
let actualWebcamID = webcamVideoComp.trackID
NSLog("[Preview] track IDs: source=\(actualSourceID) webcam=\(actualWebcamID) (preferred was \(sourceTrackID)/\(webcamTrackID)) showPiP=\(clip.showPiP)")

// Always build BOTH layer instructions during Phase A so a later
// `setShowPiP` toggle can swap layerInstructions without re-loading the
// webcam asset. Cheap: one naturalSize metadata load + transform math.
let camNatural = try await webcamVideoTrack.load(.naturalSize)
let camW = max(abs(camNatural.width), 1)
let camH = max(abs(camNatural.height), 1)
let pipW = renderSize.width * 0.22
let pipH = pipW * camH / camW
let margin = renderSize.height * 0.022
let webcamScale = CGAffineTransform(scaleX: pipW / camW, y: pipH / camH)
let webcamTranslate = CGAffineTransform(
    translationX: renderSize.width - margin - pipW,
    y: renderSize.height - margin - pipH
)
let webcamLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: webcamVideoComp)
webcamLayer.setTransform(webcamScale.concatenating(webcamTranslate), at: .zero)

let videoComp = makeVideoComposition(
    renderSize: renderSize,
    clipDuration: clipDuration,
    sourceTrackID: actualSourceID,
    webcamTrackID: actualWebcamID,
    sourceLayer: sourceLayer,
    webcamLayer: webcamLayer,
    showPiP: clip.showPiP
)

let zoomEventCount = clip.events.reduce(into: 0) { acc, e in
    if case .zoom = e.kind { acc += 1 }
}
NSLog("[Preview] renderSize=\(renderSize) zoomEvents=\(zoomEventCount) totalEvents=\(clip.events.count)")
NSLog("[Preview] build complete; AVPlayerItem ready (built-in compositor)")

let item = AVPlayerItem(asset: comp)
item.videoComposition = videoComp
let entry = PreviewCacheEntry(
    player: AVPlayer(playerItem: item),
    renderSize: renderSize,
    clipDuration: clipDuration,
    sourceTrackID: actualSourceID,
    webcamTrackID: actualWebcamID,
    sourceLayer: sourceLayer,
    webcamLayer: webcamLayer
)
return entry
```

Change the return type of `buildPreviewItem` from `AVPlayerItem` to `PreviewCacheEntry`. The signature becomes:

```swift
nonisolated static func buildPreviewItem(
    for clip: Clip,
    project: Project,
    projectFolder: URL
) async throws -> PreviewCacheEntry
```

Rename to `buildPreviewEntry` since the return is no longer just an `AVPlayerItem`.

- [ ] **Step 4: Update `Workspace.preparePreviewPlayer(for:)` to use the new return type**

In `Workspace.swift`'s `preparePreviewPlayer(for:)`:

```swift
private func preparePreviewPlayer(for id: Clip.ID) async throws {
    guard let clip = project.clips.first(where: { $0.id == id }),
          let folder = self.folder else { return }
    let snapshot = project
    let entry = try await ClipPreviewBuilder.buildPreviewEntry(
        for: clip,
        project: snapshot,
        projectFolder: folder
    )
    entry.player.currentItem?.audioMix = audioMix(for: clip)
    entry.player.volume = 1.0
    _previewCache[id] = entry
    _previewFailed.removeValue(forKey: id)
}
```

The `AVPlayer` is now constructed inside `buildPreviewEntry` (so it can be stored on `PreviewCacheEntry`), not in `preparePreviewPlayer`. The audio mix attach + volume set stays in `Workspace` because they reference `project.preferences` which is main-actor data.

- [ ] **Step 5: Update the existing `ClipPreviewBuilderTests` to reflect the new shape**

The two existing tests still assert `vc.instructions.first?.layerInstructions.count`. Update them to call `buildPreviewEntry` and inspect `entry.player.currentItem?.videoComposition`:

```swift
func test_showPiPTrue_includesWebcamLayerInstruction() async throws {
    let entry = try await buildEntry(showPiP: true)
    let item = try XCTUnwrap(entry.player.currentItem)
    let vc = try XCTUnwrap(item.videoComposition)
    let inst = try XCTUnwrap(vc.instructions.first as? AVVideoCompositionInstruction)
    XCTAssertEqual(inst.layerInstructions.count, 2)
}

func test_showPiPFalse_omitsWebcamLayerInstruction() async throws {
    let entry = try await buildEntry(showPiP: false)
    let item = try XCTUnwrap(entry.player.currentItem)
    let vc = try XCTUnwrap(item.videoComposition)
    let inst = try XCTUnwrap(vc.instructions.first as? AVVideoCompositionInstruction)
    XCTAssertEqual(inst.layerInstructions.count, 1)
}

private func buildEntry(showPiP: Bool) async throws -> PreviewCacheEntry {
    // existing body, but returns the entry produced by buildPreviewEntry
}
```

`PreviewCacheEntry` is visible to the test bundle because it's defined at the top of `ClipPreviewBuilder.swift`, which is already in `VideoCoachTests.sources` (added during the predecessor hide-PiP plan's Task 5). No `project.yml` change is needed.

- [ ] **Step 6: Run the test target, confirm green**

```
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach \
  -only-testing:VideoCoachTests test 2>&1 \
  | grep -E "Test Case|error:|\*\* (BUILD|TEST)"
```

Expected: all existing tests pass. The two `ClipPreviewBuilderTests` continue to assert layer counts; they now route through `PreviewCacheEntry`.

- [ ] **Step 7: Run the full core suite**

```
swift test --package-path apple/VideoCoachCore
```

Expected: 139 tests pass.

- [ ] **Step 8: Build the app**

```
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach \
  -configuration Debug build 2>&1 | grep -E "error:|warning:|\*\* BUILD"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add apple/App/Preview/ClipPreviewBuilder.swift \
        apple/App/Models/Workspace.swift \
        apple/Tests/AppTests/ClipPreviewBuilderTests.swift
git commit -m "$(cat <<'EOF'
preview: split builder into geometry + composition phases

Phase A (asset loads, composition track inserts, source/webcam layer
instructions with their geometry) runs once per clip-preview. Phase B
(build AVMutableVideoComposition with the desired layerInstructions
array) is now a cheap pure function that can be re-run on every
showPiP toggle. Phase A's outputs live on a new PreviewCacheEntry
struct.

No behavior change yet — this is the refactor that enables the
upcoming setShowPiP live-swap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `Workspace.setShowPiP(_:for:)` and wire the live-swap; drop the `.onChange` clear-and-reselect

**Files:**

- Modify: `apple/App/Models/Workspace.swift`
- Modify: `apple/App/Views/ClipInspector.swift`
- Modify: `apple/App/ContentView.swift`
- Test: `apple/Tests/AppTests/ClipPreviewBuilderTests.swift`

This task adds the live-swap API and changes the call sites that drove the clear-and-reselect hack from Task 9 to use it instead.

- [ ] **Step 1: Add `Workspace.setShowPiP(_:for:)` and close the toggle-during-build race in `preparePreviewPlayer`**

In `apple/App/Models/Workspace.swift`, alongside `previewPlayer(for:)` / `invalidatePreviewCache(for:)`:

```swift
/// Swap the cached preview's PiP visibility without rebuilding the
/// composition or re-loading assets. If no cache entry exists yet
/// (preview never opened, or already invalidated), this is a no-op —
/// the next preview build will pick up the current `clip.showPiP`.
func setShowPiP(_ showPiP: Bool, for id: Clip.ID) {
    guard let entry = _previewCache[id] else { return }
    let newVC = ClipPreviewBuilder.makeVideoComposition(
        renderSize: entry.renderSize,
        clipDuration: entry.clipDuration,
        sourceTrackID: entry.sourceTrackID,
        webcamTrackID: entry.webcamTrackID,
        sourceLayer: entry.sourceLayer,
        webcamLayer: entry.webcamLayer,
        showPiP: showPiP
    )
    entry.player.currentItem?.videoComposition = newVC
}
```

Then amend `preparePreviewPlayer(for:)` (changed in Task 1 Step 4) to sync if `showPiP` was toggled during Phase A. The inspector PiP toggle is interactive throughout `.previewLoading` (no `.disabled` gate on the inspector pane), so a user can toggle during the 100-800ms build window. Without this sync, the cache lands with the snapshot's pre-toggle `showPiP` value and the user sees the wrong PiP state until they toggle again. Up until Task 2 Step 6 drops the `.onChange` clear-and-reselect, the Task 9 modifier masks this — but Task 2 Step 6 removes that safety net, so this fix is load-bearing for the final shape.

```swift
private func preparePreviewPlayer(for id: Clip.ID) async throws {
    guard let clip = project.clips.first(where: { $0.id == id }),
          let folder = self.folder else { return }
    let snapshot = project
    let entry = try await ClipPreviewBuilder.buildPreviewEntry(
        for: clip,
        project: snapshot,
        projectFolder: folder
    )
    entry.player.currentItem?.audioMix = audioMix(for: clip)
    entry.player.volume = 1.0
    _previewCache[id] = entry
    // If `showPiP` was toggled while Phase A was in flight, the cached
    // entry was built with the stale snapshot value. Re-read the live
    // value and re-run Phase B in place if it differs.
    if let currentClip = project.clips.first(where: { $0.id == id }),
       currentClip.showPiP != clip.showPiP {
        setShowPiP(currentClip.showPiP, for: id)
    }
    _previewFailed.removeValue(forKey: id)
}
```

- [ ] **Step 2: Write the failing live-swap test**

Append to `apple/Tests/AppTests/ClipPreviewBuilderTests.swift`. Reuses the existing `buildEntry(showPiP:)` helper (the renamed `buildItem` from Task 1 Step 5) so the test focuses on what's new — the layer-instruction swap — instead of re-staging Project/Clip/bookmark setup.

```swift
/// Verifies that `makeVideoComposition` — the helper that
/// `Workspace.setShowPiP(_:for:)` wraps — correctly rebuilds the
/// composition with one vs. two layer instructions when called against
/// a live AVPlayerItem. The guard in `setShowPiP`
/// (`guard let entry = _previewCache[id] else { return }`) is a
/// trivial cache-miss no-op; exercising it end-to-end would require
/// constructing a full `Workspace` with a real project folder, which
/// transitively pulls MPVKit and ProjectStore into the test bundle —
/// not worth it for a one-line guard.
@MainActor
func test_makeVideoComposition_swapsLayerInstructionsInPlace() async throws {
    let entry = try await buildEntry(showPiP: true)
    let item = try XCTUnwrap(entry.player.currentItem)

    // Sanity: two layer instructions initially.
    let vcBefore = try XCTUnwrap(item.videoComposition)
    let instBefore = try XCTUnwrap(vcBefore.instructions.first as? AVVideoCompositionInstruction)
    XCTAssertEqual(instBefore.layerInstructions.count, 2)

    // Flip via the helper that setShowPiP wraps.
    item.videoComposition = ClipPreviewBuilder.makeVideoComposition(
        renderSize: entry.renderSize,
        clipDuration: entry.clipDuration,
        sourceTrackID: entry.sourceTrackID,
        webcamTrackID: entry.webcamTrackID,
        sourceLayer: entry.sourceLayer,
        webcamLayer: entry.webcamLayer,
        showPiP: false
    )

    // After the swap: the SAME AVPlayer instance now sees a single
    // layer instruction.
    let vcAfter = try XCTUnwrap(item.videoComposition)
    let instAfter = try XCTUnwrap(vcAfter.instructions.first as? AVVideoCompositionInstruction)
    XCTAssertEqual(instAfter.layerInstructions.count, 1,
        "live-swap must reduce layer count to 1 without rebuilding the player")

    // Flip back to confirm symmetry.
    item.videoComposition = ClipPreviewBuilder.makeVideoComposition(
        renderSize: entry.renderSize,
        clipDuration: entry.clipDuration,
        sourceTrackID: entry.sourceTrackID,
        webcamTrackID: entry.webcamTrackID,
        sourceLayer: entry.sourceLayer,
        webcamLayer: entry.webcamLayer,
        showPiP: true
    )
    item.videoComposition = restoredVC
    let vcRestored = try XCTUnwrap(item.videoComposition)
    let instRestored = try XCTUnwrap(vcRestored.instructions.first as? AVVideoCompositionInstruction)
    XCTAssertEqual(instRestored.layerInstructions.count, 2,
        "live-swap back to showPiP=true must restore both layer instructions")
}
```

- [ ] **Step 3: Run the test, confirm it passes**

```
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach \
  -only-testing:VideoCoachTests/ClipPreviewBuilderTests/test_makeVideoComposition_swapsLayerInstructionsInPlace test 2>&1 \
  | grep -E "Test Case|error:|\*\* (BUILD|TEST)"
```

Expected: pass. Task 1 already shipped `makeVideoComposition`, so the helper exists and the test verifies the contract works end-to-end against a real built `AVPlayerItem`. No conceptual red phase here — the test is a forward-looking check that the swap mechanism does what the rest of Task 2 relies on.

- [ ] **Step 4: Modify `Workspace.applyInverse(of:)` and `applyForward(of:)` to use `setShowPiP` instead of `invalidatePreviewCache`**

The existing `.editClip` cases (around lines 543–549 and 573–578 of `Workspace.swift`) currently invalidate the entire preview cache on undo/redo. Other clip fields (name, tags, notes) don't affect playback. The only clip field that affects playback is `showPiP`. Replace the `invalidatePreviewCache(for: id)` call with `setShowPiP(project.clips[i].showPiP, for: id)` for the editClip cases.

```swift
case let .editClip(id, before, _):
    if let i = project.clips.firstIndex(where: { $0.id == id }) {
        project.clips[i] = before
        // Among all Clip fields reachable from the inspector today, only
        // `showPiP` affects rendered playback — name, tags, and notes are
        // pure metadata. `events` affects playback (zoom keyframes, freeze
        // segments) but is set at recording time and has no inspector UI.
        // If a future field both affects playback AND gains inspector UI,
        // this call site must also call `invalidatePreviewCache(for: id)`
        // for that field.
        setShowPiP(before.showPiP, for: id)
        try? saveProject()
    }
```

Mirror change in `applyForward` (same comment):

```swift
case let .editClip(id, _, after):
    if let i = project.clips.firstIndex(where: { $0.id == id }) {
        project.clips[i] = after
        setShowPiP(after.showPiP, for: id)
        try? saveProject()
    }
```

- [ ] **Step 5: Update the inspector toggle setter in `apple/App/Views/ClipInspector.swift`**

The setter currently calls `workspace.invalidatePreviewCache(for: clip.id)`. Change to `workspace.setShowPiP(newValue, for: clip.id)`:

```swift
Toggle("Show picture-in-picture", isOn: Binding(
    get: { clip.showPiP },
    set: { newValue in
        let before = clip
        clip.showPiP = newValue
        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
        try? workspace.saveProject()
        workspace.setShowPiP(newValue, for: clip.id)
    }
))
```

- [ ] **Step 6: Delete the `.onChange(of: showPiP)` modifier in `apple/App/ContentView.swift`**

The Task 9 modifier:

```swift
.onChange(of: workspace.project.clips.first(where: { $0.id == selectedClipID })?.showPiP) { _, _ in
    if case .previewClip(let id) = appMode {
        selectedClipID = nil
        DispatchQueue.main.async { selectedClipID = id }
    }
}
```

is no longer needed — both call sites (inspector toggle setter, undo/redo) now drive the live-swap directly. Delete the modifier.

- [ ] **Step 7: Run the full test target**

```
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach \
  -only-testing:VideoCoachTests test 2>&1 \
  | grep -E "Test Case|error:|\*\* (BUILD|TEST)"
```

Expected: all VideoCoachTests pass, including the new live-swap test.

- [ ] **Step 8: Build the app**

```
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach \
  -configuration Debug build 2>&1 | grep -E "error:|warning:|\*\* BUILD"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Manual smoke (user runs this)**

1. Launch via `apple/scripts/run.sh`.
2. Open a project with a recorded clip whose `showPiP == true`.
3. Click the clip → preview opens with PiP visible.
4. Toggle the inspector "Show picture-in-picture" off — PiP disappears within one frame. The video does NOT pause, seek, or rebuild a loading state.
5. Toggle back on — PiP returns within one frame.
6. ⌘Z to undo — same behavior, instant flip.
7. ⌘⇧Z to redo — same behavior, instant flip.

- [ ] **Step 10: Commit**

```bash
git add apple/App/Models/Workspace.swift \
        apple/App/Views/ClipInspector.swift \
        apple/App/ContentView.swift \
        apple/Tests/AppTests/ClipPreviewBuilderTests.swift
git commit -m "$(cat <<'EOF'
preview: live-swap videoComposition on showPiP toggle

Replaces the Task 9 clear-and-reselect hack with a surgical
videoComposition swap. Inspector toggle, undo, and redo all call
Workspace.setShowPiP(_:for:), which re-runs Phase B of
ClipPreviewBuilder against the cached PreviewCacheEntry and assigns
the result to playerItem.videoComposition. The AVPlayer instance,
the AVMutableComposition, and every track insertion stay intact —
no asset reload, no seek interruption, no preview-loading state.

The .onChange(of: showPiP) modifier in ContentView is gone; the
mutation sites (inspector setter, undo/redo apply paths) drive the
visual sync directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage**
  - Phase A / Phase B split → Task 1 (Steps 1–3)
  - PreviewCacheEntry cache shape → Task 1 (Step 2)
  - setShowPiP live-swap API → Task 2 (Step 1)
  - Inspector toggle uses live-swap → Task 2 (Step 5)
  - Undo/redo use live-swap → Task 2 (Step 4)
  - Drop the Task 9 clear-and-reselect → Task 2 (Step 6)
  - Live-swap test → Task 2 (Step 2)
  - Manual smoke covers the UX claim (instant flip in preview, on undo, on redo) → Task 2 (Step 9)

- **Placeholder scan**: no TBDs, no "fix later," no vague spec language. Every step shows the actual code or the precise edit to make.

- **Type consistency**: `PreviewCacheEntry` is the struct name throughout. `setShowPiP(_:for:)`, `makeVideoComposition(...)`, `buildPreviewEntry(...)` are the API names throughout. No drift between tasks.

- **Risks acknowledged**
  - Adding `Workspace.swift` to `VideoCoachTests.sources` (Task 1 Step 5) may pull in app-target dependencies that don't compile in the unit-test bundle. The plan says STOP and report if that happens; the most likely fix is splitting `PreviewCacheEntry` into its own small file that doesn't carry the Workspace dependencies.
  - Eagerly building the webcam layer even when initial `clip.showPiP == false` costs one `await webcamVideoTrack.load(.naturalSize)` call we skipped before. That call is metadata-only (no decoding); cost is sub-millisecond on local files. Earns its place: avoids a second asset hit when the user toggles PiP back on.
  - `applyInverse`/`applyForward` now narrowly handle the editClip case as "only showPiP affects playback." If a future field is added to `Clip` that DOES affect playback (currently none — `events` is set during recording and never edited in the inspector), the new field-adder will need to invalidate the cache. Comment on the editClip case documents this.
