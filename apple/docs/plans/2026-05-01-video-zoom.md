# Video Zoom + Pan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the zoom/pan feature designed in `apple/docs/plans/2026-05-01-video-zoom-design.md` — interactive zoom on the source-playback view (mouse + trackpad), keyframed capture during recording, replay during clip preview and export.

**Architecture:** New `Zoom` struct in `VideoCoachCore` plus a `.zoom(Zoom)` variant of `CommentaryEvent.Kind`. `Workspace.currentZoom` is the live state observed by `MPVRenderingNSView`, which writes mpv's `video-zoom` / `video-pan-x` / `video-pan-y` runtime properties. `RecordingController.appendZoom` captures keyframes with an anchor pattern (two keyframes 1ms apart for discrete events). `Clip.zoomAt(recordTime:)` linearly interpolates between keyframes. `PreviewCompositor` and `CompilationCompositor` each gain a one-line `let zoom = clip.zoomAt(recordTime: ...)` plus a shared `Zoom.transform(sourceSize:destSize:)` extension applied to the source frame.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, AppKit (NSEvent gesture handlers), libmpv runtime properties via MPVKit, AVFoundation (`AVVideoCompositing`).

**Branch:** `feat/video-zoom` (off `feat/source-playback-metal-direct` at `c72c27b`).

**Companion document:** `apple/docs/plans/2026-05-01-video-zoom-design.md` — read this first for the *why* behind every decision (D1–D9). This plan covers the *what* and *how*.

---

## Adversarial review history (plan v1 → v2)

The first draft was reviewed by `feature-dev:code-reviewer`. Findings folded into v2 (this document) before any execution:

