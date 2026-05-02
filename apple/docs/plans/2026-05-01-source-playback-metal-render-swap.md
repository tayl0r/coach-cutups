# Source-Playback Render-Path Swap: SW → GL+IOSurface→Metal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the per-frame CPU↔GPU staging copy in `MPVSourcePlayer.renderInto(...)` by switching mpv's render context from `MPV_RENDER_API_TYPE_SW` to `MPV_RENDER_API_TYPE_OPENGL`, with mpv writing into a GL FBO backed by an `IOSurface` that is shared with a Metal texture on the existing `CAMetalLayer`. Result: at 4K HEVC the per-frame ~33 MB pixel-buffer allocation, mpv→CPU copy, and CPU→GPU `texture.replace` upload all go away; mpv renders directly into GPU-resident memory and Metal blits to the drawable.

**Architecture:** `MPVSourcePlayer` grows a parallel `attachRenderGL(...)` / `renderIntoGL(layer:drawableSize:commandQueue:)` pair. The GL render context is created with `MPV_RENDER_PARAM_API_TYPE = MPV_RENDER_API_TYPE_OPENGL` and `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS` whose `get_proc_address` resolves through `CGLGetProcAddress` (legacy CGL, the macOS path called out in `render_gl.h`). `MPVRenderingNSView` keeps its `CAMetalLayer` + `CVDisplayLink` + cached `MTLDevice`/`MTLCommandQueue`, but instead of allocating a CPU pixel buffer, it owns a small `GLMetalBridge` actor-free helper that:

1. Creates a per-size `IOSurface` (BGRA8, width×height in drawable pixels).
2. Creates an `NSOpenGLContext` (legacy `NSOpenGLPixelFormat`) and binds an `IOSurface`-backed `GL_TEXTURE_RECTANGLE` via `CGLTexImageIOSurface2D`.
3. Wraps that texture in a single GL FBO whose color attachment is the IOSurface texture.
4. Creates a Metal `MTLTexture` over the same `IOSurface` via `device.makeTexture(descriptor:iosurface:plane:)`.

Per-frame: GL context made current → `mpv_render_context_render` with `MPV_RENDER_PARAM_OPENGL_FBO` and `MPV_RENDER_PARAM_FLIP_Y=1` → `glFlush` → blit-encoder copies the IOSurface-backed Metal texture into the layer's drawable → present. The IOSurface is the zero-copy hand-off; no `bytesPerRow * height` CPU buffer, no `texture.replace`, no `MPV_RENDER_PARAM_SW_*`.

The existing `renderLock` + `renderContext` lifecycle, the `attachRender`/`detachRender` pairing, the `viewDidMoveToWindow`/`setFrameSize`/`viewDidChangeBackingProperties` size-tracking overrides, and `MPVRenderingNSView`'s `tearDown()` are preserved. Only the *body* of the per-frame path changes; the *structure* doesn't. The SW path (`attachRender` + `renderInto`) stays in the source tree behind a `mpvRenderBackend` enum so a single-line change reverts to it if anything regresses.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, libmpv (via MPVKit `Libmpv` module), legacy OpenGL 3.2 Core Profile (CGL), Metal, `IOSurface`, `CVDisplayLink`, XCTest.

**Companion documents:**
- `docs/plans/2026-05-01-source-playback-mpv-migration-design.md` — the full mpv migration design (D1–D15 + adversarial-review history). Section "D6 hwdec" and the "H3" review finding about Phase 1's SW gate are the *why* behind this swap.
- `docs/plans/2026-05-01-source-playback-mpv-migration.md` — the executed migration plan that left the render path on SW, and acknowledged this swap as deferred follow-up.
- `/tmp/metal-swap-prompt.md` — the cold-start prompt that motivated this plan (Path A vs Path B trade-off framing).

**Test commands:**
- `xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels` — XCUITest harness; saves `/tmp/xcui-mpv-bringup.png`. Must still pass after the swap.
- `./scripts/run.sh` — manual smoke for 4K HEVC playback against `/tmp/mpv-test-fixture.mp4`. Compare Activity Monitor sustained CPU vs `main`.

**Build-system note (Phase 0.2 found):** `scripts/run.sh` only re-runs `xcodegen` when `project.yml` is newer than `*.pbxproj`. When a task adds *new* `.swift` or `.h` source files, run `xcodegen generate` manually before `xcodebuild`, or the new files won't be in the build target.

**Branching:** Land on a separate branch off `feat/impl-phases-1-4-9` (currently `a09101a`). Suggested name: `feat/source-playback-gl-render`. The SW path stays as the safe fallback if Metal regresses anything.

---

## Path-decision rationale (review this first)

The cold-start prompt presented two viable paths:

- **Path A — `MPV_RENDER_API_TYPE_OPENGL`** with the OpenGL render API, GL→Metal bridged via shared `IOSurface`. IINA's approach. **Selected.**
- **Path B — `vo=gpu-next` + `wid=<NSView*>`** native embed: mpv's gpu-next VO uses Metal internally on macOS; passing `wid` lets mpv create its own CALayer hierarchy inside our NSView, bypassing `mpv_render_context` entirely.

I checked MPVKit 0.41.0's actual exposed surface in
`~/Library/Developer/Xcode/DerivedData/VideoCoach-aldlfihezaflyucqutmrgkalqixu/SourcePackages/artifacts/mpvkit/Libmpv/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers/mpv/`.
Three relevant headers ship: `client.h`, `render.h`, `render_gl.h`. The exposed `MPV_RENDER_PARAM_*` enum lists OpenGL and SW; no Metal API type. So Path A's API surface is verified to exist; Path B does not require new render-context constants but does require setting `wid` on the *core* `mpv_handle` and switching to `vo=gpu-next` from `vo=libmpv`.

