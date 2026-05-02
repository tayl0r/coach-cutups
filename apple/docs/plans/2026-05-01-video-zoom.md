# Video Zoom + Pan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the zoom/pan feature designed in `apple/docs/plans/2026-05-01-video-zoom-design.md` — interactive zoom on the source-playback view (mouse + trackpad), keyframed capture during recording, replay during clip preview and export.

**Architecture:** New `Zoom` struct in `VideoCoachCore` plus a `.zoom(Zoom)` variant of `CommentaryEvent.Kind`. `Workspace.currentZoom` is the live state observed by `MPVRenderingNSView`, which writes mpv's `video-zoom` / `video-pan-x` / `video-pan-y` runtime properties. `RecordingController.appendZoom` captures keyframes with an anchor pattern (two keyframes 1ms apart for discrete events). `Clip.zoomAt(recordTime:)` linearly interpolates between keyframes. `PreviewCompositor` and `CompilationCompositor` each gain a one-line `let zoom = clip.zoomAt(recordTime: ...)` plus a shared `Zoom.transform(sourceSize:destSize:)` extension applied to the source frame.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, AppKit (NSEvent gesture handlers), libmpv runtime properties via MPVKit, AVFoundation (`AVVideoCompositing`).

**Branch:** `feat/video-zoom` (off `feat/source-playback-metal-direct` at `c72c27b`).

**Companion document:** `apple/docs/plans/2026-05-01-video-zoom-design.md` — read this first for the *why* behind every decision (D1–D9). This plan covers the *what* and *how*.

**Test commands:**
- `cd apple && swift test --package-path VideoCoachCore` — unit tests for Zoom math, lookup, capture rules, compositor pixel assertions.
- `cd apple && xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachUITests/MPVZoomPlaybackTests` — XCUITest for live-playback wiring.
- `cd apple && ./scripts/run.sh` — manual smoke (the gesture handlers are largely manually verified).

---

## Phase 1 — Data model + lookup math (pure, TDD-first)

The whole feature rides on a few small pure functions. Land them first under unit tests; later phases consume them.

### Task 1.1: Add `Zoom` struct with clamping

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift`

**Step 1: Write the failing tests.**

```swift
// apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift
import XCTest
@testable import VideoCoachCore

final class ZoomTests: XCTestCase {
    func test_identity_is_full_frame() {
        XCTAssertEqual(Zoom.identity.scale, 1.0)
        XCTAssertEqual(Zoom.identity.panX, 0)
        XCTAssertEqual(Zoom.identity.panY, 0)
    }

    func test_clamped_scale_floor_is_1() {
        XCTAssertEqual(Zoom(scale: 0.5, panX: 0, panY: 0).clamped().scale, 1.0)
    }

    func test_clamped_scale_ceiling_is_10() {
        XCTAssertEqual(Zoom(scale: 99, panX: 0, panY: 0).clamped().scale, 10.0)
    }

    func test_clamped_pan_is_zero_at_scale_1() {
        let z = Zoom(scale: 1.0, panX: 0.3, panY: -0.4).clamped()
        XCTAssertEqual(z.panX, 0)
        XCTAssertEqual(z.panY, 0)
    }

    func test_clamped_pan_constrains_visible_to_source_at_scale_2() {
        // At scale=2 the visible window is half the source. Maximum pan is
        // ±0.25 (so visible region edge sits at source edge).
        let limit = (2.0 - 1.0) / (2 * 2.0)
        let z = Zoom(scale: 2.0, panX: 1.0, panY: -1.0).clamped()
        XCTAssertEqual(z.panX, limit, accuracy: 1e-9)
        XCTAssertEqual(z.panY, -limit, accuracy: 1e-9)
    }
}
```

**Step 2: Run tests, expect failure (`Zoom` undefined).**

```bash
cd apple && swift test --package-path VideoCoachCore --filter ZoomTests
```
Expected: build error "Cannot find 'Zoom' in scope".

**Step 3: Implement `Zoom`.**

```swift
// apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift
import Foundation

public struct Zoom: Codable, Hashable, Sendable {
    public var scale: Double
    public var panX: Double
    public var panY: Double

    public static let identity = Zoom(scale: 1.0, panX: 0, panY: 0)

    public init(scale: Double, panX: Double, panY: Double) {
        self.scale = scale
        self.panX = panX
        self.panY = panY
    }

    /// Hard floor 1.0× (no zooming out past full frame), soft cap 10×.
    /// Pan range narrows as scale → 1.0; at scale=1 pan is forced to 0.
    public func clamped() -> Zoom {
        let s = max(1.0, min(10.0, scale))
        guard s > 1.0 else { return Zoom(scale: 1.0, panX: 0, panY: 0) }
        let limit = (s - 1.0) / (2.0 * s)
        let px = max(-limit, min(limit, panX))
        let py = max(-limit, min(limit, panY))
        return Zoom(scale: s, panX: px, panY: py)
    }
}
```

**Step 4: Run tests, expect pass.**

```bash
cd apple && swift test --package-path VideoCoachCore --filter ZoomTests
```
Expected: 5 tests pass.

**Step 5: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift
git commit -m "feat(zoom): add Zoom struct with scale/pan clamping"
```

### Task 1.2: Cursor-pivot zoom math