| Finding | Where it lives now |
|---------|-------------------|
| **mpv `video-pan-x`/`video-pan-y` are fractions of the *unzoomed* fit-width, not of the source.** At scale=2, passing raw `panX=0.25` lands the visual center at source ~0.625, not the intended 0.75 (mpv issue #3038). The pure-Swift math tests pass; the mpv translation is wrong. | Task 2.1 — `setZoom` now multiplies by scale before writing: `var px = zoom.panX * zoom.scale`. The unit conversion is documented in the function comment with a reference to mpv issue #3038. |
| **`PreviewCompositor` is a pure CIImage pipeline; the plan's "CGContext path" note primes the implementer for the wrong code.** Additionally, `Zoom.transform` uses letterbox-fit (`min`); the existing PreviewCompositor stretches to fill (`outW/baseCI.extent.width × outH/...`). Applying the transform at identity silently changes preview from stretch to letterbox. | Task 5.1 — rewritten to specify the CIImage path exclusively. `Zoom.transform` keeps letterbox-fit semantics; PreviewCompositor's existing stretch is preserved by composing zoom AS A DELTA (`zoom.deltaTransform(...)`) on top of the existing layout transform, so identity zoom is bit-identical to current output. |
| **`Workspace.currentZoom` didSet reentrancy is fragile and intersects an open `@Observable` macro bug** (Apple Developer Forums 731113). | Task 2.2 — replaced with an explicit `setCurrentZoom(_:)` method on `Workspace`. Backing storage is `@ObservationIgnored _currentZoom`; the public `var currentZoom: Zoom` has a custom getter/setter that delegates. No reentrant didSet. |
| **`appendZoom(_:atRecordTime:)` test seam is a public API surface that production code can accidentally call with arbitrary timestamps, breaking monotonicity assumptions in `zoomAt(recordTime:)`.** | Task 4.1 — clock injection instead. `RecordingController.init(t0Seconds: Double, clock: @escaping () -> Double = { CACurrentMediaTime() })`. Tests inject a fake clock; production uses the default. The two-argument overload disappears. |
| **`CommentaryEvent.Kind.zoom` Codable: old builds will crash with `DecodingError.dataCorrupted` when reading new project files containing zoom events** — Swift's synthesized Codable for enums throws on unknown discriminators. | Task 1.3 — adds a manual `init(from:)` on `CommentaryEvent.Kind` with an explicit `case unknown` fallback for unrecognized variants. The `Clip` event-array decoder skips `.unknown` events at replay time. `Project.formatVersion` bumps to 2. |
| **`CompilationCompositor` at identity zoom changes export from stretch-to-fill to letterbox-fit for non-matching aspect ratios** — same silent behavior change as PreviewCompositor. | Task 5.2 — same `deltaTransform` pattern as Task 5.1. Existing stretch policy is preserved at identity; non-identity zoom applies the delta on top. The design doc D4's "bit-identical" claim is now actually true. |
| **Scroll-direction inversion not documented**; future readers can't tell if the deltaY-based zoom direction is intentional. | Task 3.1 — explanatory comment in `scrollWheel(with:)` body referencing the macOS natural-scrolling convention. |
| **`MPVRenderingNSView.setCurrentZoom` is dead code unless ContentView calls back after Workspace clamping.** | Task 3.4 — `updateNSView` in the production representable explicitly calls `nsView.setCurrentZoom(workspace.currentZoom)` so the view's local mirror stays canonical after clamping. |

---

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

### Task 1.3: Add `.zoom(Zoom)` to `CommentaryEvent.Kind` with backward-compat decoder

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` (formatVersion bump)
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CommentaryEventZoomTests.swift`

**Step 1: Write the failing tests.**

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

    func test_unknown_kind_decodes_as_unknown_case_not_error() throws {
        // Simulates a future build's project file with a kind discriminator
        // we don't recognize. Old builds must not crash on this.
        let json = #"""
        {"recordTime":1.0,"kind":{"futureKind":{"someField":42}}}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CommentaryEvent.self, from: json)
        if case .unknown = decoded.kind {
            // Pass.
        } else {
            XCTFail("Expected .unknown for future discriminator, got \(decoded.kind)")
        }
    }

    func test_unknown_kind_does_not_appear_in_zoom_lookup() {
        let unknown = CommentaryEvent(recordTime: 1.0, kind: .unknown)
        let zoom = CommentaryEvent(recordTime: 2.0, kind: .zoom(Zoom(scale: 2, panX: 0, panY: 0)))
        let c = Clip(name: "x", sourceIndex: 0, startSourceSeconds: 0,
                     recordingDuration: 5, recordingFilename: "x.mov",
                     events: [unknown, zoom], sortIndex: 0)
        XCTAssertEqual(c.zoomAt(recordTime: 3.0).scale, 2.0, accuracy: 1e-9)
    }
}
```

**Step 2: Run, expect fail.**

**Step 3: Add the case + manual decoder.**

```swift
// apple/VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift
import Foundation

public struct CommentaryEvent: Codable, Hashable, Sendable {
    public var recordTime: Double
    public var kind: Kind
    public init(recordTime: Double, kind: Kind) {
        self.recordTime = recordTime
        self.kind = kind
    }

    public enum Kind: Hashable, Sendable {
        case play
        case pause
        case skip(delta: Double)
        case stroke(Stroke)
        case clearAll
        case zoom(Zoom)        // NEW
        case unknown           // Forward-compat: future kinds we don't recognize
    }
}