| Trade-off | Path A (chosen) | Path B |
|---|---|---|
| API surface available in MPVKit 0.41.0 | Yes (`render_gl.h` confirmed) | Yes — `wid` works against any `mpv_handle`; no extra header constant needed |
| Lifecycle control | We own `mpv_render_context_create/free`; matches existing `attachRender`/`detachRender` | `vo=gpu-next` teardown semantics when the host NSView leaves/re-enters a window are undocumented; the existing mount→unmount→remount lifecycle path (`viewWillMove(toWindow:nil)` + `updatePlayer(_:)` identity-swap) would not reliably surface a latent context leak or layer orphan before shipping |
| Compositor architecture | Metal stays the final compositor (matches the rest of the app's GPU path) | mpv replaces the visible layer; harder to layer Metal overlays on top later |
| First-responder + click handling | Unchanged; `MPVRenderingNSView` still owns the surface | mpv's NSView likely intercepts mouse events; Phase-3 first-responder fix (`3ab22aa`) at risk |
| GL deprecation on macOS | Functional through macOS 15; deprecated since 10.14 — long tail | Same dylib backend, no GL on the app side |
| Implementation complexity | Medium: GL context + IOSurface + FBO + GL→Metal blit | Low–medium *if* `wid` works as advertised on macOS arm64; high if it doesn't |
| Reversibility | Single-flag swap back to SW preserved | Switching VO at runtime requires `mpv_set_property("vo", ...)` and a stream restart |
| Binary size | No new dylibs | No new dylibs |

**Why A wins for us:** the existing `attachRender`/`detachRender` pairing, the `renderLock`, the `framebufferOnly = false` drawable, and the SwiftUI `NSViewRepresentable`-driven view lifecycle were all built around the assumption that *we* own the render context. Path A keeps that. Path B inverts it. The user's prior preference (per H3 in the migration plan's review history) was to preserve the rendering boundary the migration plan locked in.

**Open the door for Path B in review.** If the adversarial reviewer can show that `wid`+`vo=gpu-next` cleanly preserves teardown, click handling, and the `updatePlayer(_:)` identity-swap path, Path B is *simpler* and worth reconsidering. This decision should be challenged.

---

## Adversarial review history (plan v1 → v2)

The first draft was reviewed by `feature-dev:code-reviewer`. Findings folded into v2 (this document) before any execution:

| Finding | Where it lives now |
|---------|-------------------|
| **GL context must be current on the calling thread when `mpv_render_context_create` runs** — `render_gl.h` says all `mpv_render_*` calls implicitly use the GL context, and `create` calls `get_proc_address` to resolve every entry point. Plan v1 only made the context current inside `renderIntoGL`, so `create` would resolve NULL pointers. | Phase 2 Task 2.1 — `attachRenderGL` now takes the `NSOpenGLContext` as a parameter, calls `makeCurrentContext()` before `mpv_render_context_create`, and calls `NSOpenGLContext.clearCurrentContext()` after success so the display-link thread can acquire the context cleanly. |
| **GL context cannot be left current on the main thread after `attachRenderGL`** — display-link thread later calls `makeCurrentContext`, and CGL treats "current on another thread" as a fatal error on some drivers. | Phase 2 Task 2.1 — explicit `NSOpenGLContext.clearCurrentContext()` after `mpv_render_context_create` returns. |
| **`vcGLGetProcAddress` cannot use `CFBundleGetFunctionPointerForName`** — `OpenGL.framework` does not export 3.x Core entry points (`glGenVertexArrays`, draw variants, etc.) as flat-namespace symbols; the resolver must be `CGLGetProcAddress`, which dispatches through CGL's private function-pointer table. The v1 claim that `CGLGetProcAddress` "does not exist on macOS" was wrong — it is declared in `<OpenGL/OpenGL.h>`. Phase 0.2 would have passed (no mpv involved); Phase 3 would have crashed at first shader compile. | Phase 2 Task 2.3 — body of `vcGLGetProcAddress` rewritten to call `CGLGetProcAddress`. Adds bridging-header import for `<OpenGL/OpenGL.h>`. |
| **`renderIntoGL` called `bridge.resize(...)` before `makeCurrentContext()`** — `resize` issues `glGenTextures`/`glDeleteTextures`/`glGenFramebuffers`, which silently no-op or crash without a current context. | Phase 2 Task 2.2 — `bridge.glContext.makeCurrentContext()` is hoisted to the first line after the `renderLock` + `renderContext` + size guards, before `bridge.resize(...)`. |
| **Task 3.4 prose justified teardown safety with the wrong mechanism** — claimed `renderIntoGL`'s try-lock provides mutual exclusion; actually the *blocking* `renderLock.lock()` inside `detachRender` waits for any in-flight render call. Code was correct; prose was misleading. | Phase 3 Task 3.4 — "Order claim" paragraph rewritten to attribute safety to `detachRender`'s blocking lock + `CVDisplayLinkStop`, with the try-lock as a best-effort skip on the render side. |
| **Phase 1 Task 1.3 used `git revert` + `git commit --amend` to "preserve history" of a throwaway demo** — leaves `HEAD~1` as a broken intermediate that wires a synthetic test view into the bring-up window. Repeats the "edit then revert" anti-pattern the prior migration plan's review explicitly flagged. | Phase 1 Task 1.3 — `MPVRenderBackend` gains a permanent `.glBridgeDemo` case that drives the bridge with a clear-color test pattern. Bring-up debug picker exposes it. No revert. |
| **Path-B rejection rationale referenced "no Metal API type in MPVKit headers"** — Path B never needed a render-context constant (it uses `mpv_set_option("wid", ...)`). Real reason to reject is undocumented `vo=gpu-next` teardown semantics when the host NSView leaves/re-enters a window. | Path-decision rationale — "Lifecycle control" row reframed around teardown semantics, not header surface. |

---

## Phase 0 — De-risk gate

The whole plan rests on the assumption that legacy CGL still works inside our hardened-runtime, non-sandboxed app on macOS 14+ arm64. Phase 0 spends ~30 minutes proving the foundations before any mpv code is touched. If any gate check fails, stop and re-plan.

### Task 0.1: Confirm `render_gl.h` is reachable from Swift via the `Libmpv` module

**Files:**
- Read-only check.

**Step 1: Grep the resolved module headers.**

Run:
```bash
ls /Users/taylor/Library/Developer/Xcode/DerivedData/VideoCoach-aldlfihezaflyucqutmrgkalqixu/SourcePackages/artifacts/mpvkit/Libmpv/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers/mpv/
```
Expected: `client.h  render.h  render_gl.h  stream_cb.h`. If `render_gl.h` is missing, MPVKit was vended without GL — escalate before continuing.

**Step 2: Confirm Swift sees `MPV_RENDER_API_TYPE_OPENGL` and `mpv_opengl_init_params`.**

