# Compositor GPU-direct render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-frame CGImage round-trip in `CompilationCompositor.startRequest(_:)` with a single `CIContext.render(_:to:bounds:colorSpace:)` call so the base frame + PiP composition stays GPU-resident. Strokes + text bar continue on the existing CGContext path.

**Architecture:** Mirror the exact pattern already used by `PreviewCompositor.swift` in the same package (which is shipping and proven). Two sequential stages on the same output `CVPixelBuffer`. **Stage 1:** build a composed `CIImage` (black background + base with zoom + optional PiP) and render it into the output buffer via `CIContext.render(_:to:bounds:colorSpace:)`. **Stage 2:** open a CGContext over the same buffer and draw strokes + text bar exactly as today. Delete the now-unused `makeCGImage(_:)` helper.

**Tech Stack:** Core Image (stage 1, GPU), CoreGraphics + CoreText (stage 2 overlays, unchanged). All work in one Swift file: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`. Reference: `apple/VideoCoachCore/Sources/VideoCoachCore/PreviewCompositor.swift:65–189`.

**Build commands:**
- Core unit tests: `cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test`
- App build & launch (after Swift edits): `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`

---

## Reference implementation

The single most important context for this plan: **`PreviewCompositor.startRequest(_:)` already does the stage-1 work.** Read that file first. It implements:

- `CIImage(color: .black).cropped(to: outRect)` background
- Non-uniform `baseScale` to stretch base CIImage to viewport (matches today's CG `cg.draw(img, in: outRect)` stretch policy)
- Zoom delta applied as `.transformed(by: zoom.deltaTransform(viewportSize:))`
- Identity-zoom early-out skipping the `.cropped(to:)` op for bit-identical behavior at the common case
- PiP placement at `(outW - margin - pipW, margin)` in CIImage bottom-left coordinates
- Single `ciContext.render(composite, to: out, bounds: outRect, colorSpace: Self.outputColorSpace)` write
- `private static let outputColorSpace = CGColorSpaceCreateDeviceRGB()` hoisted to type scope

We are NOT inventing new patterns. We are mirroring PreviewCompositor and adding strokes + text bar (which PreviewCompositor doesn't need because preview draws those as AppKit overlays).

---

## File Structure

**Modify:**
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift` — `startRequest(_:)` is rewritten as a two-stage pipeline mirroring `PreviewCompositor`; `makeCGImage(_:)` is deleted; the CIContext doc comment is updated; `outputColorSpace` hoisted to `private static let`.

**Modify (test addition):**
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift` — add one new test that samples pixels at the PiP location and the base-frame center to lock in correct orientation and placement.

---

## Task 1: Replace `startRequest(_:)` with the two-stage GPU pipeline

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`

- [ ] **Step 1: Update the CIContext doc comment and hoist `outputColorSpace`**

Find the existing doc comment + property (lines 33–46):

```swift
    /// Shared CIContext for `CVPixelBuffer → CGImage` conversions in
    /// ``makeCGImage(_:)``. Allocated once per compositor instance (one
    /// allocation per export, not per frame). Working color space is pinned
    /// to deviceRGB so the CG draw matches our output buffer's colorspace
    /// (avoids subtle color shifts in the export).
    ///
    /// Eager init (NOT `lazy var`) — `lazy var` is not thread-safe, and
    /// AVFoundation may call `startRequest(_:)` from a private dispatch queue
    /// without a documented serialization guarantee. Eager init dodges the
    /// race entirely.
    private let ciContext: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
    ])
```

Replace with:

```swift
    /// Hoisted to type scope so `CIContext.render(_:to:bounds:colorSpace:)`
    /// doesn't allocate a fresh `CGColorSpace` per frame on the hot path.
    /// Mirrors `PreviewCompositor.outputColorSpace`.
    private static let outputColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Shared CIContext used to render the composed base + PiP CIImage
    /// directly into the output CVPixelBuffer (stage 1 of startRequest).
    /// `CIContext.render(_:to:bounds:colorSpace:)` writes into the buffer's
    /// IOSurface without an intermediate CGImage, keeping the frame
    /// GPU-resident from source decode through encoder hand-off. Working
    /// and output color spaces are pinned to deviceRGB so the subsequent
    /// CGContext overlay pass (stage 2) draws on bytes laid down in the
    /// same color space.
    ///
    /// `render(_:to:bounds:colorSpace:)` is synchronous — it flushes the
    /// GPU pipeline before returning, so stage 2's `CVPixelBufferLockBaseAddress`
    /// safely reads the bytes stage 1 wrote with no ordering hazard.
    ///
    /// Eager init (NOT `lazy var`) — `lazy var` is not thread-safe, and
    /// AVFoundation may call `startRequest(_:)` from a private dispatch
    /// queue without a documented serialization guarantee. Eager init dodges
    /// the race entirely.
    private let ciContext: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
    ])
```

- [ ] **Step 2: Rewrite `startRequest(_:)` body**

Replace the entire `startRequest(_:)` method (lines 56–193 in current file). Find the existing method beginning `public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {` and replace its body with this two-stage implementation:

```swift
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // macOS 26 strips the AVMutableVideoCompositionInstruction subclass
        // on at least the playback path (PreviewCompositor saw this) and
        // appears to do the same on the export path under some conditions
        // ("AVAssetExportSession failed: Operation Stopped" was traced to
        // this fatalError firing inside the export pipeline). Recover
        // gracefully: when the cast misses, fall back to a "no per-clip
        // context" path that still emits a frame so the export completes.
        let inst = request.videoCompositionInstruction as? CompilationInstruction
        let recordTime = inst.map { (request.compositionTime - $0.clipCompositionStart).seconds } ?? 0

        // Resolve source + webcam track IDs (same logic as before — the
        // instruction subclass exposes them directly, with a fallback to
        // `requiredSourceTrackIDs` declaration order when stripped).
        let sourceTrackID: CMPersistentTrackID
        if let inst {
            sourceTrackID = inst.sourceTrackID
        } else if let firstRequiredID = request.videoCompositionInstruction
                    .requiredSourceTrackIDs?.first as? CMPersistentTrackID {
            sourceTrackID = firstRequiredID
        } else {
            sourceTrackID = kCMPersistentTrackID_Invalid
        }
        let webcamTrackID: CMPersistentTrackID
        if let inst {
            webcamTrackID = inst.webcamTrackID
        } else if let required = request.videoCompositionInstruction.requiredSourceTrackIDs,
                  required.count >= 2,
                  let second = required[1] as? CMPersistentTrackID {
            webcamTrackID = second
        } else {
            webcamTrackID = kCMPersistentTrackID_Invalid
        }

        let base: CVPixelBuffer? = request.sourceFrame(byTrackID: sourceTrackID)
        let webcam: CVPixelBuffer? = request.sourceFrame(byTrackID: webcamTrackID)

        guard let renderContext, let out = renderContext.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        let outW = CGFloat(CVPixelBufferGetWidth(out))
        let outH = CGFloat(CVPixelBufferGetHeight(out))
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        // ── Stage 1: GPU-direct render of base + PiP ───────────────────
        //
        // This block is a structural mirror of PreviewCompositor.startRequest
        // lines 117–177. If you change anything here that's not strictly a
        // stroke/text overlay concern, mirror it in PreviewCompositor too —
        // they're paired by visual contract (preview must match export).

        var composite: CIImage = CIImage(color: .black).cropped(to: outRect)

        if let base {
            let baseCI = CIImage(cvPixelBuffer: base)
            // baseCI.extent.origin is (0,0) for any CIImage made from an
            // AVFoundation-allocated CVPixelBuffer (which is what
            // `request.sourceFrame(byTrackID:)` always returns). The fit
            // math below assumes origin (0,0); we don't translate by
            // -origin because the assumption holds for all real inputs.
            let baseScale = CGAffineTransform(
                scaleX: outW / max(baseCI.extent.width, 1),
                y: outH / max(baseCI.extent.height, 1)
            )
            let stretched = baseCI.transformed(by: baseScale)
            let zoom = inst?.events.zoomAt(recordTime: recordTime) ?? .identity
            // Identity-zoom early-out — skip `.cropped(to: outRect)` op so
            // behavior is bit-identical to the prior pipeline at zoom=1.
            // `deltaTransform` early-outs at identity already, but `.cropped`
            // is a non-trivial CIImage op we don't want on the hot path.
            // At any non-identity zoom the cropped path is required to keep
            // the zoomed image bounded by outRect.
            let zoomed = (zoom == .identity)
                ? stretched
                : stretched.transformed(by: zoom.deltaTransform(viewportSize: outRect.size))
                           .cropped(to: outRect)
            composite = zoomed.composited(over: composite)
        }

        if let webcam {
            let camCI = CIImage(cvPixelBuffer: webcam)
            let camW = camCI.extent.width
            let camH = camCI.extent.height
            let pipW = outW * 0.22
            let pipH = pipW * camH / max(camW, 1)
            let margin = outH * 0.022
            // CIImage's coordinate origin is bottom-left, so "bottom-right
            // with margin" = (outW - margin - pipW, margin). This matches
            // PreviewCompositor.startRequest lines 159–173 exactly.
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

        ciContext.render(
            composite,
            to: out,
            bounds: outRect,
            colorSpace: Self.outputColorSpace
        )

        // ── Stage 2: CGContext overlays (strokes + text bar) ───────────
        //
        // The output buffer now contains the composed base + PiP. Open a
        // CGContext over its IOSurface-backed memory to draw the smaller
        // overlays (strokes are typically a few thousand pixels of work
        // per frame; text bar is a single-line CoreText draw). The Y-flip
        // is preserved so stroke coordinates (top-left, normalized) and
        // the text-bar Y math continue to work unchanged.
        //
        // `CIContext.render` is synchronous (flushes GPU before returning),
        // so there's no ordering hazard between the IOSurface write above
        // and the lockBaseAddress + CG draws below.

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        let w = Int(outW)
        let h = Int(outH)
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(out),
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
            space: Self.outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            request.finishCancelledRequest()
            return
        }

        // After this transform, user-space (0, 0) is top-left — matches how
        // strokes are recorded and how drawTextBar's bar-rect math is
        // written.
        cg.translateBy(x: 0, y: outH)
        cg.scaleBy(x: 1, y: -1)

        let size = CGSize(width: outW, height: outH)

        if let inst {
            let synthClip = Clip(
                name: "_compositorReplay",
                sourceIndex: 0,
                startSourceSeconds: 0,
                recordingDuration: max(recordTime, 0) + 1,
                recordingFilename: "",
                events: inst.events,
                sortIndex: 0
            )
            for vs in visibleStrokes(in: synthClip, atRecordTime: recordTime) {
                drawStroke(vs, into: cg, size: size)
            }
            drawTextBar(inst.textBarLine, into: cg, size: size)
        }

        request.finish(withComposedVideoFrame: out)
    }
```