This is the load-bearing geometry test from D2.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift`

**Step 1: Write the failing test.**

```swift
// Append to ZoomTests
func test_zoomedToCursor_keeps_source_point_under_cursor() {
    // Cursor at view-relative (0.75, 0.5) — right edge midline.
    // Start at identity; zoom to scale=2 toward the cursor.
    // The source point that was at (0.75, 0.5) before must still be at
    // (0.75, 0.5) in the new viewport.
    let before = Zoom.identity
    let cursor = CGPoint(x: 0.75, y: 0.5)
    let after = before.zoomedToCursor(newScale: 2.0, cursor: cursor)
    let sourcePointBefore = before.sourcePoint(atViewPosition: cursor)
    let sourcePointAfter = after.sourcePoint(atViewPosition: cursor)
    XCTAssertEqual(sourcePointBefore.x, sourcePointAfter.x, accuracy: 1e-9)
    XCTAssertEqual(sourcePointBefore.y, sourcePointAfter.y, accuracy: 1e-9)
}

func test_zoomedToCursor_preserves_cursor_pivot_through_chained_zooms() {
    let cursor = CGPoint(x: 0.3, y: 0.7)
    var z = Zoom.identity
    z = z.zoomedToCursor(newScale: 1.5, cursor: cursor)
    z = z.zoomedToCursor(newScale: 3.0, cursor: cursor)
    let src = z.sourcePoint(atViewPosition: cursor)
    let identitySrc = Zoom.identity.sourcePoint(atViewPosition: cursor)
    XCTAssertEqual(src.x, identitySrc.x, accuracy: 1e-9)
    XCTAssertEqual(src.y, identitySrc.y, accuracy: 1e-9)
}
```

**Step 2: Run, expect fail (`zoomedToCursor` and `sourcePoint` undefined).**

**Step 3: Implement.**

```swift
// Append to Zoom.swift
public extension Zoom {
    /// Source point currently visible at view-relative position
    /// `viewPos` (each component 0...1). Inverse of the rendering transform.
    func sourcePoint(atViewPosition viewPos: CGPoint) -> CGPoint {
        // Visible window in source coordinates: width = 1/scale, centered at
        // 0.5 + pan. So source = (0.5 + pan) + (viewPos - 0.5) / scale.
        CGPoint(
            x: (0.5 + panX) + (Double(viewPos.x) - 0.5) / scale,
            y: (0.5 + panY) + (Double(viewPos.y) - 0.5) / scale
        )
    }

    /// Apply a new scale while keeping the source point under `cursor`
    /// fixed under the cursor. Pan is clamped via `.clamped()`.
    func zoomedToCursor(newScale: Double, cursor: CGPoint) -> Zoom {
        let s2 = max(1.0, min(10.0, newScale))
        guard s2 > 1.0 else { return .identity }
        // Source point under cursor before the zoom (uses self.scale and pan).
        let src = sourcePoint(atViewPosition: cursor)
        // Solve for pan' such that source = src remains under cursor at s2.
        let panX2 = (src.x - (Double(cursor.x) - 0.5) / s2) - 0.5
        let panY2 = (src.y - (Double(cursor.y) - 0.5) / s2) - 0.5
        return Zoom(scale: s2, panX: panX2, panY: panY2).clamped()
    }
}
```

**Step 4: Run tests, expect pass.**

**Step 5: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift
git commit -m "feat(zoom): cursor-pivot zoom math with chained-zoom invariant test"
```

### Task 1.3: Add `.zoom(Zoom)` to `CommentaryEvent.Kind`

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CommentaryEventZoomTests.swift`

**Step 1: Write the failing test (Codable round-trip).**

```swift
import XCTest
@testable import VideoCoachCore

