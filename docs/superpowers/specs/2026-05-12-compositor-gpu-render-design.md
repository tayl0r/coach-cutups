# Compositor: GPU-direct base + PiP render

## Goal

Replace the `CGImage` + `CGContext.draw` round-trip in
`CompilationCompositor.startRequest(_:)` with a single
`CIContext.render(_:to:bounds:colorSpace:)` call that writes the
composed base frame + PiP webcam directly into the output
`CVPixelBuffer`. Keep stroke and text-bar rendering on the existing
`CGContext` path — they're small and don't dominate the profile.

Expected wall-time improvement on a 1080p export: **3–4×.** Source:
the Time Profiler showed 81% of total export wall time in two
calls — `CGContextDrawImage` (55%) and `createCGImage` (26%) — that
both vanish under the new path.

## Background

`CompilationCompositor.startRequest(_:)` is called once per output
frame by AVFoundation. The current implementation, per profile,
spends ~78 wall-seconds (out of an 87-second export) on:

1. `ciContext.createCGImage(...)` — forces a GPU → CPU readback of
   the source `CVPixelBuffer` for every frame.
2. `cg.draw(cgImage, in: ...)` — CPU rasterization back into the
   output buffer (which is then handed to VideoToolbox for GPU
   encode, i.e., a CPU → GPU upload again).

Two round-trips per frame. The HEVC encoder on the Media Engine is
idle waiting for these CPU steps. The encoder itself does not
appear in the top of the profile.

## Approach

`CIContext.render(_:to:bounds:colorSpace:)` writes a `CIImage`
directly into a `CVPixelBuffer`'s IOSurface-backed memory.
GPU-resident the whole way. We use it for the **base frame + PiP
webcam** composition. Strokes and the text bar continue to render
via `CGContext` because:

- Both are small in pixel-count (a few hundred to a few thousand
  pixels of work per frame) and contribute negligibly to the
  profile.
- The existing CG-based code is well-tested and pixel-stable; we
  don't want to take risk on the parts that aren't the
  bottleneck.

The two render stages run sequentially against the same output
buffer:

```
                  ┌────────────────────────────────────┐
   stage 1   ───► │ ciContext.render(baseAndPip, to: out) │  GPU → IOSurface
                  └────────────────────────────────────┘
                                  ▼
                  ┌────────────────────────────────────┐
   stage 2   ───► │ CGContext over `out`'s base addr   │  CPU writes overlays
                  │   draw strokes; draw text bar      │
                  └────────────────────────────────────┘
                                  ▼
                  request.finish(withComposedVideoFrame: out)
```

No concurrent access — stage 1 fully completes before stage 2
opens the CGContext, so there's no IOSurface / mapped-memory
collision.

## Detailed change

The single method modified is
`CompilationCompositor.startRequest(_:)`.

### Stage 1 — build the composed CIImage

```swift
let w = renderContext?.size.width  ?? 0      // already used today
let h = renderContext?.size.height ?? 0

// Black background — covers the case where `base` is nil
// (clip starts paused with no cached frame). CIColor.black backed
// by a CIImage constant-color, cropped to the output viewport.
let viewport = CGRect(x: 0, y: 0, width: w, height: h)
var composed = CIImage(color: .black).cropped(to: viewport)

if let base {
    let baseImage = CIImage(cvPixelBuffer: base)
    // Apply zoom delta. zoom.deltaTransform is the same matrix
    // applied today via cg.concatenate; CIImage uses the same
    // CGAffineTransform type.
    let zoom = inst?.events.zoomAt(recordTime: recordTime) ?? .identity
    let zoomed = zoom == .identity
        ? baseImage
        : baseImage.transformed(by: zoom.deltaTransform(viewportSize: CGSize(width: w, height: h)))
    composed = zoomed.composited(over: composed)
}

let webcamTrackID = …   // existing resolution unchanged
if let webcam = request.sourceFrame(byTrackID: webcamTrackID) {
    let webcamImage = CIImage(cvPixelBuffer: webcam)
    let webcamW = webcamImage.extent.width
    let webcamH = webcamImage.extent.height
    let pipW = CGFloat(w) * 0.22
    let pipH = pipW * webcamH / max(webcamW, 1)
    let margin = CGFloat(h) * 0.022
    let pipRect = CGRect(
        x: CGFloat(w) - pipW - margin,
        y: CGFloat(h) - pipH - margin,
        width: pipW,
        height: pipH
    )
    // Scale to the PiP target rect, then translate into position.
    let scaled = webcamImage.transformed(
        by: CGAffineTransform(scaleX: pipW / webcamW, y: pipH / webcamH)
    )
    let placed = scaled.transformed(
        by: CGAffineTransform(translationX: pipRect.minX, y: pipRect.minY)
    )
    composed = placed.composited(over: composed)
}

// Now write the composed image directly to the output buffer.
// CIImage's natural origin is bottom-left and the output buffer
// matches that convention from CIContext's perspective — Core
// Image handles the orientation internally when rendering to a
// pixel buffer. NO Y-flip required at this stage.
let outputColorSpace = CGColorSpaceCreateDeviceRGB()
ciContext.render(
    composed,
    to: out,
    bounds: viewport,
    colorSpace: outputColorSpace
)
```

### Stage 2 — overlays via CGContext (mostly unchanged)

After stage 1, open the CGContext over the now-populated output
buffer. The existing Y-flip remains, since strokes are recorded in
top-left normalized coordinates and the existing
`Denormalize.point(…, flipY: false)` math expects the flipped
CGContext.