// Manual Codable for Kind so unknown discriminators decode as .unknown
// instead of throwing DecodingError.dataCorrupted. Old builds opening
// new project files don't crash on .zoom or any future variant.
extension CommentaryEvent.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case play, pause, skip, stroke, clearAll, zoom
    }
    private struct SkipPayload: Codable { let delta: Double }

    public init(from decoder: Decoder) throws {
        // Match Swift's auto-synth: enums with associated values are emitted
        // as a single-key dictionary {"caseName": <payload>} (or {"caseName": {}}
        // for no-payload cases).
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.play)     { self = .play; return }
        if container.contains(.pause)    { self = .pause; return }
        if container.contains(.clearAll) { self = .clearAll; return }
        if let s = try? container.decode(SkipPayload.self, forKey: .skip) {
            self = .skip(delta: s.delta); return
        }
        if let stroke = try? container.decode(Stroke.self, forKey: .stroke) {
            self = .stroke(stroke); return
        }
        if let z = try? container.decode(Zoom.self, forKey: .zoom) {
            self = .zoom(z); return
        }
        // Unknown discriminator → graceful skip instead of crash.
        self = .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .play:       try container.encode([String:String](), forKey: .play)
        case .pause:      try container.encode([String:String](), forKey: .pause)
        case .clearAll:   try container.encode([String:String](), forKey: .clearAll)
        case .skip(let d): try container.encode(SkipPayload(delta: d), forKey: .skip)
        case .stroke(let s): try container.encode(s, forKey: .stroke)
        case .zoom(let z):   try container.encode(z, forKey: .zoom)
        case .unknown:
            // Don't write .unknown back — it represents a kind we couldn't
            // decode, so we can't faithfully re-encode it. Drop on save.
            // (Old builds opening new files don't save them right back; if
            // they DO, the unknown event silently drops, which is acceptable.)
            break
        }
    }
}
```

> **Note on the auto-synth compat:** Swift's automatic enum Codable emits `{"play": {}}` (empty object, not `null`) for no-payload cases. The dummy `[String:String]()` above matches that on encode and the `container.contains(.play)` matches it on decode regardless of whether the payload is `{}` or `null`. Verify against an existing encoded project file before final commit.

**Step 4: Bump format version.**

```swift
// Project.swift
public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int = 2  // was 1; bumped for .zoom event variant
    // ...
}
```

**Step 5: Modify `Clip.zoomAt(recordTime:)` from Task 1.4 to skip `.unknown` events** (the implementer adjusts the `case let .zoom(z) = e.kind` switch to add a default that ignores `.unknown`; existing tests still pass).

**Step 6: Run all tests in the package, expect pass.**

```bash
cd apple && swift test --package-path VideoCoachCore
```

**Step 7: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift \
        apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/CommentaryEventZoomTests.swift
git commit -m "feat(zoom): .zoom(Zoom) + .unknown variant for forward-compat decoding"
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
    // mpv's video-zoom is logarithmic (each unit = 2x). Our Zoom.scale is
    // linear, so log2 the scale.
    var mpvZoom = log2(zoom.scale)
    // mpv's video-pan-x/-y are fractions of the UNZOOMED fit-width, NOT of
    // the source. To get zoom-invariant panning that matches our convention
    // (pan is a fraction of source width, centered), multiply by scale before
    // writing. See mpv issue #3038 for the mpv-side rationale; the
    // adversarial-review history at the top of this plan documents the bug
    // this conversion fixes.
    var px = zoom.panX * zoom.scale
    var py = zoom.panY * zoom.scale
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

### Task 2.2: Add `currentZoom` to Workspace via explicit setter

**Files:**
- Modify: `apple/App/Models/Workspace.swift`

**Step 1: Add the observable property + setter** (avoiding the reentrant-didSet pattern that intersects an open `@Observable` macro bug — see the v2 review history).

Find the existing observable properties (`folder`, `project`, `sourcePlayer`, `missingSourceIndices`) near the top of the class. Add:

```swift
/// Live zoom/pan state for the source-playback view. Ephemeral —
/// not persisted to the project. Reset to identity on workspace switch
/// (which happens by Workspace re-init in openProject).
///
/// Backed by a private stored property; mutate via `setCurrentZoom(_:)`
/// (or assign via the computed setter, which delegates). The setter
/// clamps the input to the valid range, propagates to mpv, and emits a
/// keyframe to the in-progress recording (if any).
@ObservationIgnored
private var _currentZoom: Zoom = .identity

var currentZoom: Zoom {
    get { _currentZoom }
    set { setCurrentZoom(newValue) }
}