Add this temporary file:
```swift
// App/Source/_GLProbe.swift — TEMPORARY, deleted at end of Task 0.1
import Libmpv

func _glProbe() {
    let _: UnsafePointer<CChar> = MPV_RENDER_API_TYPE_OPENGL
    var p = mpv_opengl_init_params(get_proc_address: nil, get_proc_address_ctx: nil)
    _ = p
}
```

Run: `xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'`

Expected: clean build. If the symbols don't resolve, the umbrella `Libmpv` modulemap doesn't include `render_gl.h` — fix by adding `header "mpv/render_gl.h"` to the modulemap *or* fall back to a bridging header. Record outcome.

**Step 3: Delete `_GLProbe.swift` after the build succeeds. Commit nothing.**

### Task 0.2: Confirm `NSOpenGLContext` + `CGLTexImageIOSurface2D` work under hardened runtime

**Files:**
- Create: `App/Source/_GLContextProbe.swift` — TEMPORARY, deleted at end of Task 0.2.

**Step 1: Add the probe.** This creates an `NSOpenGLContext` with a 3.2 Core profile, makes it current, allocates an `IOSurface`, binds a `GL_TEXTURE_RECTANGLE` to it, and creates an FBO with that texture as a color attachment. If hardened runtime + library validation reject any of this, we find out now.

```swift
// App/Source/_GLContextProbe.swift
import AppKit
import OpenGL.GL3
import IOSurface
import CoreVideo

@MainActor
func _glContextProbe() throws {
    let attribs: [NSOpenGLPixelFormatAttribute] = [
        NSOpenGLPFAAccelerated, NSOpenGLPFADoubleBuffer, NSOpenGLPFAAllowOfflineRenderers,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFAOpenGLProfile, NSOpenGLPFAOpenGLProfile_t(NSOpenGLProfileVersion3_2Core),
        0
    ].map { NSOpenGLPixelFormatAttribute($0) }

    guard let pf = NSOpenGLPixelFormat(attributes: attribs) else { fatalError("pf nil") }
    guard let ctx = NSOpenGLContext(format: pf, share: nil) else { fatalError("ctx nil") }
    ctx.makeCurrentContext()

    let w: Int = 1920, h: Int = 1080
    let props: [IOSurfacePropertyKey: Any] = [
        .width: w, .height: h, .bytesPerElement: 4,
        .pixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
    ]
    guard let surface = IOSurface(properties: props) else { fatalError("ios nil") }

    var tex: GLuint = 0
    glGenTextures(1, &tex)
    glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), tex)
    let cgl = CGLGetCurrentContext()!
    let r = CGLTexImageIOSurface2D(
        cgl, GLenum(GL_TEXTURE_RECTANGLE),
        GLenum(GL_RGBA), GLsizei(w), GLsizei(h),
        GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
        Unmanaged.passUnretained(surface).toOpaque(), 0
    )
    assert(r == kCGLNoError, "CGLTexImageIOSurface2D failed: \(r)")

    var fbo: GLuint = 0
    glGenFramebuffers(1, &fbo)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                           GLenum(GL_TEXTURE_RECTANGLE), tex, 0)
    let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
    assert(status == GLenum(GL_FRAMEBUFFER_COMPLETE), "FBO incomplete: \(status)")

    glDeleteFramebuffers(1, &fbo)
    glDeleteTextures(1, &tex)
}
```

**Step 2: Wire the probe into `applicationDidFinishLaunching` temporarily.**

Find `App/VideoCoachApp.swift` (or the `NSApplicationDelegate` adapter) and add a one-liner that calls `try? _glContextProbe()` once at startup.

**Step 3: Build and run.** Expected: app launches with no `EXC_BAD_INSTRUCTION` from the asserts and no library-validation errors in Console.app. Watch Console.app for `dyld` errors specifically. If any assert trips, capture the GL error code and stop.

**Step 4: Revert the wiring and delete `_GLContextProbe.swift`.** Commit nothing.

### Task 0.3: Capture the SW-path baseline

**Files:** read-only.

We need a CPU + dropped-frame baseline against `/tmp/mpv-test-fixture.mp4` so Phase 5 can prove the swap actually helped.

**Step 1: Build `main` (or the current branch tip) without GL changes.**

```bash
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```

**Step 2: Launch via `./scripts/run.sh`, open the most-recent project (auto-load is in place), let the 4K HEVC source play for 60 seconds.**

**Step 3: Record in `docs/plans/2026-05-01-source-playback-metal-render-swap.md`** under a new "Baseline measurements" section at the bottom of this file:

- Activity Monitor sustained `VideoCoach` CPU% (single-window mean over 60s)
- `mpv stats` "Dropped: …" (toggled via `playbackHotkeys` if available; otherwise capture mpv log lines if `msg-level` permits)
- Total resident memory

**Step 4: Commit the baseline numbers.**
```bash
git add docs/plans/2026-05-01-source-playback-metal-render-swap.md
git commit -m "docs(metal-swap): record SW-path baseline for Phase 5 comparison"
```

---

## Phase 1 — Standalone GL+IOSurface→Metal scaffold

Before introducing mpv into the picture, build the GL→IOSurface→Metal bridge against a *known* GL workload (a fragment-shader test pattern). If pixels show up correctly at 4K with the right backing scale, we know the bridge is sound and any later breakage is mpv-side. This is the highest-value de-risking phase in the plan.

### Task 1.1: Add the `GLMetalBridge` skeleton

**Files:**
- Create: `App/Source/GLMetalBridge.swift`

**Step 1: Write the failing test.**

Create: `Tests/AppTests/GLMetalBridgeTests.swift`

```swift
import XCTest
import Metal
@testable import VideoCoach

final class GLMetalBridgeTests: XCTestCase {
    func test_bridge_creates_iosurface_at_requested_size() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let bridge = try GLMetalBridge(device: device)
        try bridge.resize(to: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(bridge.surfaceWidth, 1920)
        XCTAssertEqual(bridge.surfaceHeight, 1080)
        XCTAssertNotNil(bridge.metalTexture)
        XCTAssertEqual(bridge.metalTexture?.width, 1920)
    }
}
```

Run: `xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachTests/GLMetalBridgeTests/test_bridge_creates_iosurface_at_requested_size`
Expected: FAIL — `GLMetalBridge` does not exist.

**Step 2: Implement the skeleton.**