Notes for the implementer:

- `drawStroke(_:into:size:)`, `drawTextBar(_:into:size:)`, and `visibleStrokes(in:atRecordTime:)` are **unchanged** and remain elsewhere in the file. Do not modify them.
- `Zoom.deltaTransform(viewportSize:)`, `Clip.init`, and `inst.events`/`textBarLine`/`clipCompositionStart`/`sourceTrackID`/`webcamTrackID` are existing API; the new body uses them identically to the old one.
- The stage-1 block is a 1:1 structural mirror of `PreviewCompositor.startRequest(_:)` lines 117–177. If anything diverges, that's a bug — go back to PreviewCompositor as the reference and reconcile.

- [ ] **Step 3: Delete `makeCGImage(_:)`**

Find the helper at the bottom of the file:

```swift
    private func makeCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        // CIImage's native coordinate convention is bottom-left origin, but
        // a CVPixelBuffer's pixel rows are top-down. `createCGImage` produces
        // a CGImage whose row 0 corresponds to CIImage y=0 (the BOTTOM of
        // the source image). When that CGImage is drawn into our top-left
        // CGContext (flipped above), the image lands upside-down. Apply a
        // vertical flip to the CIImage so its row 0 = TOP of source, then
        // the CGImage we hand to cg.draw is naturally right-side-up.
        let flipped = ci
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: ci.extent.height))
        return ciContext.createCGImage(flipped, from: flipped.extent)
    }
```

Delete the entire method including its doc/comment block.

