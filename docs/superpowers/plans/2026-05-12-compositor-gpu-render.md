# Compositor GPU-direct render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-frame CGImage round-trip in `CompilationCompositor.startRequest(_:)` with a single `CIContext.render(_:to:bounds:colorSpace:)` call so the base frame + PiP composition stays GPU-resident.

**Architecture:** Two sequential stages on the same output `CVPixelBuffer`. Stage 1: build a composed `CIImage` (black background, source frame with zoom transform, optional PiP webcam) and render it directly into the output buffer via `CIContext.render`. Stage 2: open a CGContext over the same buffer and draw strokes + text bar exactly as today. The `makeCGImage(_:)` helper is removed.

**Tech Stack:** Core Image, AVFoundation, CoreVideo, CoreText (unchanged for overlays). All work happens in one Swift file: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`.

**Build commands:**
- Core unit tests: `cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test`
- App build & launch (after Swift edits): `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`

---

## File Structure

**Modify:**
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift` — `startRequest(_:)` is rewritten as a two-stage pipeline; `makeCGImage(_:)` is deleted; the CIContext init's doc comment is updated to reflect the new role (direct CVPixelBuffer render, not CGImage conversion).

**No new files.** No test files are added — the existing E2E tests in `apple/VideoCoachCore/Tests/VideoCoachCoreTests/` (`CompilationExporterTests.swift`, `CompilationExporterE2ETests.swift`, `LayerInstructionZoomTests.swift`) already exercise the export pipeline against fiducial assets; their assertions are the verification gate.

---