```swift
// App/Source/GLMetalBridge.swift
import Foundation
import AppKit
import Metal
import OpenGL.GL3
import IOSurface
import CoreVideo

/// Owns the GL context, IOSurface, GL texture, GL FBO, and Metal texture
/// that bridge mpv's GL output to a CAMetalLayer drawable. One bridge per
/// MPVRenderingNSView. Not thread-safe; the owner serializes access via the
/// view's renderLock-equivalent.
final class GLMetalBridge {
    let glContext: NSOpenGLContext
    let device: MTLDevice
    private(set) var surface: IOSurfaceRef?
    private(set) var glTexture: GLuint = 0
    private(set) var fbo: GLuint = 0
    private(set) var metalTexture: MTLTexture?
    private(set) var surfaceWidth: Int = 0
    private(set) var surfaceHeight: Int = 0

    init(device: MTLDevice) throws {
        self.device = device
        // Note: use NSOpenGLPixelFormatAttribute(...) to cast each element — there
        // is no NSOpenGLPFAOpenGLProfile_t symbol (Phase 0.2 found this typo).
        let attribs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAllowOfflineRenderers),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            0,
        ]
        guard let pf = NSOpenGLPixelFormat(attributes: attribs),
              let ctx = NSOpenGLContext(format: pf, share: nil) else {
            throw GLMetalBridgeError.glContextFailed
        }
        self.glContext = ctx
    }

    func resize(to size: CGSize) throws {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        if w == surfaceWidth, h == surfaceHeight, surface != nil { return }

        teardownGLObjects()

        let props: [IOSurfacePropertyKey: Any] = [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
        ]
        guard let s = IOSurface(properties: props) else { throw GLMetalBridgeError.iosurfaceFailed }
        let cfSurface = s as IOSurfaceRef  // Phase 0.2 found this is the right bridge form
        self.surface = cfSurface

        glContext.makeCurrentContext()
        glGenTextures(1, &glTexture)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), glTexture)
        let cgl = CGLGetCurrentContext()!
        let r = CGLTexImageIOSurface2D(
            cgl, GLenum(GL_TEXTURE_RECTANGLE),
            GLenum(GL_RGBA), GLsizei(w), GLsizei(h),
            GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            cfSurface, 0
        )
        guard r == kCGLNoError else { throw GLMetalBridgeError.cglTexImageFailed(Int(r)) }

        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_RECTANGLE), glTexture, 0
        )
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw GLMetalBridgeError.fboIncomplete
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard let mtl = device.makeTexture(descriptor: desc, iosurface: cfSurface, plane: 0) else {
            throw GLMetalBridgeError.metalTextureFailed
        }
        self.metalTexture = mtl
        self.surfaceWidth = w
        self.surfaceHeight = h
    }

    private func teardownGLObjects() {
        glContext.makeCurrentContext()
        if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
        if glTexture != 0 { glDeleteTextures(1, &glTexture); glTexture = 0 }
        metalTexture = nil
        surface = nil
    }

    deinit { teardownGLObjects() }
}

enum GLMetalBridgeError: Error {
    case glContextFailed
    case iosurfaceFailed
    case cglTexImageFailed(Int)
    case fboIncomplete
    case metalTextureFailed
}
```

**Step 3: Run the test.**

Run: `xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachTests/GLMetalBridgeTests/test_bridge_creates_iosurface_at_requested_size`
Expected: PASS.

**Step 4: Commit.**

```bash
git add App/Source/GLMetalBridge.swift Tests/AppTests/GLMetalBridgeTests.swift
git commit -m "feat(render): add GLMetalBridge skeleton (IOSurface + GL FBO + Metal texture)"
```

### Task 1.2: Render a known fragment-shader test pattern through the bridge

Why: prove the GL→IOSurface→Metal hand-off works with *a* GL workload before adding mpv. If a checkerboard shows up correctly at 4K, the only remaining unknowns are mpv-specific.

**Files:**
- Modify: `App/Source/GLMetalBridge.swift` — add a `clearTo(red:green:blue:)` helper that issues `glClear` against the FBO.
- Create: `Tests/AppTests/GLMetalBridgeRenderTests.swift`

**Step 1: Write the failing test.**

```swift
func test_clear_to_red_shows_red_in_metal_texture_bytes() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let bridge = try GLMetalBridge(device: device)
    try bridge.resize(to: CGSize(width: 64, height: 64))
    bridge.clearTo(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    glFlush()  // ensure GL writes are visible to Metal via IOSurface

    // Read the Metal texture back via getBytes (storageMode .shared makes this safe).
    let tex = bridge.metalTexture!
    var pixel = [UInt8](repeating: 0, count: 4)
    tex.getBytes(&pixel, bytesPerRow: tex.width * 4,
                 from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    // BGRA8Unorm: [B, G, R, A]. Red = (0, 0, 255, 255).
    XCTAssertEqual(pixel[0], 0)
    XCTAssertEqual(pixel[1], 0)
    XCTAssertEqual(pixel[2], 255)
    XCTAssertEqual(pixel[3], 255)
}
```

Run: expected FAIL (`clearTo` not implemented).

**Step 2: Implement `clearTo`.**

```swift
func clearTo(red: Float, green: Float, blue: Float, alpha: Float) {
    glContext.makeCurrentContext()
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    glViewport(0, 0, GLsizei(surfaceWidth), GLsizei(surfaceHeight))
    glClearColor(GLfloat(red), GLfloat(green), GLfloat(blue), GLfloat(alpha))
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
}
```

**Step 3: Run the test.** Expected PASS. If it fails with non-red bytes, the IOSurface bridge has a colorspace or byte-order bug — fix before continuing.

**Step 4: Commit.**

```bash
git add App/Source/GLMetalBridge.swift Tests/AppTests/GLMetalBridgeRenderTests.swift
git commit -m "test(render): GLMetalBridge clear writes pixels visible to Metal"
```

### Task 1.3: Blit IOSurface-backed Metal texture into a CAMetalLayer drawable

This proves the second half of the path: bridge → drawable → present.

**Files:**
- Modify: `App/Source/GLMetalBridge.swift` — add `present(into layer: CAMetalLayer, commandQueue: MTLCommandQueue)`.

**Step 1: Implement the present helper.**