```swift
CVPixelBufferLockBaseAddress(out, [])
defer { CVPixelBufferUnlockBaseAddress(out, []) }

guard let cg = CGContext(
    data: CVPixelBufferGetBaseAddress(out),
    width: w,
    height: h,
    bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(out),
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
) else {
    request.finishCancelledRequest()
    return
}

// IMPORTANT: do NOT cg.fill black or cg.draw the base image here —
// stage 1 already wrote the composed base + PiP. The CGContext is
// only used for overlays on top.

cg.translateBy(x: 0, y: CGFloat(h))
cg.scaleBy(x: 1, y: -1)
let size = CGSize(width: w, height: h)

if let inst {
    let synthClip = Clip(…)  // unchanged
    for vs in visibleStrokes(in: synthClip, atRecordTime: recordTime) {
        drawStroke(vs, into: cg, size: size)
    }
    drawTextBar(inst.textBarLine, into: cg, size: size)
}
```

### Deletions

- The current `cg.setFillColor(.black) + cg.fill(...)` lines — black
  fill is now handled by the CIImage `CIColor.black` background in
  stage 1.
- The current `cg.draw(cgImage, ...)` for the base frame.
- The current `cg.draw(wImg, ...)` for the PiP webcam.
- The `makeCGImage(_:)` private helper — has no remaining callers
  after this change.
- The `cg.saveGState()` / `cg.restoreGState()` pair around the zoom
  transform — no longer needed since the zoom is applied to the
  CIImage, not the CGContext.

The 4 lines of `defer { CVPixelBufferUnlockBaseAddress(out, []) }`
machinery move from the top of the method to the start of stage 2
(immediately before opening the CGContext) — stage 1 doesn't need
the buffer locked because CIContext.render manages access via
IOSurface internally.

## Subtleties

- **Color space.** Stage 1 renders with `CGColorSpaceCreateDeviceRGB`
  matching the `ciContext`'s `outputColorSpace` initialization
  (already `deviceRGB`). Stage 2's CGContext also uses
  `deviceRGB`. Same color space throughout the pipeline = no
  shift.
- **Pixel format.** `renderContext?.newPixelBuffer()` returns BGRA
  (the AVFoundation default for video composition). CIContext
  renders BGRA natively; CGContext with `byteOrder32Little +
  premultipliedFirst` also matches BGRA. Both stages write
  identical bytes per pixel.
- **CIImage Y-orientation when rendering to a `CVPixelBuffer`.**
  Apple's docs and the [WWDC 2017 "Working with HEIF and HEVC"
  guidance](https://developer.apple.com/videos/play/wwdc2017/511/)
  confirm that `CIContext.render(_:to:bounds:colorSpace:)` to a
  CVPixelBuffer writes top-left-origin pixels — i.e., Core Image
  handles the upside-down convention internally. We don't add a
  Y-flip in stage 1. Stage 2's CGContext flip is unchanged because
  stroke coordinates are recorded top-left.
- **PiP coordinate Y.** The `pipRect` math uses
  `CGFloat(h) - pipH - margin` for the Y origin. Today's CG path
  draws this after a Y-flip is active, so this lands the PiP at
  the bottom of the visual frame. In stage 1, with no Y-flip
  applied to the CIImage, `pipRect.minY = h - pipH - margin` lands
  the PiP at the TOP of the rendered image (CIImage origin is
  bottom-left). To preserve the bottom-right placement we use
  `pipRect.minY = margin` (bottom of CIImage space = bottom of
  output). Validate against an existing exported clip with a
  visible PiP.
- **`out` may have been pre-zeroed differently across runs.**
  `newPixelBuffer()` doesn't guarantee zeroed memory, but stage 1
  fully covers the viewport (black background, optionally with
  base + PiP atop), so we don't depend on pool-slot leftover bits.

## Risk

The change is mechanically small but pixel-critical. Two
verification gates:

1. **Existing E2E tests pass.** `CompilationExporterTests` and
   `CompilationExporterE2ETests` already exercise full exports.
   They use synthetic test assets and verify byte-level or
   pixel-sample assertions. If any assertion shifts by more than
   ±1 LSB, abort and investigate.
2. **One new pixel-sample test** (optional, recommended). Use the
   existing `FiducialAsset` helper to export a known clip and
   sample ~4 pixels at characteristic positions (center, two
   corners, PiP region). Tolerance ±2 LSB. Locks behaviour against
   future compositor changes.
3. **Manual smoke**: export a clip with visible strokes + text bar
   + PiP. Eyeball against a known-good export from before the
   change. Particular attention to: stroke alignment (Y-flip), PiP
   position (bottom-right corner), zoom-applied base frame.

## Non-goals

- Migrating strokes / text bar to Core Image (could be a future
  win but the profile shows it's not currently a bottleneck).
- Switching from `AVAssetExportSession` to a hand-built
  `AVAssetWriter` + reader pipeline (bigger surgery, separate
  spec).
- Adopting Metal directly. CIContext is Metal-backed under the
  hood on Apple Silicon; we get the same GPU path without
  managing Metal command queues.
- Touching the export progress UI spec — separate scope.

## File changes summary

- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`
  — modify `startRequest(_:)` per the stage-1 / stage-2 layout
  above; delete `makeCGImage(_:)` (now unused).
- (Optional) `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift`
  — add a pixel-sample assertion using `FiducialAsset` if the
  current tests don't cover pixel correctness strictly enough.