- [ ] **Step 4: Build the package**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift build
```
Expected: build succeeds. Any compile error here is a sign that a helper signature was misremembered — re-read the surrounding code or PreviewCompositor.

- [ ] **Step 5: Run the package unit tests**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test
```
Expected: ALL PASS — including the existing `CompilationExporterTests`, `CompilationExporterE2ETests`, and `LayerInstructionZoomTests`. The existing E2E tests verify zoom keyframe application and freeze-frame correctness; if those pass, the base-frame transform + zoom pipeline is correct.

Note: existing tests do NOT cover PiP placement or non-zoomed base orientation directly. Task 2 adds a pixel-sample test that covers those gaps.

- [ ] **Step 6: Build and launch the app, do a manual smoke export**

Run:
```
/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh
```

Open a project with at least one tagged clip that has visible strokes drawn on it. Export. Verify in the exported file:
- Base frame visible and right-side-up.
- Strokes appear at the right positions (same as before the change).
- Text bar at the bottom is readable, right-side-up.
- If the clip has a webcam recording, the PiP is in the bottom-right corner.
- If the clip has zoom events, the base frame is zoomed appropriately.

Compare against a known-good export. If anything looks wrong, do NOT commit — investigate.

- [ ] **Step 7: Commit Task 1**

```
cd /Users/taylor/dev/coach-cutups-2
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift
git commit -m "perf(compositor): render base + PiP via CIContext.render (GPU-direct)

Mirrors the proven pattern already in PreviewCompositor.swift —
build a composed CIImage (black background, base with zoom, optional
PiP) and write it directly into the output CVPixelBuffer's IOSurface
via CIContext.render(_:to:bounds:colorSpace:). Strokes + text bar
continue to render via CGContext over the same buffer (small per-frame
cost; unchanged behavior). The makeCGImage(_:) helper has no remaining
callers and is removed.

Instruments showed 81% of export wall time in CGContextDrawImage +
createCGImage. Both vanish under the new path; the HEVC encoder is
no longer starved waiting on CPU rasterization. Expected 3-4x
speedup on 1080p exports."
```

---

## Task 2: Add pixel-correctness coverage for PiP placement and base orientation

The existing E2E tests cover zoom + freeze frames but not PiP location or base-frame orientation. Add one test that samples pixels at characteristic positions so the next refactor (or a future regression) can't ship upside-down output or a misplaced PiP without failing CI.

**Files:**
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift`

- [ ] **Step 1: Read the file to understand the existing test idiom**

```
cat /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift
```

Note: tests use `FiducialAsset` (a known-colored test source) and decode exported frames via existing helpers. The test should reuse those helpers; do not introduce new image-reading infrastructure.

- [ ] **Step 2: Add the new test method**

At the end of the test class (before the closing brace), add:

```swift
    /// Lock in correct base-frame orientation and PiP bottom-right
    /// placement against silent regressions. Samples 4 characteristic
    /// pixels on the first frame of a known clip:
    ///   - center: base frame color (FiducialAsset center sample)
    ///   - top-left of the base region: should NOT match the PiP color
    ///     (proves base isn't shifted/cropped wrongly)
    ///   - bottom-right area (the PiP region): should match webcam color
    ///   - top-right area (outside the PiP region): should match base
    func test_first_frame_pip_lands_bottom_right_and_base_is_upright() async throws {
        let asset = try FiducialAsset.makeBaseAndWebcam()
        // FiducialAsset.makeBaseAndWebcam returns a clip whose source is
        // checkered (so corners differ) and whose webcam is a single
        // distinguishable solid color. See Helpers/FiducialAsset.swift.

        let outURL = try await asset.export()  // existing helper used by other E2E tests
        let frame = try FiducialAsset.readFirstFrame(of: outURL)

        let w = frame.width
        let h = frame.height

        // Base center should equal the asset's known base-center color.
        let baseCenter = frame.sampleAvgRGB(x: w/2, y: h/2, radius: 4)
        XCTAssertEqual(baseCenter.r, asset.baseCenterColor.r, accuracy: 0.03,
                       "base frame center should match source center (orientation check)")
        XCTAssertEqual(baseCenter.g, asset.baseCenterColor.g, accuracy: 0.03)
        XCTAssertEqual(baseCenter.b, asset.baseCenterColor.b, accuracy: 0.03)

        // PiP at bottom-right: sample ~5% from the right edge, ~5% from
        // the bottom edge — well inside the 22%-wide, 2.2%-margin PiP
        // region.
        let pipX = w - max(1, w / 20)
        let pipY = h - max(1, h / 20)
        let pipSample = frame.sampleAvgRGB(x: pipX, y: pipY, radius: 4)
        XCTAssertEqual(pipSample.r, asset.webcamColor.r, accuracy: 0.05,
                       "bottom-right pixel should match webcam color (PiP placement check)")
        XCTAssertEqual(pipSample.g, asset.webcamColor.g, accuracy: 0.05)
        XCTAssertEqual(pipSample.b, asset.webcamColor.b, accuracy: 0.05)

        // Top-right (outside PiP region): should match the base, not webcam.
        // PiP occupies the bottom 22% × pipAspect of the right edge; the
        // top-right corner is well outside that. Sample ~5% from the top
        // edge, ~5% from the right edge.
        let topRightX = w - max(1, w / 20)
        let topRightY = max(1, h / 20)
        let topRightSample = frame.sampleAvgRGB(x: topRightX, y: topRightY, radius: 4)
        XCTAssertNotEqual(topRightSample.r, asset.webcamColor.r, accuracy: 0.05,
                          "top-right should NOT show webcam color (would indicate inverted PiP Y)")
    }