```swift
func present(into layer: CAMetalLayer, commandQueue: MTLCommandQueue) {
    guard let mtl = metalTexture, let drawable = layer.nextDrawable() else { return }
    let target = drawable.texture
    guard let cmd = commandQueue.makeCommandBuffer(),
          let blit = cmd.makeBlitCommandEncoder() else { return }
    let copyW = min(mtl.width, target.width)
    let copyH = min(mtl.height, target.height)
    blit.copy(
        from: mtl, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOriginMake(0, 0, 0),
        sourceSize: MTLSizeMake(copyW, copyH, 1),
        to: target, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOriginMake(0, 0, 0)
    )
    blit.endEncoding()
    cmd.present(drawable)
    cmd.commit()
}
```

**Step 2: Add a permanent `GLBridgeDemoRepresentable` debug view + a Debug-menu entry.** Following the migration plan's "edit then revert invited accidental commits" finding, this demo is *kept* as a permanent debug escape hatch, not a throwaway revert.

Create: `App/Views/GLBridgeDemoView.swift`

```swift
// SwiftUI representable that drives a GLMetalBridge with clearTo(red,green,blue,alpha)
// from a CVDisplayLink. Used to verify the GL→IOSurface→Metal hand-off
// independent of mpv. Permanent debug fixture — exposed via the Debug menu.
struct GLBridgeDemoRepresentable: NSViewRepresentable {
    let r: Float
    let g: Float
    let b: Float
    func makeNSView(context: Context) -> GLBridgeDemoNSView { GLBridgeDemoNSView(r: r, g: g, b: b) }
    func updateNSView(_ nsView: GLBridgeDemoNSView, context: Context) {}
}

final class GLBridgeDemoNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bridge: GLMetalBridge
    private var displayLink: CVDisplayLink?
    private let r: Float; private let g: Float; private let b: Float

    init(r: Float, g: Float, b: Float) {
        self.r = r; self.g = g; self.b = b
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { fatalError("Metal device unavailable") }
        self.device = dev
        self.commandQueue = q
        self.bridge = (try? GLMetalBridge(device: dev))!
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let s = window?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(width: max(1, newSize.width * s), height: max(1, newSize.height * s))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard let self else { return kCVReturnSuccess }
                let size = self.metalLayer.drawableSize
                guard size.width > 0, size.height > 0 else { return kCVReturnSuccess }
                try? self.bridge.resize(to: size)
                self.bridge.clearTo(red: self.r, green: self.g, blue: self.b, alpha: 1.0)
                glFlush()
                self.bridge.present(into: self.metalLayer, commandQueue: self.commandQueue)
                return kCVReturnSuccess
            }
            _ = CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }
}
```

Wire a Debug menu entry that opens a window hosting `GLBridgeDemoRepresentable(r: 1, g: 0, b: 0)`. Pattern matches the existing "MPV Bring-up Window" entry — find it in the same Debug-menu file and add a sibling entry "GL Bridge Demo (Red)".

**Step 3: Build + open Debug → GL Bridge Demo (Red).** Expected: solid red full-screen view at backing-scale resolution. Resize the window; the bridge resizes; still red. If the layer renders black or a wrong-coloured stripe, halt and diagnose.

**Step 4: Commit the demo as a permanent debug fixture.**

```bash
git add App/Views/GLBridgeDemoView.swift App/<DebugMenuFile>.swift
git commit -m "feat(render-debug): GLBridgeDemo view exercises GL→IOSurface→Metal in isolation"
```

---

## Phase 2 — Add `attachRenderGL` / `renderIntoGL` to `MPVSourcePlayer`

mpv side. The existing SW path is untouched; we add a parallel GL path. The `mpvRenderBackend` enum is added in Phase 3 once both paths exist and the view can choose.

### Task 2.1: Add the GL render-context attach

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift:329-358` (the `attachRender()` body).

**Step 1: Write the failing test.**

This is hard to unit-test without a GL context — defer the test to Phase 3's view-level integration. Skip the unit test here and rely on Phase 3's XCUITest for integration coverage. Record the deviation in the commit message.

**Step 2: Add `attachRenderGL(glContext:getProcAddress:)` next to the existing `attachRender()`.**

> **Why the GL context is a parameter:** `render_gl.h` requires that the GL context be current on the calling thread when `mpv_render_context_create` runs — `create` calls `get_proc_address` to resolve every entry point, and the resolver dispatches through CGL, which needs a current context. We accept the `NSOpenGLContext` so we can `makeCurrentContext()` here, then `clearCurrentContext()` after `create` succeeds so the display-link thread can acquire the context for subsequent renders.

```swift
public func attachRenderGL(
    glContext: NSOpenGLContext,
    getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
) throws {
    renderLock.lock(); defer { renderLock.unlock() }
    guard renderContext == nil else { throw MPVSourcePlayerError.alreadyAttached }

    // GL context MUST be current on this thread before mpv_render_context_create —
    // create() calls get_proc_address synchronously, and CGL's resolver requires a
    // current context. After create() returns we clear the context on this thread
    // so the CVDisplayLink render thread can make it current safely.
    glContext.makeCurrentContext()

    var apiTypeBuf = Array("opengl".utf8CString)
    var advancedControl: Int32 = 0  // keep simple per render.h "Threading" warning

    let rc: CInt = apiTypeBuf.withUnsafeMutableBufferPointer { apiBuf -> CInt in
        var glInit = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )
        return withUnsafeMutablePointer(to: &glInit) { glInitPtr -> CInt in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                 data: UnsafeMutableRawPointer(apiBuf.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                 data: UnsafeMutableRawPointer(glInitPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                                 data: withUnsafeMutableBytes(of: &advancedControl) { $0.baseAddress }),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var ctx: OpaquePointer?
            let r = params.withUnsafeMutableBufferPointer {
                mpv_render_context_create(&ctx, handle, $0.baseAddress)
            }
            if r >= 0, let ctx { self.renderContext = ctx }
            return r
        }
    }

    // Always clear, even on failure — the context is "owned" by the render
    // thread from this point on. Leaving it current on main is what causes
    // CGL "context already current on another thread" fatals on some drivers.
    NSOpenGLContext.clearCurrentContext()

    guard rc >= 0, renderContext != nil else {
        throw MPVSourcePlayerError.renderContextFailed(code: Int(rc))
    }
}
```

> **Lifetime note:** `mpv_render_context_create` reads the params array synchronously and copies what it needs. The local `glInit`, `apiBuf`, and `params` array can safely go out of scope on return. The `get_proc_address` *callback* must remain valid for the lifetime of the render context — we use a `@convention(c)` function pointer (no captured Swift closure), so this is a global function passed by reference and lifetime is automatic. The `NSOpenGLContext` itself must outlive the render context — that's owned by `GLMetalBridge`, whose lifetime is the view's, which encloses the player's render-context lifetime.

**Step 3: Build to confirm symbols resolve.**

```bash
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```
Expected: clean build. If `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS` doesn't resolve, revisit Phase 0 Task 0.1's modulemap finding.

**Step 4: Commit.**

```bash
git add App/Source/MPVSourcePlayer.swift
git commit -m "feat(source-playback): add attachRenderGL to MPVSourcePlayer (parallel to SW)"
```

### Task 2.2: Add `renderIntoGL(layer:drawableSize:commandQueue:bridge:)`

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift` — add a parallel render method.