func setCurrentZoom(_ zoom: Zoom) {
    let clamped = zoom.clamped()
    guard clamped != _currentZoom else { return }
    // @Observable observes via the computed property's getter; touch it.
    self._currentZoom = clamped  // ← @Observable's macro wraps this; binding readers
                                 //    re-fire because the computed getter returns
                                 //    the new value.
    sourcePlayer?.setZoom(clamped)
    recordingController?.appendZoom(clamped)
}
```

> **Why the explicit setter:** the v1 plan used a reentrant didSet that re-assigned a clamped value. The reviewer flagged that this pattern (a) intersects an open `@Observable` macro bug where `didSet` doesn't always fire as expected, and (b) is fragile — any future caller who reads `currentZoom` from inside the didSet would see a transient unclamped value. The explicit setter pattern eliminates both issues. Test bindings still work: SwiftUI views that read `currentZoom` re-render when `_currentZoom` changes (via the `@Observable` macro's tracking on the computed-property getter).

**Step 2: Add the `recordingController` reference** (assuming it doesn't exist yet on Workspace; if it does, skip):

```swift
@ObservationIgnored
weak var recordingController: RecordingController?
```

This is set by ContentView when recording starts; cleared when recording stops. Weak so the controller isn't kept alive past its natural end.

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
        // Direction: positive scrollingDeltaY = swipe up = expose more of top
        // (so the visible center moves toward smaller y in source). The flip
        // already incorporates the user's natural-scrolling preference; mpv
        // and Apple's docs both treat scrollingDeltaY as content-direction.
        guard currentZoom.scale > 1.0 else { return }
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
        // Direction: scrollingDeltaY > 0 = wheel scrolled up (away from user)
        // = zoom IN. This matches Maps, Safari, Final Cut, every macOS app
        // that supports wheel-to-zoom. macOS's natural-scrolling preference
        // is already baked into scrollingDeltaY; we don't read
        // isDirectionInvertedFromDevice separately. (Verified against reviewer
        // finding 7 in v2 review history.)
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
    let currentZoom: Zoom               // workspace-canonical (clamped) value
    let onZoomChange: (Zoom) -> Void
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        v.updatePlayer(player)
        v.onZoomChange = onZoomChange
        v.setCurrentZoom(currentZoom)
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {
        nsView.updatePlayer(player)
        nsView.onZoomChange = onZoomChange
        // Sync the view's local Zoom mirror with the workspace canonical
        // (clamped) value after every body re-eval. Without this, the view's
        // internal mirror diverges from Workspace state at clamp boundaries
        // and the next gesture computes from stale state. (Reviewer finding 8.)
        nsView.setCurrentZoom(currentZoom)
    }
}
```

In `ContentView` where `MPVPlayerView(player:)` is constructed, change the call site to pass the workspace closure:

```swift
MPVPlayerView(
    player: workspace.sourcePlayer,
    currentZoom: workspace.currentZoom,
    onZoomChange: { newZoom in workspace.currentZoom = newZoom }
)
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

**Step 3: Implement with clock injection (no public time-override seam).**

Modify `RecordingController.init` to accept an injectable clock:

```swift
@MainActor
final class RecordingController {
    let t0Seconds: Double
    private let clock: () -> Double          // NEW: injectable for tests
    private(set) var events: [CommentaryEvent] = []
    private var lastCapturedZoom: Zoom = .identity
    private var lastCaptureTime: Double = -.infinity

    init(t0Seconds: Double, clock: @escaping () -> Double = { CACurrentMediaTime() }) {
        self.t0Seconds = t0Seconds
        self.clock = clock
    }

    private var now: Double { clock() - t0Seconds }

    // Existing append methods keep using `now` (which now goes through clock).
    // ...

    /// Called at start-of-recording with the inherited zoom from
    /// Workspace.currentZoom. Always emits a .zoom event at recordTime=0.
    func appendInitialZoom(_ z: Zoom) {
        events.append(.init(recordTime: 0, kind: .zoom(z)))
        lastCapturedZoom = z
        lastCaptureTime = 0
    }