## Task 1: Replace `startRequest(_:)` with the two-stage GPU pipeline

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`

- [ ] **Step 1: Update the CIContext doc comment**

Find the existing doc comment (lines 33–46):

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
    /// Shared CIContext used to render the composed base + PiP CIImage
    /// directly into the output CVPixelBuffer (stage 1 of startRequest).
    /// CIContext.render(_:to:bounds:colorSpace:) writes into the buffer's
    /// IOSurface without an intermediate CGImage, keeping the frame
    /// GPU-resident from source decode through encoder hand-off. Working
    /// and output color spaces are pinned to deviceRGB so the subsequent
    /// CGContext overlay pass (stage 2) draws on bytes laid down in the
    /// same color space.
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

- [ ] **Step 2: Rewrite `startRequest(_:)` body**

Replace the entire `startRequest(_:)` method (lines 56–193 in current file). Find the existing method (the one that begins `public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {` and includes the CG draw block) and replace its body with this two-stage implementation:

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

        guard let out = renderContext?.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        let viewport = CGRect(x: 0, y: 0, width: w, height: h)
        let deviceRGB = CGColorSpaceCreateDeviceRGB()

        // ── Stage 1: GPU-direct render of base + PiP ───────────────────
        //
        // Build the composed CIImage: black background, optionally the
        // source frame with zoom transform applied, optionally the PiP
        // webcam placed at bottom-right. Then render the whole thing in
        // one CIContext.render(_:to:bounds:colorSpace:) call which writes
        // directly into `out`'s IOSurface. No CGImage object, no CPU
        // readback — the encoder picks the buffer up GPU-resident.
        //
        // CIImage's coordinate origin is bottom-left. CIContext.render
        // writes the image into the CVPixelBuffer such that
        // `bounds.origin` maps to the buffer's top-left pixel. So the
        // PiP placement uses `y = margin` (bottom in CIImage space ==
        // bottom of output frame).

        var composed: CIImage = CIImage(color: .black).cropped(to: viewport)

        if let base {
            let baseImage = CIImage(cvPixelBuffer: base)
            // Scale the source's natural extent to the viewport, then
            // apply the zoom delta on top. This matches today's
            // cg.draw(img, in: CGRect(0, 0, w, h)) followed by
            // cg.concatenate(zoom.deltaTransform(...)). Composition
            // order is: viewport-fit first, then zoom delta.
            let srcExtent = baseImage.extent
            let fit = CGAffineTransform(
                scaleX: CGFloat(w) / max(srcExtent.width, 1),
                y: CGFloat(h) / max(srcExtent.height, 1)
            )
            var positioned = baseImage.transformed(by: fit)

            let zoom = inst?.events.zoomAt(recordTime: recordTime) ?? .identity
            if zoom != .identity {
                positioned = positioned.transformed(
                    by: zoom.deltaTransform(viewportSize: CGSize(width: w, height: h))
                )
            }
            // Crop to viewport so transformed-extent excess doesn't leak
            // into PiP region or cause the render to allocate a larger
            // intermediate.
            composed = positioned.cropped(to: viewport).composited(over: composed)
        }

        if let webcam {
            let webcamImage = CIImage(cvPixelBuffer: webcam)
            let webcamW = max(webcamImage.extent.width, 1)
            let webcamH = max(webcamImage.extent.height, 1)
            let pipW = CGFloat(w) * 0.22
            let pipH = pipW * webcamH / webcamW
            let margin = CGFloat(h) * 0.022
            // Bottom-right in CIImage space (origin bottom-left):
            //   x = w - pipW - margin
            //   y = margin    (bottom margin)
            let scale = CGAffineTransform(scaleX: pipW / webcamW, y: pipH / webcamH)
            let translate = CGAffineTransform(
                translationX: CGFloat(w) - pipW - margin,
                y: margin
            )
            let placed = webcamImage
                .transformed(by: scale)
                .transformed(by: translate)
                .cropped(to: viewport)
            composed = placed.composited(over: composed)
        }

        ciContext.render(
            composed,
            to: out,
            bounds: viewport,
            colorSpace: deviceRGB
        )

        // ── Stage 2: CGContext overlays (strokes + text bar) ───────────
        //
        // The output buffer now contains the composed base + PiP. Open
        // a CGContext over its IOSurface-backed memory to draw the
        // smaller overlays. The Y-flip is preserved so stroke
        // coordinates (top-left, normalized) and the text-bar Y math
        // continue to work unchanged.

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(out),
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
            space: deviceRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            request.finishCancelledRequest()
            return
        }

        // After this transform, user-space (0, 0) is top-left — matches
        // how strokes are recorded and how drawTextBar's bar-rect math
        // is written.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)

        let size = CGSize(width: w, height: h)

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

- The local helpers `drawStroke(_:into:size:)`, `drawTextBar(_:into:size:)`, and `visibleStrokes(in:atRecordTime:)` are **unchanged** and remain elsewhere in the file. Do not remove or modify them.
- `Zoom.deltaTransform(viewportSize:)`, `Clip.init`, and `inst.events`/`textBarLine`/`clipCompositionStart`/`sourceTrackID`/`webcamTrackID` are existing API; the new body uses them identically to the old one.
- The PiP Y origin moves from `CGFloat(h) - pipH - margin` (CG-space, post-flip) to `margin` (CIImage space, bottom-left). This is intentional — bottom-right placement is preserved; see the spec's "PiP coordinate Y" subtlety section.

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

Delete the entire method including its doc/comment block above it.

- [ ] **Step 4: Build the package**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift build
```
Expected: build succeeds. Any compile error here is a sign that a helper signature was misremembered — re-read the surrounding code.

- [ ] **Step 5: Run the package unit tests**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test
```
Expected: ALL PASS. The relevant suites (`CompilationExporterTests`, `CompilationExporterE2ETests`, `LayerInstructionZoomTests`) exercise full exports against fiducial assets and verify pixel-level assertions or duration assertions or composition shapes. If any of these fail:

- A test asserting pixel colors at known positions → check stage 1's transform math (the scale-to-viewport `fit` transform, plus the zoom delta, plus any cropping). Most likely cause is the `fit` transform — if the source asset's natural extent doesn't equal the output size, the old `cg.draw(img, in: CGRect(0, 0, w, h))` did the scale implicitly and the new path needs `fit` to do it explicitly.
- A test asserting the PiP position → verify the Y math. In CIImage space, `y = margin` places the bottom of the PiP `margin` pixels above the bottom of the output frame. If the test expects the PiP at the top-right (which would be wrong but worth ruling out), inspect the test expectation.
- A test asserting upside-down output → check the stage-1 orientation. `CIImage(cvPixelBuffer:)` + `CIContext.render(...)` is *expected* to round-trip a buffer identically (both ends use the same convention). If pixels come out upside-down anyway, apply a vertical flip to the final composed image before rendering:

  ```swift
  let flipped = composed
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(h)))
  ciContext.render(flipped, to: out, bounds: viewport, colorSpace: deviceRGB)
  ```

  If you apply this flip, the PiP Y math must also flip: `translationY: margin` becomes `translationY: CGFloat(h) - pipH - margin`. (The two flips compose to leave the PiP at visual bottom-right either way.)

Do not skip past failing tests. Each is a real signal.

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

If anything looks wrong, capture a comparison frame from a known-good export (from before the change — Git allows `git show HEAD~1:apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift` to compare). Don't ship a regression.

- [ ] **Step 7: Commit**

```
cd /Users/taylor/dev/coach-cutups-2
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift
git commit -m "perf(compositor): render base + PiP via CIContext.render (GPU-direct)

Replaces the CGImage + CGContextDrawImage round-trip with a single
CIContext.render(_:to:bounds:colorSpace:) call that writes the
composed base frame + PiP webcam directly into the output
CVPixelBuffer's IOSurface. Strokes + text bar continue to render
via CGContext (small per-frame cost; unchanged).

Instruments showed 81% of export wall time in CGContextDrawImage +
createCGImage. Both vanish under the new path; the HEVC encoder is
no longer starved waiting on CPU rasterization. Expected 3-4x
speedup on 1080p exports.

The makeCGImage(_:) helper has no remaining callers and is removed."
```

---

## Task 2: Verify in Release configuration

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

Report the new export wall time so we can confirm the perf delta in the commit log as a follow-up note if desired.