**Step 1: Implement.**

```swift
public nonisolated func renderIntoGL(
    layer: CAMetalLayer,
    drawableSize: CGSize,
    commandQueue: MTLCommandQueue,
    bridge: GLMetalBridge
) {
    guard renderLock.try() else { return }
    defer { renderLock.unlock() }
    guard let renderContext else { return }

    let w = Int32(drawableSize.width)
    let h = Int32(drawableSize.height)
    guard w > 0, h > 0 else { return }

    // GL context MUST be current before any GL call — bridge.resize() issues
    // glGenTextures/glDeleteTextures/glGenFramebuffers internally, so the
    // makeCurrent has to happen before resize, not after. (v1 had this
    // backwards; the first frame would have silently no-op'd or crashed.)
    bridge.glContext.makeCurrentContext()

    do {
        try bridge.resize(to: drawableSize)
    } catch {
        return  // resize failed; skip this frame, log handled at bridge layer
    }

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), bridge.fbo)
    glViewport(0, 0, GLsizei(w), GLsizei(h))

    var fbo = mpv_opengl_fbo(
        fbo: Int32(bridge.fbo),
        w: w, h: h,
        internal_format: 0  // 0 = "unknown / default"; mpv tolerates this for our case
    )
    var flipY: Int32 = 1  // GL framebuffer is flipped vs mpv's natural orientation

    let _: CInt = withUnsafeMutablePointer(to: &fbo) { fboPtr -> CInt in
        return withUnsafeMutablePointer(to: &flipY) { flipPtr -> CInt in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO,
                                 data: UnsafeMutableRawPointer(fboPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y,
                                 data: UnsafeMutableRawPointer(flipPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return params.withUnsafeMutableBufferPointer {
                mpv_render_context_render(renderContext, $0.baseAddress)
            }
        }
    }
    glFlush()  // ensure GL writes are visible to Metal via IOSurface before the blit

    bridge.present(into: layer, commandQueue: commandQueue)
}
```

> **flipY note:** `MPV_RENDER_PARAM_FLIP_Y=1` is the default convention when rendering into a default GL framebuffer (origin at bottom-left). Our FBO has the same origin, so the flip is needed. If the picture comes out upside-down, this flag is the lever.

**Step 2: Build to confirm.**

```bash
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```
Expected: clean build.

**Step 3: Commit.**

```bash
git add App/Source/MPVSourcePlayer.swift
git commit -m "feat(source-playback): add renderIntoGL using GLMetalBridge"
```

### Task 2.3: Provide a top-level `glProcAddress` C function

**Why:** `mpv_opengl_init_params.get_proc_address` is `@convention(c)`, so we can't pass a Swift closure that captures state. We expose a free function whose context pointer is the `NSOpenGLContext` we want to query.

**Files:**
- Modify: `App/Source/GLMetalBridge.swift` — add a free function plus a static helper to feed it the right context.

**Step 1: Add the function.**

> **Why `CGLGetProcAddress`, not `CFBundleGetFunctionPointerForName`** (correcting v1): `OpenGL.framework` does not export 3.x Core Profile entry points (`glGenVertexArrays`, draw variants, etc.) as flat-namespace symbols. `CFBundleGetFunctionPointerForName` returns NULL for them. `CGLGetProcAddress` is declared in `<OpenGL/OpenGL.h>` and dispatches through CGL's private function-pointer table — this is what IINA and every other libmpv-on-macOS embedder uses.

`CGLGetProcAddress` is not in Swift's `OpenGL` overlay, so we expose it via a bridging header.

Create: `App/Source/CGLBridge.h`

```c
#ifndef CGLBridge_h
#define CGLBridge_h
#include <OpenGL/OpenGL.h>
// CGLGetProcAddress takes const GLubyte* but mpv hands us const char*.
// Bridge function with the right signature for direct use from Swift.
static inline void *vc_cgl_get_proc_address(const char *name) {
    return CGLGetProcAddress((const GLubyte *)name);
}
#endif
```

Add `#import "CGLBridge.h"` to the existing app bridging header (or create one named `App/VideoCoach-Bridging-Header.h` and set `SWIFT_OBJC_BRIDGING_HEADER` in `project.yml` if missing — record which path is taken in the commit message).

Then the Swift glue:

```swift
// At file scope, outside the class.
@_cdecl("vcGLGetProcAddress")
func vcGLGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return vc_cgl_get_proc_address(name)
}
```

**Step 2: Build.**

```bash
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```

**Step 3: Commit.**

```bash
git add App/Source/GLMetalBridge.swift
git commit -m "feat(render): add vcGLGetProcAddress for mpv OpenGL init"
```

---

## Phase 3 — `MPVRenderingNSView` switch and `mpvRenderBackend` flag

### Task 3.1: Add the backend enum and route attach/render through it

**Files:**
- Modify: `App/Views/MPVPlayerView.swift`

**Step 1: Define `MPVRenderBackend`.**

At file scope above `MPVRenderingNSView`:

```swift
enum MPVRenderBackend {
    case sw
    case glToMetal

    /// Production default; flip back to .sw if a regression appears.
    static let production: MPVRenderBackend = .glToMetal
}
```

**Step 2: Give `MPVRenderingNSView` a `backend` property.**

```swift
private let backend: MPVRenderBackend
private var bridge: GLMetalBridge?

init(frame: NSRect, backend: MPVRenderBackend = .production) {
    self.backend = backend
    // … existing init body
}
```