    /// Append a zoom keyframe at the current recordTime (via injected clock).
    /// If the gap since the last capture is > 100ms, emit an anchor keyframe
    /// at (now - 1ms) holding the previous value, so lerp lookup produces a
    /// snap rather than drifting backward through a quiet period.
    func appendZoom(_ z: Zoom) {
        let t = now
        if t - lastCaptureTime > 0.1 {
            events.append(.init(recordTime: t - 0.001, kind: .zoom(lastCapturedZoom)))
        }
        events.append(.init(recordTime: t, kind: .zoom(z)))
        lastCapturedZoom = z
        lastCaptureTime = t
    }
}
```

> **Why the clock injection** (rather than the v1 plan's `appendZoom(_:atRecordTime:)` overload): production code can't accidentally call into the time-override path because it doesn't exist. Tests inject a closure (e.g. `var t = 0.0; let rc = RecordingController(t0Seconds: 0, clock: { t })` and step `t` between calls). Reviewer finding 4 fixed.

The earlier `RecordingZoomCaptureTests` need a small update to use the clock-injection seam. Replace `rc.appendZoom(zoom, atRecordTime: t)` with:

```swift
var clockTime = 0.0
let rc = RecordingController(t0Seconds: 0, clock: { clockTime })
rc.appendInitialZoom(.identity)
clockTime = 5.0
rc.appendZoom(Zoom(scale: 2.0, panX: 0, panY: 0))
// assertions...
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

### Task 5.1: PreviewCompositor applies zoom delta-transform per frame (CIImage path)

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift` — add `deltaTransform`.
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift`.

> **Important** (reviewer finding 2): `PreviewCompositor` is a **pure CIImage pipeline**. It does NOT use a `CGContext`. Read `apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift` first; the integration point is wherever the source CIImage is transformed before being composited with overlays.
>
> Additionally, the existing PreviewCompositor stretches source-to-output (non-uniform). `Zoom.transform(sourceSize:destSize:)` is a letterbox-fit transform — applying it at identity would silently change preview from stretch-to-fill to letterbox-fit. To preserve identity-equivalence, apply zoom as a DELTA on top of the existing layout transform, rather than replacing it.

**Step 1: Add a `deltaTransform` helper to `Zoom`** that captures only the zoom-and-pan portion (no base scale):

```swift
// Append to Zoom.swift
public extension Zoom {
    /// Zoom-and-pan delta in normalized [0,1] viewport coordinates,
    /// to be applied AFTER any existing layout transform. At identity,
    /// returns the identity transform (no behavior change for existing
    /// compositors). At scale=2, panX=0.1: scale up by 2 around the
    /// viewport center, then translate by 0.1 of viewport width.
    func deltaTransform(viewportSize: CGSize) -> CGAffineTransform {
        guard scale != 1.0 || panX != 0 || panY != 0 else { return .identity }
        let cx = viewportSize.width / 2
        let cy = viewportSize.height / 2
        let tx = -panX * viewportSize.width
        let ty = -panY * viewportSize.height
        return CGAffineTransform.identity
            .translatedBy(x: cx + tx, y: cy + ty)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -cx, y: -cy)
    }
}
```

Add a unit test:

```swift
// Append to ZoomTests.swift
func test_deltaTransform_at_identity_is_identity() {
    let t = Zoom.identity.deltaTransform(viewportSize: CGSize(width: 1920, height: 1080))
    XCTAssertEqual(t, .identity)
}

func test_deltaTransform_at_scale_2_centers_zoomed_viewport() {
    let vp = CGSize(width: 1000, height: 500)
    let t = Zoom(scale: 2, panX: 0, panY: 0).deltaTransform(viewportSize: vp)
    // Center of viewport (500, 250) should map to itself.
    let center = CGPoint(x: 500, y: 250).applying(t)
    XCTAssertEqual(center.x, 500, accuracy: 1e-9)
    XCTAssertEqual(center.y, 250, accuracy: 1e-9)
    // Top-left of viewport (0,0) should map to (-500, -250) — pulled outside.
    let origin = CGPoint.zero.applying(t)
    XCTAssertEqual(origin.x, -500, accuracy: 1e-9)
    XCTAssertEqual(origin.y, -250, accuracy: 1e-9)
}
```

**Step 2: Apply the delta in `PreviewCompositor.startRequest(_:)`.**

Locate the line where the source CIImage gets its layout transform applied (search for `.transformed(by:` near the source-frame handling). Apply zoom AFTER that transform:

```swift
let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
let zoom = clip.zoomAt(recordTime: recordTime)
let zoomDelta = zoom.deltaTransform(viewportSize: outputSize)

// Apply existing layout transform first (stretch-to-fill — unchanged), then
// the zoom delta on top:
let baseImage = sourceCIImage.transformed(by: existingLayoutTransform)
let zoomed = zoom.scale == 1.0
    ? baseImage
    : baseImage.transformed(by: zoomDelta).cropped(to: CGRect(origin: .zero, size: outputSize))
```

> **Why `cropped`:** scaling a CIImage by 2× expands its `extent` past the viewport. Without crop, the compositor would composite the larger image into the destination, scaling everything down and defeating the zoom. The `cropped(to:)` constrains the output to viewport bounds — the visible portion is exactly the zoomed region.

**Step 3: Run existing PreviewCompositor tests (smoke).**

```bash
cd apple && swift test --package-path VideoCoachCore --filter PreviewCompositor
```
Expected: all existing tests still pass (identity-zoom is bit-identical to current behavior).

**Step 4: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Zoom.swift \
        apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/ZoomTests.swift
git commit -m "feat(zoom): PreviewCompositor applies CIImage zoom delta-transform"
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
    func test_identity_zoom_produces_same_output_as_no_zoom() async throws {
        // Regression test: at scale=1, panX=0, panY=0, the compositor output
        // must be byte-identical to a clip with no zoom events at all.
        // Reviewer finding 6 — guards against the silent stretch-vs-letterbox
        // regression.
        // ... generate two outputs (one with .identity zoom event, one with
        //     no events), assert center+corner pixels match.
    }

    func test_zoom_2x_centered_shows_only_center_quadrant_of_source() async throws {
        // Build a synthetic source that's red top-left quadrant + blue
        // everywhere else. At zoom=2 panX=0 panY=0, the visible viewport
        // is the center quadrant of the source — sampling the output's
        // top-left corner should now show pixels FROM the source's
        // (25%, 25%) point, not (0, 0). We sample three known points and
        // assert they reflect the zoomed region.
    }
}
```

**Step 2: Run, expect compile error / XCTFail.**

**Step 3: Wire zoom into `CompilationCompositor.startRequest(_:)`** using the SAME delta-transform pattern as Task 5.1.

`CompilationCompositor`'s rendering path uses a `CGContext` (the `makeCGImage(_:)` helper in the existing source converts CVPixelBuffer→CIImage→CGImage; the resulting CGImage is drawn into the destination via `cg.draw(img, in: fullRect)`).

The current draw call (`cg.draw(img, in: CGRect(x:0, y:0, width:w, height:h))`) is a stretch-to-fill that ignores aspect ratio. Apply the zoom delta as a `concatenate` BEFORE the draw so identity zoom is bit-identical to today's behavior:

```swift
let recordTime = ...   // existing computation
let zoom = clip.zoomAt(recordTime: recordTime)
let zoomDelta = zoom.deltaTransform(viewportSize: CGSize(width: w, height: h))

cg.saveGState()
if zoom.scale != 1.0 || zoom.panX != 0 || zoom.panY != 0 {
    cg.concatenate(zoomDelta)
}
cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
cg.restoreGState()
```

> **Why this preserves the existing stretch-to-fill at identity:** at zoom=1 the deltaTransform is `.identity` and we skip the `concatenate` entirely. The `cg.draw(img, in: fullRect)` call is unchanged from current behavior — the compositor's output is identical for all clips with no zoom events. Reviewer finding 6 fixed.

**Step 4: Implement the test bodies.** Build a synthetic source via `SyntheticAsset.swift`'s helpers, configure a `Clip` with one `.zoom(Zoom(scale: 2, ...))` event, run the compositor, assert pixels via `PixelSampling.swift`.

**Step 5: Run, expect pass.**

**Step 6: Commit.**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift \
        apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationCompositorZoomTests.swift
git commit -m "feat(zoom): CompilationCompositor applies per-frame zoom delta-transform"
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