final class CommentaryEventZoomTests: XCTestCase {
    func test_zoom_event_roundtrips_through_codable() throws {
        let original = CommentaryEvent(
            recordTime: 1.5,
            kind: .zoom(Zoom(scale: 2.0, panX: 0.1, panY: -0.05))
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommentaryEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

**Step 2: Run, expect fail (`.zoom` case missing).**

**Step 3: Add the case.**

```swift
// CommentaryEvent.swift
public enum Kind: Codable, Hashable, Sendable {
    case play
    case pause
    case skip(delta: Double)
    case stroke(Stroke)
    case clearAll
    case zoom(Zoom)        // NEW
}
```

**Step 4: Run, expect pass.**

**Step 5: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/CommentaryEventZoomTests.swift
git commit -m "feat(zoom): add .zoom(Zoom) variant to CommentaryEvent.Kind"
```

### Task 1.4: `Clip.zoomAt(recordTime:)` lerp

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/ClipZoomLookup.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ClipZoomLookupTests.swift`

**Step 1: Write the failing tests.**

```swift
import XCTest
@testable import VideoCoachCore

final class ClipZoomLookupTests: XCTestCase {
    private func clip(_ zooms: [(Double, Zoom)]) -> Clip {
        Clip(
            name: "test",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 10,
            recordingFilename: "x.mov",
            events: zooms.map { CommentaryEvent(recordTime: $0.0, kind: .zoom($0.1)) },
            sortIndex: 0
        )
    }

    func test_no_zoom_events_returns_identity() {
        XCTAssertEqual(clip([]).zoomAt(recordTime: 0), .identity)
        XCTAssertEqual(clip([]).zoomAt(recordTime: 99), .identity)
    }

    func test_single_keyframe_holds_for_all_times() {
        let z = Zoom(scale: 2, panX: 0.1, panY: 0)
        let c = clip([(1.0, z)])
        XCTAssertEqual(c.zoomAt(recordTime: 0), z)
        XCTAssertEqual(c.zoomAt(recordTime: 0.5), z)
        XCTAssertEqual(c.zoomAt(recordTime: 5), z)
    }

    func test_lerp_at_midpoint_is_average() {
        let a = Zoom(scale: 1, panX: 0, panY: 0)
        let b = Zoom(scale: 3, panX: 0.2, panY: -0.1)
        let c = clip([(0, a), (2, b)])
        let mid = c.zoomAt(recordTime: 1.0)
        XCTAssertEqual(mid.scale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(mid.panX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(mid.panY, -0.05, accuracy: 1e-9)
    }

    func test_anchor_pattern_produces_snap() {
        // Anchor at t-1ms holding the previous value, new value at t.
        let oldZ = Zoom(scale: 1, panX: 0, panY: 0)
        let newZ = Zoom(scale: 2, panX: 0, panY: 0)
        let c = clip([
            (0, oldZ),
            (5.0 - 0.001, oldZ),  // anchor
            (5.0, newZ),
        ])
        // Just before t: still oldZ.
        XCTAssertEqual(c.zoomAt(recordTime: 4.99).scale, 1.0, accuracy: 1e-3)
        // Just after t: newZ.
        XCTAssertEqual(c.zoomAt(recordTime: 5.01).scale, 2.0, accuracy: 1e-3)
    }

    func test_before_first_event_returns_first_value() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        XCTAssertEqual(clip([(1, z)]).zoomAt(recordTime: 0), z)
    }

    func test_after_last_event_returns_last_value() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        XCTAssertEqual(clip([(1, z)]).zoomAt(recordTime: 99), z)
    }

    func test_ignores_non_zoom_events() {
        let z = Zoom(scale: 2, panX: 0, panY: 0)
        let c = Clip(
            name: "x", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 10, recordingFilename: "x.mov",
            events: [
                CommentaryEvent(recordTime: 0.5, kind: .play),
                CommentaryEvent(recordTime: 1.0, kind: .zoom(z)),
                CommentaryEvent(recordTime: 1.5, kind: .pause),
            ],
            sortIndex: 0
        )
        XCTAssertEqual(c.zoomAt(recordTime: 1.5), z)
    }
}
```

**Step 2: Run, expect fail (`zoomAt` undefined).**

**Step 3: Implement.**

```swift
// apple/VideoCoachCore/Sources/VideoCoachCore/ClipZoomLookup.swift
import Foundation

public extension Clip {
    /// Active Zoom at recordTime t, with linear interpolation between
    /// adjacent keyframes. Empty / before-first → identity (or first
    /// value if any). After-last → last value.
    func zoomAt(recordTime t: Double) -> Zoom {
        var prev: (time: Double, zoom: Zoom)?
        var next: (time: Double, zoom: Zoom)?
        for e in events {
            guard case let .zoom(z) = e.kind else { continue }
            if e.recordTime <= t {
                prev = (e.recordTime, z)
            } else {
                next = (e.recordTime, z)
                break
            }
        }
        switch (prev, next) {
        case (nil, nil):
            return .identity
        case (let p?, nil):
            return p.zoom
        case (nil, let n?):
            return n.zoom
        case (let p?, let n?):
            let span = n.time - p.time
            guard span > 0 else { return n.zoom }
            let alpha = (t - p.time) / span
            return Zoom.lerp(p.zoom, n.zoom, alpha: alpha)
        }
    }
}

public extension Zoom {
    static func lerp(_ a: Zoom, _ b: Zoom, alpha: Double) -> Zoom {
        let t = max(0, min(1, alpha))
        return Zoom(
            scale: a.scale + (b.scale - a.scale) * t,
            panX: a.panX + (b.panX - a.panX) * t,
            panY: a.panY + (b.panY - a.panY) * t
        )
    }
}
```

**Step 4: Run, expect pass.**

**Step 5: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/ClipZoomLookup.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/ClipZoomLookupTests.swift
git commit -m "feat(zoom): Clip.zoomAt(recordTime:) with linear interpolation"
```

### Task 1.5: `Zoom.transform(sourceSize:destSize:)` extension

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift`

**Step 1: Write the failing tests.**

```swift
// Append to ZoomTests.swift
func test_identity_transform_is_letterbox_fit() {
    let src = CGSize(width: 1920, height: 1080)
    let dst = CGSize(width: 1920, height: 1080)
    let t = Zoom.identity.transform(sourceSize: src, destSize: dst)
    // No scaling change, no offset.
    XCTAssertEqual(t.a, 1.0, accuracy: 1e-9)
    XCTAssertEqual(t.d, 1.0, accuracy: 1e-9)
    XCTAssertEqual(t.tx, 0, accuracy: 1e-9)
    XCTAssertEqual(t.ty, 0, accuracy: 1e-9)
}

func test_scale_2_centers_zoomed_source_in_dest() {
    let src = CGSize(width: 1000, height: 500)
    let dst = CGSize(width: 1000, height: 500)
    let z = Zoom(scale: 2, panX: 0, panY: 0)
    let t = z.transform(sourceSize: src, destSize: dst)
    XCTAssertEqual(t.a, 2.0, accuracy: 1e-9)
    // Origin (0,0) of the source must map to (-500, -250) in dest space so
    // the source center stays centered.
    let origin = CGPoint.zero.applying(t)
    XCTAssertEqual(origin.x, -500, accuracy: 1e-9)
    XCTAssertEqual(origin.y, -250, accuracy: 1e-9)
}
```

**Step 2: Run, expect fail.**

**Step 3: Implement.**

```swift
// Append to Zoom.swift
public extension Zoom {
    func transform(sourceSize: CGSize, destSize: CGSize) -> CGAffineTransform {
        let baseScale = min(destSize.width / sourceSize.width,
                            destSize.height / sourceSize.height)
        let s = scale * baseScale
        let dx = (destSize.width - sourceSize.width * s) / 2
        let dy = (destSize.height - sourceSize.height * s) / 2
        let tx = dx - panX * sourceSize.width * s
        let ty = dy - panY * sourceSize.height * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty)
    }
}
```

**Step 4: Run tests, expect pass.**

**Step 5: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift
git commit -m "feat(zoom): Zoom.transform(sourceSize:destSize:) affine helper"
```

---

## Phase 2 — Live state plumbing (Workspace → MPVSourcePlayer)

### Task 2.1: Add `setZoom(_:)` to MPVSourcePlayer

**Files:**
- Modify: `apple/App/Source/MPVSourcePlayer.swift`

**Step 1: Locate the public API section** (search for `public func play()` or similar) and add `setZoom`.

**Step 2: Implement.**

```swift
// Add as a peer of play/pause/setVolume in MPVSourcePlayer.
public func setZoom(_ zoom: Zoom) {
    guard let h = handle else { return }
    // Convert linear scale → log2 (mpv's video-zoom scale).
    var mpvZoom = log2(zoom.scale)
    var px = zoom.panX
    var py = zoom.panY
    mpv_set_property(h, "video-zoom",  MPV_FORMAT_DOUBLE, &mpvZoom)
    mpv_set_property(h, "video-pan-x", MPV_FORMAT_DOUBLE, &px)
    mpv_set_property(h, "video-pan-y", MPV_FORMAT_DOUBLE, &py)
}
```

> **Note:** these are runtime properties (unlike `wid` which is pre-init-only). They can be set repeatedly during playback.

**Step 3: Build to confirm.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit.**

```bash
git add apple/App/Source/MPVSourcePlayer.swift
git commit -m "feat(zoom): MPVSourcePlayer.setZoom writes mpv runtime properties"
```

### Task 2.2: Add `currentZoom` to Workspace

**Files:**
- Modify: `apple/App/Models/Workspace.swift`

**Step 1: Add the observable property.**

Find the existing observable properties (`folder`, `project`, `sourcePlayer`, `missingSourceIndices`) near the top of the class. Add:

```swift
/// Live zoom/pan state for the source-playback view. Ephemeral —
/// not persisted to the project. Reset to identity on workspace switch
/// (which happens by Workspace re-init in openProject).
var currentZoom: Zoom = .identity {
    didSet {
        let clamped = currentZoom.clamped()
        if clamped != currentZoom {
            // didSet runs after the assignment; reassign with the clamped
            // value to keep the public-facing value in canonical form. The
            // reentrant didSet is a no-op because clamped == clamped.clamped().
            currentZoom = clamped
            return
        }
        sourcePlayer?.setZoom(clamped)
    }
}
```

> **Why the reentrant assignment:** SwiftUI/@Observable views that bind `currentZoom` see the canonical clamped value, not whatever the input handler accidentally pushed. The early `return` skips the second mpv write — the second didSet pass propagates correctly.

**Step 2: Add `import VideoCoachCore`** if not already imported.

**Step 3: Build.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
```

**Step 4: Commit.**

```bash
git add apple/App/Models/Workspace.swift
git commit -m "feat(zoom): Workspace.currentZoom observable, propagates to sourcePlayer"
```

---

## Phase 3 — Input handling on `MPVRenderingNSView`

### Task 3.1: scrollWheel routing (mouse wheel → zoom; trackpad swipe → pan)

**Files:**
- Modify: `apple/App/Views/MPVPlayerView.swift`

**Step 1: Add a handler reference.**

`MPVRenderingNSView` is created without a reference back to the workspace. We need one. Two options:
- (a) Pass a closure into `init` (`onZoomChange: (Zoom) -> Void`).
- (b) Have the view read `Workspace` via SwiftUI environment.

Use (a) for both bring-up and production paths because (b) requires environment plumbing that's currently absent.

Modify `MPVRenderingNSView`'s init to accept a closure:

```swift
final class MPVRenderingNSView: NSView {
    private let metalLayer = MPVMetalLayer()
    private var ownedPlayer: MPVSourcePlayer?
    private weak var sharedPlayer: MPVSourcePlayer?

    /// Called whenever the user produces a zoom/pan input. The handler is
    /// expected to clamp and route the new Zoom to MPVSourcePlayer.setZoom.
    /// Bring-up window passes a closure that updates an internal Zoom var
    /// and calls player.setZoom directly. Production passes a closure that
    /// updates Workspace.currentZoom (whose didSet calls setZoom).
    var onZoomChange: ((Zoom) -> Void)?

    /// Most recent Zoom committed by onZoomChange. Mirrored locally so the
    /// view can compute incremental updates (e.g. cursor-pivot zoom needs
    /// the current state to compute the next state).
    private var currentZoom: Zoom = .identity
    // ... existing properties
}
```

Add a public setter:
```swift
@MainActor
func setCurrentZoom(_ zoom: Zoom) { currentZoom = zoom }
```

**Step 2: Implement `scrollWheel(with:)`.**

```swift
override func scrollWheel(with event: NSEvent) {
    let cursor = cursorInBounds(event)
    if event.hasPreciseScrollingDeltas {
        // Trackpad two-finger swipe → pan.
        guard currentZoom.scale > 1.0 else { return }
        // Pan deltas in source-fraction units. Negative dx because dragging
        // right reveals more of the right-hand source.
        let viewW = max(1, bounds.width)
        let viewH = max(1, bounds.height)
        let dx = -event.scrollingDeltaX / (viewW * currentZoom.scale)
        let dy = -event.scrollingDeltaY / (viewH * currentZoom.scale)
        let next = Zoom(
            scale: currentZoom.scale,
            panX: currentZoom.panX + dx,
            panY: currentZoom.panY + dy
        )
        commit(next)
    } else {
        // Coarse mouse wheel → zoom toward cursor.
        let step = 0.1
        let factor = 1.0 + step * (event.scrollingDeltaY > 0 ? 1.0 : -1.0)
        let nextScale = currentZoom.scale * factor
        let next = currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor)
        commit(next)
    }
}

/// Cursor position normalized to [0,1] in view bounds.
private func cursorInBounds(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, from: nil)
    let x = bounds.width > 0 ? p.x / bounds.width : 0.5
    let y = bounds.height > 0 ? (bounds.height - p.y) / bounds.height : 0.5
    return CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
}

private func commit(_ zoom: Zoom) {
    let clamped = zoom.clamped()
    currentZoom = clamped
    onZoomChange?(clamped)
}
```

> **Y-axis note:** AppKit's view-local point has origin at *bottom-left*. For zoom-toward-cursor we want top-left-origin so it matches the source-frame coordinate system. Hence the `bounds.height - p.y` flip.

**Step 3: Build.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
```

**Step 4: Commit.**

```bash
git add apple/App/Views/MPVPlayerView.swift
git commit -m "feat(zoom): scrollWheel handler — mouse wheel zooms, trackpad swipe pans"
```

### Task 3.2: `magnify(with:)` for trackpad pinch

**Files:**
- Modify: `apple/App/Views/MPVPlayerView.swift`

**Step 1: Implement.**

```swift
override func magnify(with event: NSEvent) {
    let cursor = cursorInBounds(event)
    // event.magnification is a delta (-1...1 typical per gesture step).
    // Compounding into scale: nextScale = scale * (1 + magnification).
    let nextScale = currentZoom.scale * (1.0 + event.magnification)
    let next = currentZoom.zoomedToCursor(newScale: nextScale, cursor: cursor)
    commit(next)
}
```

**Step 2: Build + commit.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
git add apple/App/Views/MPVPlayerView.swift
git commit -m "feat(zoom): magnify(with:) — trackpad pinch zooms toward cursor"
```

### Task 3.3: Mouse drag-to-pan with click-vs-drag threshold

**Files:**
- Modify: `apple/App/Views/MPVPlayerView.swift`

**Step 1: Add state for the gesture.**

```swift
private var dragAnchor: CGPoint?       // mouseDown location, in view local coords
private var dragStartZoom: Zoom?       // zoom at mouseDown
private var didCrossDragThreshold: Bool = false
private static let dragThresholdSqr: CGFloat = 16  // 4 px squared
```

**Step 2: Replace existing `mouseDown(with:)` and add `mouseDragged` + `mouseUp`.**

```swift
override func mouseDown(with event: NSEvent) {
    dragAnchor = convert(event.locationInWindow, from: nil)
    dragStartZoom = currentZoom
    didCrossDragThreshold = false
    // Do NOT grab first-responder yet — defer until mouseUp without drag.
    // (The existing first-responder steal is moved out of mouseDown.)
}

override func mouseDragged(with event: NSEvent) {
    guard let anchor = dragAnchor, let startZoom = dragStartZoom,
          startZoom.scale > 1.0 else { return }
    let now = convert(event.locationInWindow, from: nil)
    let dx = now.x - anchor.x
    let dy = now.y - anchor.y
    if !didCrossDragThreshold && dx * dx + dy * dy < Self.dragThresholdSqr {
        return
    }
    didCrossDragThreshold = true
    // Pan delta: dragging right reveals more of right-hand source, so pan
    // moves in the opposite direction from the cursor.
    let viewW = max(1, bounds.width)
    let viewH = max(1, bounds.height)
    let nextPanX = startZoom.panX - (dx / (viewW * startZoom.scale))
    let nextPanY = startZoom.panY + (dy / (viewH * startZoom.scale))  // y-axis flip
    let next = Zoom(scale: startZoom.scale, panX: nextPanX, panY: nextPanY)
    commit(next)
}

override func mouseUp(with event: NSEvent) {
    if !didCrossDragThreshold {
        // Plain click — original first-responder grab semantics.
        window?.makeFirstResponder(self)
    }
    dragAnchor = nil
    dragStartZoom = nil
    didCrossDragThreshold = false
}
```

**Step 3: Build.**

**Step 4: Commit.**

```bash
git add apple/App/Views/MPVPlayerView.swift
git commit -m "feat(zoom): mouse drag-to-pan with 4px click-vs-drag threshold"
```

### Task 3.4: Wire bring-up window + production representable to push to Workspace

**Files:**
- Modify: `apple/App/Views/MPVPlayerView.swift` (bring-up rep)
- Modify: `apple/App/ContentView.swift` (production rep)

**Step 1: Bring-up window's `MPVDebugRepresentable` already creates an owned player.** Configure `onZoomChange` in `bringUp`:

```swift
@MainActor
func bringUp(filePath: String, hwdec: String) throws {
    let p = MPVSourcePlayer(audioOff: true)
    try p.attachLayer(metalLayer)
    p.setPlaylist([filePath])
    p.play()
    self.ownedPlayer = p
    // Local zoom state for the bring-up window.
    self.onZoomChange = { [weak p, weak self] z in
        guard let self else { return }
        self.setCurrentZoom(z)
        p?.setZoom(z)
    }
}
```

**Step 2: Production representable (`MPVPlayerView`) wires through Workspace.**

Modify `MPVPlayerView` to take a closure parameter:

```swift
struct MPVPlayerView: NSViewRepresentable {
    let player: MPVSourcePlayer?
    let onZoomChange: (Zoom) -> Void
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        v.updatePlayer(player)
        v.onZoomChange = onZoomChange
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {
        nsView.updatePlayer(player)
        nsView.onZoomChange = onZoomChange
    }
}
```

In `ContentView` where `MPVPlayerView(player:)` is constructed, change the call site to pass the workspace closure:

```swift
MPVPlayerView(player: workspace.sourcePlayer) { newZoom in
    workspace.currentZoom = newZoom
}
```

> Find the existing `MPVPlayerView(player:` call site with `grep -n 'MPVPlayerView(player' apple/App/ContentView.swift`.

**Step 3: Build, run XCUITest as a smoke check.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels 2>&1 | tail -3
```
Expected: build green, existing test still green (we haven't broken anything).

**Step 4: Commit.**

```bash
git add apple/App/Views/MPVPlayerView.swift apple/App/ContentView.swift
git commit -m "feat(zoom): wire view zoom events into Workspace.currentZoom"
```

### Task 3.5: ⌘0 reset shortcut

**Files:**
- Modify: `apple/App/Views/KeyCommandView.swift`

**Step 1: Read the file** to understand existing key-handling structure (likely an `NSView` overlay with `keyDown(with:)`). Add a case for `event.charactersIgnoringModifiers == "0"` AND `event.modifierFlags.contains(.command)`:

```swift
// Inside keyDown(with:), alongside existing shortcut checks
if event.modifierFlags.contains(.command),
   event.charactersIgnoringModifiers == "0" {
    onResetZoom?()
    return
}
```

Add a property `var onResetZoom: (() -> Void)?` and wire it from the production view path to set `workspace.currentZoom = .identity`.

**Step 2: Build + commit.**

```bash
cd apple && xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64' 2>&1 | tail -3
git add apple/App/Views/KeyCommandView.swift apple/App/ContentView.swift
git commit -m "feat(zoom): ⌘0 resets zoom to identity"
```

---

## Phase 4 — Recording capture

### Task 4.1: `RecordingController.appendZoom` with anchor pattern

**Files:**
- Modify: `apple/App/Recording/RecordingController.swift`
- Create: `apple/App/Recording/RecordingZoomCaptureTests.swift` (tested via VideoCoachCore unit tests if `RecordingController` were there; since it's app-target, add a logic-test subclass under `apple/Tests/AppTests/RecordingZoomCaptureTests.swift` instead)

**Step 1: Write the failing test.**

Place at `apple/Tests/AppTests/RecordingZoomCaptureTests.swift`. The `VideoCoachTests` target compiles app-target sources directly into the test bundle (per the precedent set during the Path A render swap), so no host-app needed.

```swift
import XCTest
import VideoCoachCore
@testable import VideoCoach   // app target

final class RecordingZoomCaptureTests: XCTestCase {
    func test_inherit_at_t0_emits_initial_zoom_event() {
        let rc = RecordingController(t0Seconds: 0)
        let initial = Zoom(scale: 2.0, panX: 0.1, panY: 0)
        rc.appendInitialZoom(initial)  // called at start-of-recording
        let events = rc.finish()
        XCTAssertEqual(events.count, 1)
        if case let .zoom(z) = events[0].kind {
            XCTAssertEqual(z, initial)
            XCTAssertEqual(events[0].recordTime, 0, accuracy: 1e-9)
        } else {
            XCTFail("Expected .zoom event")
        }
    }

    func test_continuous_capture_emits_keyframes_without_anchor() {
        // Two appends 50ms apart should produce just two keyframes (no anchor).
        let rc = RecordingController(t0Seconds: 0)
        rc.appendInitialZoom(.identity)
        // Inject a fake "now" by supplying recordTime explicitly:
        rc.appendZoom(Zoom(scale: 1.5, panX: 0, panY: 0), atRecordTime: 0.05)
        rc.appendZoom(Zoom(scale: 2.0, panX: 0, panY: 0), atRecordTime: 0.10)
        XCTAssertEqual(rc.finish().filter { if case .zoom = $0.kind { return true } else { return false } }.count, 3)
    }

    func test_discrete_change_after_quiet_period_emits_anchor_keyframe() {
        let rc = RecordingController(t0Seconds: 0)
        rc.appendInitialZoom(.identity)
        // After a 5-second quiet period, a single zoom event must be preceded
        // by an anchor keyframe holding the previous value at t-1ms.
        rc.appendZoom(Zoom(scale: 2.0, panX: 0, panY: 0), atRecordTime: 5.0)
        let zooms = rc.finish().filter { if case .zoom = $0.kind { return true } else { return false } }
        XCTAssertEqual(zooms.count, 3)  // initial + anchor + new
        XCTAssertEqual(zooms[1].recordTime, 4.999, accuracy: 1e-6)
        if case let .zoom(z) = zooms[1].kind {
            XCTAssertEqual(z, .identity)  // anchor holds previous value
        } else {
            XCTFail()
        }
    }
}
```

**Step 2: Run, expect fail.**

```bash
cd apple && xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachTests/RecordingZoomCaptureTests
```

**Step 3: Implement.**

```swift
// Append to RecordingController.swift
private var lastCapturedZoom: Zoom = .identity
private var lastCaptureTime: Double = -.infinity

/// Called at start-of-recording with the inherited zoom from
/// Workspace.currentZoom. Always emits a .zoom event at recordTime=0.
func appendInitialZoom(_ z: Zoom) {
    events.append(.init(recordTime: 0, kind: .zoom(z)))
    lastCapturedZoom = z
    lastCaptureTime = 0
}

/// Test seam — production path uses `appendZoom(_:)` which reads `now`.
func appendZoom(_ z: Zoom, atRecordTime t: Double) {
    if t - lastCaptureTime > 0.1 {
        events.append(.init(recordTime: t - 0.001, kind: .zoom(lastCapturedZoom)))
    }
    events.append(.init(recordTime: t, kind: .zoom(z)))
    lastCapturedZoom = z
    lastCaptureTime = t
}

func appendZoom(_ z: Zoom) {
    appendZoom(z, atRecordTime: now)
}
```

**Step 4: Run tests, expect pass.**

**Step 5: Commit.**

```bash
git add apple/App/Recording/RecordingController.swift \
        apple/Tests/AppTests/RecordingZoomCaptureTests.swift
git commit -m "feat(zoom): RecordingController.appendZoom with anchor pattern"
```

### Task 4.2: Hook recording start + ongoing zoom changes

**Files:**
- Modify: wherever `RecordingController` is created (search for `RecordingController(t0Seconds:`)
- Modify: `apple/App/Models/Workspace.swift` (the `currentZoom.didSet`)

**Step 1: Find the recording-start site.**

```bash
grep -rn 'RecordingController(t0Seconds' apple/App
```
Expected: a single call site (likely in `ContentView.swift` or similar).

**Step 2: Modify the call site so the new controller's first action is `appendInitialZoom(workspace.currentZoom)`.** Concretely:

```swift
let rc = RecordingController(t0Seconds: t0)
rc.appendInitialZoom(workspace.currentZoom)
workspace.recordingController = rc   // or however it's stored
```

**Step 3: In `Workspace.currentZoom.didSet`, ALSO call `recordingController?.appendZoom(clamped)`** if recording is active. The expanded didSet:

```swift
var currentZoom: Zoom = .identity {
    didSet {
        let clamped = currentZoom.clamped()
        if clamped != currentZoom {
            currentZoom = clamped
            return
        }
        sourcePlayer?.setZoom(clamped)
        recordingController?.appendZoom(clamped)
    }
}
```

**Step 4: Build, run RecordingZoomCaptureTests as a smoke check, plus the existing recording integration tests if any.**

**Step 5: Commit.**

```bash
git add apple/App/Models/Workspace.swift apple/App/<call-site>.swift
git commit -m "feat(zoom): inherit at recording start; capture ongoing changes"
```

---

## Phase 5 — Preview + export integration

### Task 5.1: PreviewCompositor applies zoom transform per frame

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift`

**Step 1: Find the per-frame source-draw site.** Search inside `PreviewCompositor.startRequest(_:)` for where the source frame is composited (likely a `ctx.draw(...)` or a CIImage transform chain).

**Step 2: Apply the zoom transform.**

Compute zoom + transform once per frame:

```swift
let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
let zoom = clip.zoomAt(recordTime: recordTime)
let zoomXform = zoom.transform(sourceSize: sourceSize, destSize: outputSize)
// Apply zoomXform to source pixels before drawing strokes/text on top.
```

The exact integration depends on whether PreviewCompositor uses CGContext or CIImage:
- **CGContext path:** wrap the existing `ctx.draw(image, in: rect)` in `ctx.saveGState() / ctx.concatenate(zoomXform) / ctx.draw(...) / ctx.restoreGState()`.
- **CIImage path:** `let zoomed = sourceCIImage.transformed(by: zoomXform); ctx.draw(zoomed, ...)`.

**Step 3: Build + run any existing PreviewCompositor tests (smoke).**

```bash
cd apple && swift test --package-path VideoCoachCore --filter PreviewCompositor
```

**Step 4: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift
git commit -m "feat(zoom): PreviewCompositor applies per-frame zoom transform"
```

### Task 5.2: CompilationCompositor pixel test (TDD-first)

**Files:**
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationCompositorZoomTests.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`

**Step 1: Write the failing pixel-content test** using the existing `SyntheticAsset.swift` + `PixelSampling.swift` helpers.

```swift
import XCTest
@testable import VideoCoachCore

final class CompilationCompositorZoomTests: XCTestCase {
    func test_zoom_2x_centered_shows_only_center_quadrant_of_source() async throws {
        // Build a synthetic source that's red top-left quadrant + blue
        // everywhere else. At zoom=2 panX=0 panY=0, the visible viewport
        // is the center quadrant of the source — neither pure red nor
        // pure blue. We sample the center of the output and assert it's
        // blue (the corner is cut off).
        // ... uses SyntheticAsset.swift to generate the input
        // ... runs through CompilationCompositor with one clip + one zoom keyframe
        // ... PixelSampling.swift to read the output center pixel
        XCTFail("Implement once Compositor zoom integration lands")
    }
}
```

**Step 2: Run, expect XCTFail.**

**Step 3: Wire zoom into `CompilationCompositor.startRequest(_:)`** following the same pattern as Task 5.1 (PreviewCompositor). Reference the design doc D4 for the affine transform site.

**Step 4: Implement the test body.** Build a synthetic source via `SyntheticAsset.swift`'s helpers, configure a `Clip` with a single `.zoom(Zoom(scale: 2, ...))` event, run the compositor, assert pixels.

**Step 5: Run, expect pass.**

**Step 6: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationCompositorZoomTests.swift
git commit -m "feat(zoom): CompilationCompositor applies per-frame zoom transform"
```

---

## Phase 6 — Live-playback XCUITest

### Task 6.1: `MPVZoomPlaybackTests/testScrollZoomsBringUpWindow`

**Files:**
- Create: `apple/AppUITests/MPVZoomPlaybackTests.swift`

**Step 1: Write the test.**

```swift
import XCTest

final class MPVZoomPlaybackTests: XCTestCase {
    func testScrollZoomsBringUpWindow() throws {
        let app = XCUIApplication()
        app.launch()

        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open MPV Bring-up Window"].click()
        let bringUp = app.windows.matching(NSPredicate(format: "title == %@", "MPV Bring-up")).firstMatch
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)

        // Capture before-zoom screenshot.
        app.activate()
        bringUp.click()
        let before = bringUp.screenshot()

        // Synthesize 5 mouse-wheel notches over the bring-up window.
        let center = bringUp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<5 {
            // CGEvent for scroll.
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: 10, wheel2: 0, wheel3: 0) {
                e.location = NSEvent.mouseLocation  // approximate
                e.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let after = bringUp.screenshot()

        // Assert pixel content shifted — sample a fixed view-relative
        // position; before vs after pixels should differ (zoom changed
        // what's visible there).
        XCTAssertNotEqual(samplePixel(before, atFraction: CGPoint(x: 0.1, y: 0.5)),
                          samplePixel(after,  atFraction: CGPoint(x: 0.1, y: 0.5)),
                          "Scroll did not change visible pixels — zoom not wired")
    }

    private func samplePixel(_ s: XCUIScreenshot, atFraction p: CGPoint) -> [UInt8] {
        // Implementation: convert XCUIScreenshot.image to CGImage, sample
        // 1 pixel via a 1×1 CGContext bitmap, return [B,G,R,A] bytes.
        // Mirrors hasNonBlackPixels in MPVMountRemountTests.
        // ... full body here
        return [0, 0, 0, 0]  // implementer fills in
    }
}
```

**Step 2: Run.**

```bash
cd apple && xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVZoomPlaybackTests/testScrollZoomsBringUpWindow
```
Expected: PASS. If macOS automation gate blocks, fall back to manual screencap (same precedent as render-path Phase 4.2).

**Step 3: Commit.**

```bash
git add apple/AppUITests/MPVZoomPlaybackTests.swift
git commit -m "test(zoom): XCUITest synthesizes scroll, asserts pixels shifted"
```

---

## Phase 7 — Manual smoke + acceptance

### Task 7.1: Manual gesture verification

Cannot be automated. Launch the app, open a project, and verify:

1. **Mouse scroll wheel** zooms in/out on the source-playback view, pivoting around the cursor. ⌘0 resets.
2. **Trackpad pinch** zooms in/out, pivoting around the gesture location.
3. **Trackpad two-finger swipe** pans (only when zoomed in; no-op at scale=1).
4. **Mouse drag** (left-click + drag, when zoomed) pans. Plain click (no drag) still focuses the view (TextField focus-out works).
5. **Recording while zoomed** preserves the zoom in the saved clip — open the clip's preview after recording, scrub, see the same zoom you authored.
6. **Pan during recording** is replayed in the preview.
7. **Export** an exported file from a clip with zoom keyframes; play the export externally; verify the zoom is baked in.

If any step fails, capture which one and what you saw, then triage.

### Task 7.2: Final commit + branch ready

If everything passed, commit any small fixes from manual smoke and the branch is ready to PR back.

---

## Things this plan does NOT cover (intentional)

- **Tweening curves** other than linear. Linear lerp + the anchor pattern is the v1.
- **Per-event easing** flag in the data model. Snap behavior is implemented via the anchor pattern.
- **Zoom on the PiP webcam track.** Out of scope; webcam stays unzoomed.
- **Persisting `Workspace.currentZoom` to UserDefaults across sessions.** Ephemeral by design.
- **Non-source-track export effects** (no zoom on commentary text bars or strokes — those overlay at full output size, unchanged).

---

## Execution handoff

Plan complete and saved to `apple/docs/plans/2026-05-01-video-zoom.md`. Two execution options:

**1. Subagent-Driven (this session)** — orchestrator dispatches per task, reviews between tasks, fast iteration.

**2. Parallel Session** — open a new session with `superpowers:executing-plans`.