**Step 3: Route `attachRenderAndStart`** (currently `MPVPlayerView.swift:127`) to call `attachRenderGL` for `.glToMetal`:

```swift
@MainActor
private func attachRenderAndStart(player: MPVSourcePlayer) throws {
    switch backend {
    case .sw:
        try player.attachRender()
    case .glToMetal:
        if bridge == nil {
            bridge = try GLMetalBridge(device: device)
        }
        try player.attachRenderGL(
            glContext: bridge!.glContext,
            getProcAddress: vcGLGetProcAddress
        )
    }
    // … existing CVDisplayLink wiring (unchanged)
}
```

**Step 4: Route `renderTick`** (currently `MPVPlayerView.swift:144`) to the right method:

```swift
private func renderTick() {
    let layer = self.metalLayer
    let size = layer.drawableSize
    let queue = self.commandQueue
    guard let player = self.player else { return }
    switch backend {
    case .sw:
        player.renderInto(layer: layer, drawableSize: size, commandQueue: queue)
    case .glToMetal:
        guard let bridge = self.bridge else { return }
        player.renderIntoGL(layer: layer, drawableSize: size, commandQueue: queue, bridge: bridge)
    }
}
```

**Step 5: Build.**

```bash
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```

**Step 6: Commit.**

```bash
git add App/Views/MPVPlayerView.swift
git commit -m "feat(render): route MPVRenderingNSView through MPVRenderBackend"
```

### Task 3.2: Run the XCUITest with `.glToMetal`

The bring-up window's `MPVDebugRepresentable` constructs `MPVRenderingNSView(frame: .zero)`, which now defaults to `.production = .glToMetal`. So no test wiring change is needed — just run the harness.

**Step 1: Build + run the existing harness.**

```bash
xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels
```
Expected: PASS, with `/tmp/xcui-mpv-bringup.png` showing the test-fixture frame.

**Step 2: Visually verify the screenshot.**

Read `/tmp/xcui-mpv-bringup.png` (the orchestrator can `Read` the file). Pixels should match the fixture's first second of video, not be all-black, all-red, or vertically flipped.

If the image is **all-black**: bridge created but mpv didn't render → inspect mpv log for "vo: …" lines indicating wrong VO; confirm `vo=libmpv` is still set (it is, in `MPVSourcePlayer.init`).

If the image is **vertically flipped**: toggle `MPV_RENDER_PARAM_FLIP_Y` from 1 → 0.

If the image has **wrong colors** (red↔blue swap): the IOSurface format/pixelFormat→Metal pixelFormat mismatch — confirm both are BGRA8.

**Step 3: Commit only after the screenshot looks right.**

```bash
# No file changes if green; tag the moment.
git commit --allow-empty -m "test(render): XCUITest passes with .glToMetal backend"
```

### Task 3.3: Handle resize and backing-scale changes

**Why:** `setFrameSize`, `viewDidChangeBackingProperties`, and `viewDidMoveToWindow` already call `updateDrawableSize()` (which sets `metalLayer.drawableSize`). The bridge's `resize(to:)` is invoked from `renderIntoGL` on every tick — it's a no-op when the size is unchanged, so this is already covered. Verify by Retina-vs-non-Retina screen drag.

**Step 1: Manual verification.**

Drag the bring-up window from a Retina display to a non-Retina display (or vice-versa). Expected: video continues rendering at the right resolution.

**Step 2: Add a defensive log inside `GLMetalBridge.resize` when the surface is recreated, gated on `#if DEBUG`.**

```swift
#if DEBUG
NSLog("[GLMetalBridge] resize: \(surfaceWidth)x\(surfaceHeight) → \(w)x\(h)")
#endif
```

**Step 3: Commit.**

```bash
git add App/Source/GLMetalBridge.swift
git commit -m "chore(render): debug log on GLMetalBridge resize"
```

### Task 3.4: Lifecycle audit

**Files:**
- Modify: `App/Views/MPVPlayerView.swift` — `tearDown()`.

**Why:** The bridge owns GL objects + IOSurface + Metal texture. On `tearDown()` (the `viewWillMove(toWindow: nil)` path) we must release the bridge *after* `detachRender()` has freed the mpv render context, otherwise an in-flight render-thread call could touch a freed FBO.

**Step 1: Update `tearDown()`** to release the bridge after the player detaches:

```swift
private func tearDown() {
    if let link = displayLink {
        CVDisplayLinkStop(link)
        displayLink = nil
    }
    if let owned = ownedPlayer {
        owned.detachRender()
        ownedPlayer = nil
    } else {
        sharedPlayer?.detachRender()
        sharedPlayer = nil
    }
    // Release the bridge AFTER the render context is freed; the render context
    // referenced our FBO via the GL callbacks, so order matters.
    bridge = nil
}
```