```

Note: the exact `FiducialAsset` API may differ from what's shown above; adjust calls to match what's already in `Helpers/FiducialAsset.swift`. The structural contract (export a known clip, sample known pixels, compare to known colors) is what matters. If `FiducialAsset.makeBaseAndWebcam()` doesn't exist as named, find or build an equivalent setup using `FiducialAsset` + `SplitColorAsset` from the existing helpers.

If the existing `FiducialAsset` doesn't support webcam tracks at all, then drop the webcam-related assertions and just lock in the base-frame orientation (center + top-left/right corner samples). The PiP coverage gap then stays open as a follow-up; the orientation coverage is the more important of the two.

- [ ] **Step 3: Run the new test**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test --filter test_first_frame_pip_lands_bottom_right_and_base_is_upright
```
Expected: PASS.

If FAIL on base orientation → the spec's "no Y-flip" assumption is wrong; apply the vertical-flip alternative from `makeCGImage` (transform the composite CIImage by `CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -outH)` before `ciContext.render`). Then also flip the PiP Y from `margin` to `outH - pipH - margin`. Re-run.

If FAIL on PiP placement specifically (base passes, PiP fails) → check the PiP `translate` Y coordinate vs the assertion location.

- [ ] **Step 4: Commit Task 2**

```
cd /Users/taylor/dev/coach-cutups-2
git add apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift
git commit -m "test(exporter): lock PiP placement + base orientation against regression

Existing E2E coverage exercises zoom keyframes and freeze frames but
not PiP location or non-zoomed base orientation. After the compositor
GPU-render refactor (preceding commit), add a pixel-sample test that
verifies (1) the first frame's center matches the source's center
color and (2) the bottom-right pixel matches the webcam color — both
of which would fail silently if the compositor's CIImage→buffer
orientation or PiP Y math were wrong."
```

---

## Task 3: Verify in Release configuration

The Release build uses Hardened Runtime + full optimization; perf characteristics differ from Debug. Worth a quick verification.

**Files:** none (verification only).

- [ ] **Step 1: Build Release**

```
/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh Release
```
Expected: build succeeds, app launches.

- [ ] **Step 2: Export a known clip**

Pick the same clip you used to measure 87s in the original Instruments profile (or whatever similar long clip you have). Export it. Time it with a stopwatch.

Expected: significant speedup. If 87s → 20-30s, we hit the projection. If the speedup is much smaller (say 87s → 60s), the encoder is now the bottleneck and we're done — that means we successfully unblocked the compositor and the next bottleneck is something different (likely the encoder itself or audio mixing). Either way, the change is a win.

- [ ] **Step 3: No commit (verification only).**

Report the new export wall time so we can confirm the perf delta as a follow-up note if desired.