> **Why this ordering is safe:** the actual mutual-exclusion mechanism is the *blocking* `renderLock.lock()` inside `MPVSourcePlayer.detachRender()` — it waits for any in-flight `renderIntoGL` to release the lock before calling `mpv_render_context_free`. The try-lock in `renderIntoGL` is only a best-effort skip on the render side (so the display-link thread doesn't block on a teardown in flight). `CVDisplayLinkStop` plus the nil-guard on `renderContext` after detach together prevent any new `renderIntoGL` from doing GL work after the context is freed. With `bridge = nil` running last, the `NSOpenGLContext` and `IOSurface` outlive the mpv render context — the reverse would be unsafe because mpv may still hold references to GL objects until `mpv_render_context_free` returns.

**Step 2: Same audit for `updatePlayer(_:)`** (`MPVPlayerView.swift:97-124`):

The current code stops the display link, calls `sharedPlayer?.detachRender()`, then `sharedPlayer = nil`. After the swap, we additionally need to drop the bridge if the player goes nil → non-nil with a different identity (the new player has a fresh render context, but the bridge's GL FBO is reusable across players). Decision: **keep the bridge across player swaps**. The bridge's lifecycle is tied to the *view*, not the *player*. Add an explicit comment:

```swift
// Note: bridge is intentionally retained across updatePlayer swaps — it's
// a view-scoped GPU resource. Only tearDown() (view leaving window) drops it.
```

**Step 3: Build + run XCUITest.**

```bash
xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels
```
Expected: PASS.

**Step 4: Commit.**

```bash
git add App/Views/MPVPlayerView.swift
git commit -m "fix(render): order bridge release after detachRender in tearDown"
```

---

## Phase 4 — Production smoke + first-responder/click regression check

The Phase-3 fix `3ab22aa` ("MPVRenderingNSView accepts first-responder on click") is fragile. The GL path doesn't change view hierarchy or hit-testing, but verify nothing regressed.

### Task 4.1: Production smoke against the fixture

**Step 1: Launch the production app via `./scripts/run.sh`** (auto-load opens the most recent project).

**Step 2: Confirm the source video plays.** Use the JKL keys to scrub. Click the player; click a TextField; click the player again and confirm focus returns (Phase-3 fix). Pause/resume.

**Step 3: Open Activity Monitor; record sustained CPU% for `VideoCoach`** during 60s of playback.

**Step 4: Compare to the Phase-0 baseline.** Expected: noticeable reduction in sustained CPU. Update the "Baseline measurements" section with the post-swap numbers.

**Step 5: Commit the measurements.**

```bash
git add docs/plans/2026-05-01-source-playback-metal-render-swap.md
git commit -m "docs(metal-swap): record post-swap CPU baseline (vs Phase 0)"
```

### Task 4.2: 4K HEVC stress test

**Step 1: Open the user's project pointing at a 4K HEVC source from the fixture set.**

**Step 2: Play continuously for ~5 minutes.** Watch for: dropped frames in mpv stats (if available), thermal throttling (Activity Monitor "Energy Impact"), playback stutter.

**Step 3: Record findings in the doc.** If stutter persists, the next lever is hooking `mpv_render_context_set_update_callback` so we render on demand instead of every display-link tick — stub a Phase 6 task for it.

**Step 4: Commit.**

```bash
git add docs/plans/2026-05-01-source-playback-metal-render-swap.md
git commit -m "docs(metal-swap): record 4K HEVC stress-test results"
```

---

## Phase 5 — Decide on SW path retention

### Task 5.1: Keep, gate, or delete?

**Decision criteria:**
- **Keep both paths gated on `MPVRenderBackend.production`:** zero-risk, ~150 lines of dead code.
- **Delete SW path:** -150 lines, but if the GL path regresses post-merge there's no in-tree fallback — only `git revert`.

**Recommendation:** *keep* both for one release cycle, then delete the SW path in a follow-up commit once the GL path has soaked. The cost is small (the SW `attachRender` and `renderInto` methods on `MPVSourcePlayer`, ~100 lines).

**Step 1: Add a one-line comment above `attachRender()` and `renderInto(...)`** flagging the deprecation.

```swift
// LEGACY: superseded by attachRenderGL/renderIntoGL. Retained as a fallback
// during the soak period. Schedule for removal once the GL path has shipped
// for at least one release without regressions.
```

**Step 2: Commit.**

```bash
git add App/Source/MPVSourcePlayer.swift
git commit -m "chore(render): mark SW render path as legacy (kept as fallback)"
```

### Task 5.2: Open a `/schedule` follow-up to delete the SW path in 2 weeks

This is an orchestrator step, not an executable subtask. After landing the swap, propose a `/schedule` agent that runs in 2 weeks and either opens a cleanup PR (if no GL-path regressions filed) or no-ops with a status note.

---

## Phase 6 — Optional: hook `mpv_render_context_set_update_callback`

If Phase 4.2 stress test shows CPU is *still* elevated, we're rendering at display refresh regardless of whether mpv has a new frame ready. Wire the update callback to render only when mpv signals an update.

Defer this until Phase 4 measurements indicate it's needed. If it isn't, drop Phase 6 entirely.

### Task 6.1: Add update callback (only if needed)

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`
- Modify: `App/Views/MPVPlayerView.swift`

**Step 1:** Have `MPVSourcePlayer` expose a `setUpdateCallback(_ cb:)` method that wraps `mpv_render_context_set_update_callback`.

**Step 2:** Have `MPVRenderingNSView` register a callback that posts to the CVDisplayLink-driven render loop a "frame pending" flag, and only call `renderIntoGL` when the flag is set.

**Step 3:** Re-run Phase 4.2; record CPU delta.

(Sketched at this depth on purpose — concrete steps land in v2 if Phase 4 demands it.)

---

## Baseline measurements

(filled in during Phase 0 and Phase 4)

| Build | Avg CPU% (60s) | Dropped frames (60s) | Resident memory |
|---|---|---|---|
| `main` (SW path) | _TBD Phase 0_ | _TBD_ | _TBD_ |
| `feat/source-playback-gl-render` (GL+IOSurface→Metal) | _TBD Phase 4_ | _TBD_ | _TBD_ |

---

## Things this plan does NOT cover (out of scope, intentional)

- **HDR / target-colorspace-hint:** the existing `target-colorspace-hint=yes` mpv option stays. With the GL render API, mpv renders into our FBO with whatever colorspace it negotiates; the IOSurface and Metal texture are both BGRA8Unorm. HDR fidelity matches the SW path's BGRA8 path (i.e. lost). Out of scope for this plan; revisit only if a user-visible HDR issue is filed.
- **Tone mapping / ICC profile:** same.
- **Subtitle/OSD rendering:** mpv handles internally; rendered into our FBO same as video.
- **Multiple monitor different refresh rates:** the CVDisplayLink is created via `CVDisplayLinkCreateWithActiveCGDisplays`, same as today. No change.
- **Fullscreen entry/exit during playback:** uses the same `setFrameSize`/`viewDidChangeBackingProperties` overrides; bridge resizes itself.
- **GPU device loss / external GPU disconnect:** Metal device validation already handles `nextDrawable() == nil`. The bridge handles `IOSurface` failures by skipping the frame.
- **Sandboxed builds:** the app is non-sandboxed under hardened runtime per the migration plan's D14. GL + IOSurface require no additional entitlements beyond what's already in `App/VideoCoach.entitlements`.

---

## Execution handoff

Two execution options after the adversarial review pass folds findings into v2:

**1. Subagent-Driven (this session)** — orchestrator dispatches a fresh subagent per task with code review between tasks.

**2. Parallel Session (separate)** — open a new session in a worktree off `feat/impl-phases-1-4-9` and use `superpowers:executing-plans`.

Pick after v2 lands.
