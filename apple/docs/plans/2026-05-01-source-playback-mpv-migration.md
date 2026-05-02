# Source-Playback Decoder Swap: AVPlayer → libmpv (MPVKit) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `Workspace.virtualPlayer` (`AVPlayer` over `AVMutableComposition`) with `Workspace.sourcePlayer` (`MPVSourcePlayer` over a persistent `mpv_handle`) for source-playback only, so 4K Android-camera HEVC files that AVFoundation mishandles play smoothly. Keep AVPlayer for clip-preview and export.

**Architecture:** App-side `MPVSourcePlayer` class wraps a persistent `mpv_handle` driven by playlist commands. mpv's `time-pos` is per-file, but `Workspace.sourceTime(at:)` already maps cumulative seconds → (sourceIndex, sourceLocalSeconds), so the source-mode skip path stays in *cumulative* seconds when talking to `SkipCoordinator` and translates back to per-file at the moment of issuing the seek. `MPVSourcePlayer.seek(playlistPos:timeSeconds:exact:completion:)` chooses between an in-file `seek` command and a cross-boundary atomic `loadfile <path> replace 0 start=<t>`. Seek-completion is `MPV_EVENT_PLAYBACK_RESTART` gated by a single-slot pending-seek tracker keyed on `mpv_command_async` reply IDs (so cross-file auto-advance restarts don't fire spurious completions). A playlist-generation counter on `MPVSourcePlayer` replaces the AVPlayer `ObjectIdentifier` stale-completion guard for *both* source and preview paths. A small `driveSkipDecision` control-flow helper hosts the debounce + late-completion + recursion logic that both paths share.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, AVFoundation (preview + export), MPVKit (source playback), CoreImage, CoreVideo, XCTest, SwiftPM.

**Companion design document:** `docs/plans/2026-05-01-source-playback-mpv-migration-design.md` — read this first for the *why* behind every decision (D1–D15) and the rejected alternatives. This plan covers the *what* and *how*.

**Test commands:**
- `cd VideoCoachCore && swift test` — Phase 2 unit tests + existing suites
- `./scripts/run.sh` — manual smoke for Phases 1, 4, 5

---

## Adversarial review history (implementation plan v1 → v2)

The first draft of this plan was reviewed by `feature-dev:code-reviewer` and `superpowers:code-reviewer` in parallel. Findings folded into v2 (this document) before any execution:

| Finding | Where it lives now |
|---------|-------------------|
| Cross-boundary FF/RW silently broken: `SkipCoordinator.requestSkip` clamped to current-file duration *before* the playlist-walking resolver could see the target. | Phase 4 — source-mode `handleSkip` operates in **cumulative** seconds against `SkipCoordinator`, then translates back to per-file via `Workspace.sourceTime(at:)`. `PlaylistSkipResolver` is no longer needed and is **deleted from the plan**. |
| `pendingSeeks.max(by:)` heuristic for matching `PLAYBACK_RESTART` to seeks was FIFO-incorrect (burst seeks paired completions to wrong reply IDs) and also fired on auto-advance restarts unrelated to app seeks. | Phase 3 Task 3.7 — single-slot `pendingSeek` tracker. `MPV_EVENT_COMMAND_REPLY` confirms the seek command was issued; `MPV_EVENT_PLAYBACK_RESTART` only fires the completion when a slot is occupied (auto-advance restarts find an empty slot and are ignored). |
| `mpv_command_async` C-string lifetime: `defer { free }` could run before mpv copied argv. | Phase 3 Task 3.6 — pending seek owns the `[UnsafeMutablePointer<CChar>?]` until `MPV_EVENT_COMMAND_REPLY` fires. |
| `readPlaylistDurations` blocked the main actor with synchronous `mpv_get_property` per playlist entry, every keypress. | Removed entirely. Source-mode `handleSkip` reads durations from `Workspace.project.sourceVideos[i].durationSeconds` (already authoritative). |
| Phase 4/5 broke subagent-driven-development: 8+ tasks left the tree non-compileable. | Phase 4 is now a single atomic migration task with sub-steps. The intermediate state isn't compileable on a *partial* execution, but the task either fully completes or rolls back; review runs once on the post-task diff. |
| Per-frame `MTLCreateSystemDefaultDevice()` and `makeCommandQueue()` allocations would spike CPU. | Phase 1 / Phase 3 — device + command queue cached on `MPVRenderingNSView` at init. |
| Task 1.3 Step 4 had three contradictory `VideoCoachApp.swift` candidates that would confuse a fresh subagent. | Phase 1 Task 1.3 Step 4 — single surgical-diff instruction (read first, then add three named additions). |
| `msg-level=all=warn` suppressed Phase 1 gate (e)'s target log line ("Using video decoder: hevc" is info-level). | Phase 1 — bring-up uses `msg-level=all=warn,vd=info`. Production `MPVSourcePlayer` keeps `all=warn`. |
| Same-file fast path bypassed D9 end-clamp epsilon when `t == duration` exactly. | Source-mode `handleSkip` clamps cumulative target to `[0, totalSourceDuration - 0.05]` before translating to per-file. |
| `bringUp(hwdec:)` parameter silently ignored after Phase 3 refactor. | Phase 1 gate (a) explicitly runs *before* Task 3.5; Task 3.5's commit message records that the picker is now decorative. |
| `setPlaylist` bumped generation *after* clearing playlist (window for stale completions). | Phase 3 Task 3.4 — bump first. |
| `coarseSeekInFlight = false` ran before generation guard. | Phase 4 — preview-branch closure clears `coarseSeekInFlight` only after `currentSkipGeneration()` matches. |
| Phase 6 spawned reviewer subagents from inside an executing subagent. | Phase 5 (renumbered) is marked **orchestrator-only**: do not execute as a normal task. |
| `URL.path` deprecated on macOS 14. | Phase 4 — `url.path(percentEncoded: false)`. |
| `pumpShouldStop` flag declared but never read. | Removed. |
| Phase 1 gate (d) "edit then revert" invited accidental commits. | Phase 1 — overlay test is a permanent toggle in the debug picker. |
| Phase 1 gate (a) measured "smoothness" subjectively; could pass on a path with hidden CPU cost. | Phase 1 — gate (a) adds a CPU + dropped-frame threshold; if SW barely passes, Phase 3 swaps to Metal advanced control immediately. |
| Debug-window `MPVSourcePlayer` would fight production for CoreAudio output. | Phase 3 Task 3.4 — debug-window instances pass `ao=null`. |
| `KeyCommandView` had a dead `player` parameter; plan didn't audit other references. | Phase 4 — explicit `grep` step before deleting. |

---

## Phase 1 — Bring-up + de-risk gate

This phase is the load-bearing gate for the entire swap. **If any of the gate checks fail, stop and re-plan rather than proceeding.**

### Task 1.1: Add MPVKit SwiftPM dependency

**Files:**
- Modify: `project.yml`

**Step 1: Read the current `project.yml`** to understand the existing structure:

```bash
cat project.yml
```

**Step 2: Modify `project.yml`** to add MPVKit as a top-level package and depend on it from the App target.

In the `packages:` block, add:
```yaml
  MPVKit:
    url: https://github.com/mpvkit/MPVKit
    from: 0.39.0
```

> **Note on the version pin:** if `swift package resolve` fails to find a 0.39+ tag, fall back to `from: 0.38.0`. Record the resolved version in the commit message.

In the App target's `dependencies:` block, add:
```yaml
      - package: MPVKit
        product: MPVKit
```

Don't replace anything else.

**Step 3: Regenerate the Xcode project and resolve packages.**
```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project VideoCoach.xcodeproj
```
Expected: clean resolution; the resolved version of MPVKit appears in `Package.resolved` under the project's xcshareddata.

**Step 4: Build to confirm the link.**
```bash
./scripts/run.sh
```
Expected: app builds and launches with no behavior change yet (no MPVKit symbols are imported anywhere). If the build fails with a missing symbol, diagnose before continuing.

**Step 5: Commit.**
```bash
git add project.yml VideoCoach.xcodeproj
git commit -m "build(source-playback): add MPVKit SwiftPM dependency

Resolved version: <X.Y.Z>"
```

---

### Task 1.2: Add `disable-library-validation` entitlement

**Why:** MPVKit ships an XCFramework with bundled libmpv + FFmpeg dylibs signed by the upstream team's identity. Hardened-runtime library validation refuses to load them otherwise. Without this entitlement the app fails at launch as soon as MPVKit symbols are referenced. (D14 in design.)

**Files:**
- Modify: `App/VideoCoach.entitlements`

**Step 1: Edit `App/VideoCoach.entitlements`** to add the new key:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

**Step 2: Rebuild and confirm app still launches.**
```bash
./scripts/run.sh
```
Expected: app launches; no behavior change yet.

**Step 3: Commit.**
```bash
git add App/VideoCoach.entitlements
git commit -m "build(source-playback): allow library validation to be disabled for MPVKit"
```

---

### Task 1.3: Standalone `MPVPlayerView` for the bring-up gate

**Goal:** Build the smallest possible NSView + `mpv_render_context` integration that loads a hardcoded path and renders. This lands as real code in `App/Views/MPVPlayerView.swift` with a private bring-up path that Phase 3 then refactors to delegate to `MPVSourcePlayer`.

**Files:**
- Create: `App/Views/MPVPlayerView.swift`
- Create: `App/Views/MPVDebugWindow.swift`
- Modify: `App/VideoCoachApp.swift`

**Step 1: Identify MPVKit's Swift module name.**

```bash
xcodebuild -resolvePackageDependencies -project VideoCoach.xcodeproj
find ~/Library/Developer/Xcode/DerivedData -path "*MPVKit*" -name "*.modulemap" 2>/dev/null | head -5
find ~/Library/Developer/Xcode/DerivedData -path "*MPVKit*" -name "*.h" 2>/dev/null | head -10
```

The Swift `import` is whatever module name the package's modulemap declares. Try `import MPVKit` first; if the build fails with "no such module," try `import Libmpv` or whatever the modulemap names the umbrella module. **Record the actual import in the commit message.**

> Throughout this plan, every `import MPVKit` may need to be substituted for the real module name discovered in this step.

**Step 2: Create `App/Views/MPVPlayerView.swift`.**

```swift
import SwiftUI
import AppKit
import Metal
import QuartzCore
import MPVKit  // adjust to actual module name from Step 1

/// NSView that hosts a CAMetalLayer and drives an mpv render context.
/// Phase 1 bring-up creates a private mpv_handle inside this view; Phase
/// 3 refactors `attach(player:)` to delegate to a shared MPVSourcePlayer.
final class MPVRenderingNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Phase-1-private handle. Phase 3.5 replaces with shared MPVSourcePlayer.
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var displayLink: CVDisplayLink?
    private let renderLock = NSLock()

    override init(frame: NSRect) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        self.device = dev
        self.commandQueue = q
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Phase 1 bring-up entry point.
    func bringUp(filePath: String, hwdec: String, audioOff: Bool = false) throws {
        let h = mpv_create()
        guard let h else { throw NSError(domain: "MPV", code: -1) }

        for (k, v) in [
            ("vo", "libmpv"),
            ("hwdec", hwdec),
            ("prefetch-playlist", "yes"),
            ("keep-open", "yes"),
            ("keep-open-pause", "no"),
            ("pause", "no"),
            // Phase 1 only: vd=info lets the "Using video decoder: hevc"
            // log line through for gate (e). MPVSourcePlayer (Phase 3)
            // pins all=warn for production.
            ("msg-level", "all=warn,vd=info"),
            ("audio-display", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("target-colorspace-hint", "yes"),
            ("volume-correct", "no"),
        ] {
            mpv_set_option_string(h, k, v)
        }
        if audioOff {
            // For the debug window — avoid fighting CoreAudio with the
            // production source player when both are open simultaneously.
            mpv_set_option_string(h, "ao", "null")
        }

        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_destroy(h)
            throw NSError(domain: "MPV", code: Int(rc))
        }
        self.mpv = h
        try attachRenderContext()

        // Single loadfile — bring-up plays one file.
        runCommand(handle: h, args: ["loadfile", filePath, "replace"])
    }

    private func attachRenderContext() throws {
        renderLock.lock(); defer { renderLock.unlock() }
        guard let mpv else { return }
        var apiType = MPV_RENDER_API_TYPE_SW
        var advancedControl: Int32 = 1
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                             data: withUnsafeMutableBytes(of: &apiType) { $0.baseAddress }),
            mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                             data: withUnsafeMutableBytes(of: &advancedControl) { $0.baseAddress }),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var ctx: OpaquePointer?
        let rc = params.withUnsafeMutableBufferPointer {
            mpv_render_context_create(&ctx, mpv, $0.baseAddress)
        }
        guard rc >= 0, let ctx else { throw NSError(domain: "MPVRender", code: Int(rc)) }
        self.renderContext = ctx

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.renderTick()
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    private func renderTick() {
        // Try-lock so a teardown can pre-empt cleanly.
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        guard let renderContext else { return }

        let drawableSize = metalLayer.drawableSize
        let w = Int32(drawableSize.width)
        let h = Int32(drawableSize.height)
        guard w > 0, h > 0 else { return }

        let bytesPerRow = Int(w) * 4
        let bufferSize = bytesPerRow * Int(h)
        let pixelBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { pixelBuffer.deallocate() }

        var size: [Int32] = [w, h]
        var stride = Int(bytesPerRow)
        var format = "0bgr".utf8CString

        format.withUnsafeMutableBufferPointer { fmtBuf in
            size.withUnsafeMutableBufferPointer { sizeBuf in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                     data: UnsafeMutableRawPointer(sizeBuf.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                     data: UnsafeMutableRawPointer(fmtBuf.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                     data: &stride),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                     data: pixelBuffer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = params.withUnsafeMutableBufferPointer {
                    mpv_render_context_render(renderContext, $0.baseAddress)
                }
            }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }
        drawable.texture.replace(
            region: MTLRegionMake2D(0, 0, Int(w), Int(h)),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )
        if let cmdBuf = commandQueue.makeCommandBuffer() {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDown() }
    }

    private func tearDown() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        renderLock.lock()
        if let ctx = renderContext {
            mpv_render_context_free(ctx)
            renderContext = nil
        }
        renderLock.unlock()
        if let h = mpv {
            mpv_terminate_destroy(h)
            mpv = nil
        }
    }

    deinit { tearDown() }
}

// Top-of-file helper that callers (bringUp, MPVSourcePlayer.runCommand)
// share. Deliberately not a method on the class because it's also useful
// to MPVSourcePlayer in Phase 3.
fileprivate func runCommand(handle: OpaquePointer, args: [String]) {
    var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { cstrings.forEach { if let p = $0 { free(p) } } }
    cstrings.withUnsafeMutableBufferPointer { buf in
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command(handle, p)
    }
}

/// SwiftUI bridge for the bring-up window.
struct MPVDebugRepresentable: NSViewRepresentable {
    let filePath: String
    let hwdec: String
    let overlayTint: Bool   // gate (d) — permanent toggle, not edit-and-revert
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec, audioOff: true) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}
```

**Step 3: Create `App/Views/MPVDebugWindow.swift`.**

```swift
import SwiftUI

/// Phase 1 / D6 gate. Standalone window that loads the test file through
/// the new mpv pipeline. The hwdec picker drives gate (a); the overlay
/// toggle drives gate (d). Both are permanent debug affordances.
struct MPVDebugWindow: View {
    @State private var hwdec: String = "videotoolbox"
    @State private var filePath: String =
        "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4"
    @State private var overlayTint: Bool = false
    @State private var revision: Int = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("File path", text: $filePath)
                Picker("hwdec", selection: $hwdec) {
                    Text("videotoolbox").tag("videotoolbox")
                    Text("no").tag("no")
                    Text("auto-safe").tag("auto-safe")
                }
                .pickerStyle(.menu)
                Toggle("Overlay tint", isOn: $overlayTint)
                Button("Reload") { revision &+= 1 }
            }
            .padding(.horizontal, 8).padding(.top, 8)

            ZStack {
                MPVDebugRepresentable(filePath: filePath, hwdec: hwdec, overlayTint: overlayTint)
                    .id(revision)   // recreate the NSView (and mpv handle) on Reload
                if overlayTint {
                    Color.red.opacity(0.3).allowsHitTesting(false)
                    Text("Overlay test")
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(6)
                }
            }
            .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}
```

**Step 4: Add the Debug menu and second WindowGroup to `App/VideoCoachApp.swift`.**

```bash
cat App/VideoCoachApp.swift
```

The file currently has one `WindowGroup` and a `.commands` block. **Make exactly three additions**, without deleting or replacing existing content:

1. Inside the existing `.commands {}` block, add `DebugMenu()` after the existing entries.
2. Below the existing `WindowGroup`, add a second one for the bring-up window:
   ```swift
   WindowGroup("MPV Bring-up", id: "mpv-debug") {
       MPVDebugWindow()
   }
   ```
3. At file scope (below `struct VideoCoachApp`), add:
   ```swift
   struct DebugMenu: Commands {
       @Environment(\.openWindow) private var openWindow
       var body: some Commands {
           CommandMenu("Debug") {
               Button("Open MPV Bring-up Window") {
                   openWindow(id: "mpv-debug")
               }
           }
       }
   }
   ```

Verify the result builds.

**Step 5: Build and launch.**
```bash
./scripts/run.sh
```
Expected: app launches with no behavior regression.

**Step 6: Open the bring-up window.** Debug menu → Open MPV Bring-up Window. The window appears with `hwdec=videotoolbox` selected. The video should start rendering and playing.

**Step 7: Run the gate checklist (D6 + Phase 1 gate).** Record pass/fail for each.

- **(a) Decoder gate.** Test file plays with `hwdec=videotoolbox` for 60+ seconds. Open Activity Monitor → the app's CPU should stay under ~120% (one P-core saturated max) on a base M-series Mac with no thermal-throttling fan ramp. Watch Console.app filtered by your app — no `[ffmpeg]` errors, no `dropped frames` reports. If FAIL, switch the picker to `hwdec=no`, click Reload, repeat. **Pass condition:** at least one value plays smoothly under the CPU threshold. **Record the working value** — it goes into Task 3.1's `MPVSourcePlayer.init`.
- **(b) Hardened-runtime + library validation.** App launched cleanly (no dyld errors). PASS implicit if you got here.
- **(c) Render-context lifecycle.** With the file playing, click Reload 3× in succession. Player must continue playing without leaks, crashes, or render-context errors after each cycle. (mpv's "render context still in use" or "couldn't free render" warnings would appear in Console.)
- **(d) SwiftUI overlay composition.** Click the "Overlay tint" toggle. Verify the red tint composites correctly over the player surface, and the "Overlay test" label is readable. Click off.
- **(e) HEVC decoder presence.** Watch Console.app filtered by your app. Within the first second of playback, mpv emits `Using video decoder: hevc` (or similar) at info level. (Phase 1 sets `msg-level=all=warn,vd=info` specifically to let this through.) If a `Failed to recognize file format` or `No video decoder found` message appears instead, MPVKit's bundled libavcodec is missing HEVC and the swap is invalidated.
- **(f) EOF behavior.** Click Reload to restart the file. Wait for playback to reach the end. Verify mpv parks on the last frame instead of going black or auto-closing.

**Step 8: If all six pass — commit and proceed.** Record the chosen `hwdec` in the commit message.

```bash
git add App/Views/MPVPlayerView.swift App/Views/MPVDebugWindow.swift App/VideoCoachApp.swift
git commit -m "feat(source-playback): Phase 1 mpv bring-up window + decoder gate

Phase 1 gate results:
- (a) decoder: hwdec=<videotoolbox|no> plays the test file smoothly,
      CPU stayed under ~120% sustained, no fan ramp.
- (b) hardened-runtime: app launches cleanly with MPVKit linked.
- (c) lifecycle: 3x Reload cycles, no leaks.
- (d) overlay: SwiftUI composites correctly over Metal-hosted player.
- (e) HEVC: libavcodec hevc decoder present.
- (f) EOF: parks on last frame as expected.

MPVKit module imported as: <MPVKit|Libmpv>
Resolved version: <X.Y.Z>"
```

**Step 9: If any gate item fails — STOP. Do not proceed to Phase 2.** Re-plan.

---

## Phase 2 — `Workspace` cumulative-time helpers

`Workspace.sourceTime(at:)` already maps cumulative seconds → (sourceIndex, sourceLocalSeconds). Source-mode `handleSkip` needs the inverse direction (sourceIndex → cumulative offset) and the total. Both are trivial; we test them so the source-mode skip logic has a known-good foundation.

### Task 2.1: Add `cumulativeOffset(forSourceIndex:)` and `totalSourceDuration` + tests

**Files:**
- Modify: `App/Models/Workspace.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/WorkspaceCumulativeTests.swift`

> The helpers are added on `Workspace` (an App-level type), but the tests live in `VideoCoachCore` because that's where existing test infrastructure runs. The test imports `Workspace` indirectly: actually it can't — `Workspace` is in App, `VideoCoachCore` is below it. **Plan correction:** put the helpers as static methods on `Project` (which IS in `VideoCoachCore`), since they only read `project.sourceVideos`. `Workspace.sourceTime(at:)` becomes a thin wrapper.

**Step 1: First confirm where `Project` lives** and whether `sourceTime(at:)` could move:

```bash
grep -rn "struct Project\|public struct Project" VideoCoachCore App | head
grep -rn "func sourceTime" App | head
```

Expected: `Project` lives in `VideoCoachCore`; `sourceTime(at:)` is on `Workspace` (App). Plan: add the new helpers as `Project` methods alongside, then have `Workspace.sourceTime(at:)` (and the new source-mode skip code in Phase 4) call them.

**Step 2: Write the failing tests.**

```swift
// VideoCoachCore/Tests/VideoCoachCoreTests/WorkspaceCumulativeTests.swift
import XCTest
@testable import VideoCoachCore

final class ProjectCumulativeTests: XCTestCase {
    private func project(durations: [Double]) -> Project {
        var p = Project(name: "test")
        p.sourceVideos = durations.map { d in
            SourceRef(bookmark: Data(), displayName: "x", durationSeconds: d)
        }
        return p
    }

    func test_totalSourceDuration_emptyIsZero() {
        XCTAssertEqual(project(durations: []).totalSourceDuration, 0)
    }
    func test_totalSourceDuration_sumsDurations() {
        XCTAssertEqual(project(durations: [120, 90, 60]).totalSourceDuration, 270)
    }
    func test_cumulativeOffsetForFirstSourceIsZero() {
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: 0), 0)
    }
    func test_cumulativeOffsetForLaterSourceIsSumOfPrior() {
        XCTAssertEqual(project(durations: [120, 90, 60]).cumulativeOffset(forSourceIndex: 2), 210)
    }
    func test_cumulativeOffsetClampsOutOfRange() {
        // Pos > last clamps to total. Pos < 0 clamps to 0.
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: 99), 210)
        XCTAssertEqual(project(durations: [120, 90]).cumulativeOffset(forSourceIndex: -1), 0)
    }
    func test_cumulativeOffsetEmptyProjectIsZero() {
        XCTAssertEqual(project(durations: []).cumulativeOffset(forSourceIndex: 0), 0)
    }
}
```

**Step 3: Run, expect failure** (`Project` doesn't have these methods yet).
```bash
cd VideoCoachCore && swift test --filter ProjectCumulativeTests
```

**Step 4: Implement on `Project`.**

Locate `Project`'s definition (`grep -n "struct Project" VideoCoachCore/Sources/VideoCoachCore/*.swift`) and add an extension at the bottom of the same file:

```swift
public extension Project {
    /// Sum of all sourceVideos' durations.
    var totalSourceDuration: Double {
        sourceVideos.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Cumulative offset of the source at `forSourceIndex` within the
    /// virtual concat. Equal to `sum(durations[0..<i])` clamped to
    /// `[0, totalSourceDuration]`.
    func cumulativeOffset(forSourceIndex i: Int) -> Double {
        if sourceVideos.isEmpty { return 0 }
        let clamped = max(0, min(i, sourceVideos.count))
        var sum: Double = 0
        for k in 0..<clamped { sum += sourceVideos[k].durationSeconds }
        return sum
    }
}
```

**Step 5: Run, expect pass.**

**Step 6: Commit.**
```bash
git add VideoCoachCore/Sources/VideoCoachCore VideoCoachCore/Tests/VideoCoachCoreTests/WorkspaceCumulativeTests.swift
git commit -m "feat(core): Project cumulative-time helpers for source-mode skip math"
```

---

## Phase 3 — `MPVSourcePlayer` core class

### Task 3.1: Skeleton + init/deinit

**Files:**
- Create: `App/Source/MPVSourcePlayer.swift`

**Step 1: Create the file.**

```swift
import Foundation
import Observation
import QuartzCore
import MPVKit  // adjust if module name differs

/// Wraps a persistent mpv_handle for source-playback (D2 in the design).
/// One instance per Workspace; setPlaylist() reuses it across rebuilds.
@MainActor
@Observable
public final class MPVSourcePlayer {
    /// hwdec value chosen during Phase 1's gate. Recorded here as the
    /// source of truth; if Phase 1 picked "no", change this constant.
    private static let hwdecOption = "videotoolbox"   // Phase-1-decided

    fileprivate let handle: OpaquePointer
    fileprivate var renderContext: OpaquePointer?
    fileprivate let renderLock = NSLock()

    /// Cached playlist paths in the order setPlaylist received them.
    /// Used by seek() to avoid mpv_get_property("playlist/<i>/filename")
    /// from the main actor.
    fileprivate var playlistPaths: [String] = []

    // Observed state — all updated from the event pump (Task 3.3).
    public private(set) var isPaused: Bool = true
    public private(set) var playlistCount: Int = 0
    public private(set) var playlistPos: Int = 0
    public private(set) var timePos: Double = 0
    public private(set) var generation: UInt64 = 0

    // Single-slot pending-seek tracking (Task 3.7).
    fileprivate struct PendingSeek {
        let replyID: UInt64
        let generation: UInt64
        let completion: @MainActor () -> Void
        /// Holds the strdup'd argv alive past mpv_command_async's return,
        /// freed on MPV_EVENT_COMMAND_REPLY (Task 3.7).
        var cstrings: [UnsafeMutablePointer<CChar>?]
        var commandReplied: Bool
    }
    fileprivate var pending: PendingSeek?
    fileprivate var nextReplyID: UInt64 = 100

    public init() throws {
        guard let h = mpv_create() else { throw MPVSourcePlayerError.createFailed }
        for (k, v) in [
            ("vo", "libmpv"),
            ("hwdec", Self.hwdecOption),
            ("prefetch-playlist", "yes"),
            ("keep-open", "yes"),
            ("keep-open-pause", "no"),
            ("pause", "yes"),
            ("msg-level", "all=warn"),
            ("audio-display", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("target-colorspace-hint", "yes"),
            ("volume-correct", "no"),
        ] {
            mpv_set_option_string(h, k, v)
        }
        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            mpv_destroy(h)
            throw MPVSourcePlayerError.initializeFailed(code: Int(rc))
        }
        self.handle = h
    }

    deinit {
        // mpv_terminate_destroy makes mpv_wait_event return MPV_EVENT_SHUTDOWN
        // which the pump (Task 3.2) uses to exit its loop. The render context
        // is freed by detachRender (called from MPVPlayerView's tearDown).
        mpv_terminate_destroy(handle)
    }

    public func bumpGeneration() {
        generation &+= 1
        // Drop any pending completion that hasn't fired — the bump means
        // we're transitioning to a state where the completion is no
        // longer meaningful.
        pending = nil
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
    case alreadyAttached
    case renderContextFailed(code: Int)
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: clean build. (Class isn't instantiated yet.)

**Step 3: Commit.**
```bash
git add App/Source/MPVSourcePlayer.swift
git commit -m "feat(source-playback): MPVSourcePlayer skeleton"
```

---

### Task 3.2: Event-pump thread

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add a stored `Thread`** on the class:
```swift
private var pumpThread: Thread?
```

**Step 2: Start the pump in `init`** (after `mpv_initialize` succeeds, before returning):
```swift
self.handle = h
let pump = Thread { [handle = h] in
    while true {
        guard let evt = mpv_wait_event(handle, 0.1) else { continue }
        let id = evt.pointee.event_id
        if id == MPV_EVENT_NONE { continue }
        if id == MPV_EVENT_SHUTDOWN { return }
        // Property + command-reply + playback-restart handlers added in 3.3 / 3.7.
    }
}
pump.name = "mpv-event-pump"
pump.start()
self.pumpThread = pump
```

**Step 3: Build.**
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer event-pump thread"
```

---

### Task 3.3: Property observation

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Subscribe** in `init` (after `mpv_initialize`, before starting the pump):
```swift
mpv_observe_property(h, 1, "pause",          MPV_FORMAT_FLAG)
mpv_observe_property(h, 2, "playlist-count", MPV_FORMAT_INT64)
mpv_observe_property(h, 3, "playlist-pos",   MPV_FORMAT_INT64)
mpv_observe_property(h, 4, "time-pos",       MPV_FORMAT_DOUBLE)
```

**Step 2: Handle property events in the pump.** Replace the placeholder with:
```swift
if id == MPV_EVENT_PROPERTY_CHANGE {
    let prop = UnsafeMutableRawPointer(evt.pointee.data)?
        .assumingMemoryBound(to: mpv_event_property.self).pointee
    let userdata = evt.pointee.reply_userdata
    Task { @MainActor [weak self] in
        guard let self else { return }
        switch userdata {
        case 1:
            if let data = prop?.data {
                self.isPaused = data.assumingMemoryBound(to: Int32.self).pointee != 0
            }
        case 2:
            if let data = prop?.data {
                self.playlistCount = Int(data.assumingMemoryBound(to: Int64.self).pointee)
            }
        case 3:
            if let data = prop?.data {
                self.playlistPos = Int(max(0, data.assumingMemoryBound(to: Int64.self).pointee))
            }
        case 4:
            if let data = prop?.data {
                let v = data.assumingMemoryBound(to: Double.self).pointee
                if v.isFinite { self.timePos = v }
            }
        default: break
        }
    }
    continue
}
```

> `mpv_event_property.data` can be nil when a property becomes unset (e.g., `time-pos` after `loadfile` before the first frame). The `if let data` guards keep the cached field at its last known good value across this transition.

**Step 3: Build.**
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): cache mpv property events as @Observable state"
```

---

### Task 3.4: `setPlaylist` + play/pause/togglePlay/setVolume

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add the public methods.**

```swift
public func setPlaylist(_ paths: [String]) {
    // Bump generation FIRST so any in-flight pending seek's completion
    // is dropped before we issue the playlist-clear (which itself can
    // generate a PLAYBACK_RESTART that we don't want fired). See
    // adversarial review history in plan front-matter.
    bumpGeneration()
    playlistPaths = paths
    runCommandSync(["playlist-clear"])
    for p in paths {
        runCommandSync(["loadfile", p, "append"])
    }
}

public func play() {
    var flag: Int32 = 0
    mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
}

public func pause() {
    var flag: Int32 = 1
    mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
}

public func togglePlay() {
    if isPaused { play() } else { pause() }
}

public func setVolume(_ v: Double) {
    var mpvVolume = max(0, min(100, v * 100))
    mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &mpvVolume)
}

private func runCommandSync(_ args: [String]) {
    var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { cstrings.forEach { if let p = $0 { free(p) } } }
    cstrings.withUnsafeMutableBufferPointer { buf in
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command(handle, p)
    }
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer playlist + play/pause/volume"
```

---

### Task 3.5: Render-context attach/detach

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`
- Modify: `App/Views/MPVPlayerView.swift`

**Step 1: Move render-context lifecycle out of `MPVRenderingNSView`'s private path** and into `MPVSourcePlayer` so the production `MPVPlayerView(player:)` path can attach/detach against a shared player.

In `MPVSourcePlayer`, add:

```swift
public func attachRender() throws {
    renderLock.lock(); defer { renderLock.unlock() }
    guard renderContext == nil else { throw MPVSourcePlayerError.alreadyAttached }
    var apiType = MPV_RENDER_API_TYPE_SW
    var advancedControl: Int32 = 1
    var params = [
        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                         data: withUnsafeMutableBytes(of: &apiType) { $0.baseAddress }),
        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                         data: withUnsafeMutableBytes(of: &advancedControl) { $0.baseAddress }),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]
    var ctx: OpaquePointer?
    let rc = params.withUnsafeMutableBufferPointer {
        mpv_render_context_create(&ctx, handle, $0.baseAddress)
    }
    guard rc >= 0, let ctx else { throw MPVSourcePlayerError.renderContextFailed(code: Int(rc)) }
    self.renderContext = ctx
}

public func detachRender() {
    renderLock.lock(); defer { renderLock.unlock() }
    if let ctx = renderContext {
        mpv_render_context_free(ctx)
        renderContext = nil
    }
}

/// Called by MPVPlayerView's CADisplayLink. Try-locks to avoid blocking
/// the display-link thread on a teardown in flight; nil renderContext
/// means a teardown happened, so we skip this frame.
public func renderInto(layer: CAMetalLayer, drawableSize: CGSize, commandQueue: MTLCommandQueue) {
    guard renderLock.try() else { return }
    defer { renderLock.unlock() }
    guard let renderContext else { return }

    let w = Int32(drawableSize.width)
    let h = Int32(drawableSize.height)
    guard w > 0, h > 0 else { return }

    let bytesPerRow = Int(w) * 4
    let bufferSize = bytesPerRow * Int(h)
    let pixelBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    defer { pixelBuffer.deallocate() }

    var size: [Int32] = [w, h]
    var stride = Int(bytesPerRow)
    var format = "0bgr".utf8CString

    format.withUnsafeMutableBufferPointer { fmtBuf in
        size.withUnsafeMutableBufferPointer { sizeBuf in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                 data: UnsafeMutableRawPointer(sizeBuf.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                 data: UnsafeMutableRawPointer(fmtBuf.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                 data: &stride),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                 data: pixelBuffer),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            _ = params.withUnsafeMutableBufferPointer {
                mpv_render_context_render(renderContext, $0.baseAddress)
            }
        }
    }

    guard let drawable = layer.nextDrawable() else { return }
    drawable.texture.replace(
        region: MTLRegionMake2D(0, 0, Int(w), Int(h)),
        mipmapLevel: 0,
        withBytes: pixelBuffer,
        bytesPerRow: bytesPerRow
    )
    if let cmdBuf = commandQueue.makeCommandBuffer() {
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
```

**Step 2: Refactor `App/Views/MPVPlayerView.swift`.** Replace the file with:

```swift
import SwiftUI
import AppKit
import Metal
import QuartzCore
import MPVKit

/// NSView that renders an MPVSourcePlayer's output into a CAMetalLayer.
final class MPVRenderingNSView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Phase-1 path owns its player; production path takes a shared one.
    private var ownedPlayer: MPVSourcePlayer?
    private weak var sharedPlayer: MPVSourcePlayer?
    private var player: MPVSourcePlayer? { ownedPlayer ?? sharedPlayer }
    private var displayLink: CVDisplayLink?

    override init(frame: NSRect) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        self.device = dev
        self.commandQueue = q
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Phase 1 bring-up entry — owns its own MPVSourcePlayer with audio off
    /// and a single-file playlist. The hwdec parameter is recorded here for
    /// historical reasons (Phase 1 gate (a)); MPVSourcePlayer hardcodes the
    /// chosen value at compile time after Phase 1 ships.
    func bringUp(filePath: String, hwdec: String) throws {
        NSLog("[MPV-debug] bringUp hwdec=\(hwdec) (note: MPVSourcePlayer hardcodes its own at this point)")
        let p = try MPVSourcePlayer()
        try attachRenderAndStart(player: p)
        p.setPlaylist([filePath])
        p.play()
        self.ownedPlayer = p
    }

    /// Production entry — view does not own the player.
    func attach(player: MPVSourcePlayer) throws {
        try attachRenderAndStart(player: player)
        self.sharedPlayer = player
    }

    private func attachRenderAndStart(player: MPVSourcePlayer) throws {
        try player.attachRender()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.renderTick()
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    private func renderTick() {
        let layer = self.metalLayer
        let size = layer.drawableSize
        let queue = self.commandQueue
        // CV display-link is off-main; player.renderInto is thread-safe via
        // its renderLock try-lock.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.player?.renderInto(layer: layer, drawableSize: size, commandQueue: queue)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDown() }
    }

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
    }

    deinit { tearDown() }
}

struct MPVDebugRepresentable: NSViewRepresentable {
    let filePath: String
    let hwdec: String
    let overlayTint: Bool
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}

/// Production view used by ContentView in Phase 4.
struct MPVPlayerView: NSViewRepresentable {
    let player: MPVSourcePlayer?
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        if let player {
            do { try v.attach(player: player) }
            catch { NSLog("[MPV] attach failed: \(error)") }
        }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {
        // No-op; the view recreates if the player identity changes (the
        // parent uses .id(player.generation) — see Phase 4).
    }
}
```

**Step 3: Run the bring-up window.** Open Debug → MPV Bring-up Window → file plays. Reload 3× — no leaks.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): move render lifecycle into MPVSourcePlayer; cache MTL device/queue"
```

---

### Task 3.6: Skip primitive — `seek(playlistPos:timeSeconds:exact:)` with reply-ID lifetimes

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add the public seek API + private async dispatch.**

```swift
public func seek(
    playlistPos targetPos: Int,
    timeSeconds targetTime: Double,
    exact: Bool,
    completion: @escaping @MainActor () -> Void
) {
    // Single-slot pending model: SkipCoordinator guarantees only one
    // seek in flight at a time, so we never need to track more than
    // one pending. Any prior pending entry was either fired (and would
    // have caused SkipCoordinator to issue this new seek) or was
    // dropped via bumpGeneration — either way it's gone here.
    pending = nil

    if targetPos == playlistPos {
        let flags = exact ? "absolute+exact" : "absolute+keyframes"
        issueAsync(
            args: ["seek", String(targetTime), flags],
            completion: completion
        )
    } else {
        guard playlistPaths.indices.contains(targetPos) else {
            // Defensive: out-of-range playlist pos. Fire completion so
            // SkipCoordinator advances; the next user input will recover.
            Task { @MainActor in completion() }
            return
        }
        issueAsync(
            args: ["loadfile", playlistPaths[targetPos], "replace", "0", "start=\(targetTime)"],
            completion: completion
        )
    }
}

private func issueAsync(
    args: [String],
    completion: @escaping @MainActor () -> Void
) {
    let id = nextReplyID
    nextReplyID &+= 1

    // strdup each arg; ownership transfers to the PendingSeek struct,
    // which holds them until MPV_EVENT_COMMAND_REPLY frees them. The
    // freed-too-soon UAF that motivates this comment was identified in
    // the v1 plan's adversarial review.
    var cstrings: [UnsafeMutablePointer<CChar>?] =
        args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    pending = PendingSeek(
        replyID: id,
        generation: generation,
        completion: completion,
        cstrings: cstrings,
        commandReplied: false
    )

    cstrings.withUnsafeMutableBufferPointer { buf in
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command_async(handle, id, p)
    }
}

/// Called from the event-pump's COMMAND_REPLY branch (Task 3.7) to free
/// the strdup'd args.
fileprivate func freePendingCstrings() {
    if var p = pending {
        for c in p.cstrings { if let c { free(c) } }
        p.cstrings = []
        pending = p
    }
}
```

**Step 2: Build.** No tests yet (the integration test happens at Phase 4).
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer.seek with reply-ID lifetime tracking"
```

---

### Task 3.7: `MPV_EVENT_COMMAND_REPLY` + `MPV_EVENT_PLAYBACK_RESTART` dispatch

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Extend the pump.** Add above the existing `MPV_EVENT_PROPERTY_CHANGE` block:

```swift
if id == MPV_EVENT_COMMAND_REPLY {
    let replyID = evt.pointee.reply_userdata
    let cmdError = evt.pointee.error
    Task { @MainActor [weak self] in
        guard let self else { return }
        guard var p = self.pending, p.replyID == replyID else { return }
        // Free the strdup'd argv — mpv has consumed them by now.
        for c in p.cstrings { if let c { free(c) } }
        p.cstrings = []
        if cmdError < 0 {
            // Command rejected. Drop the pending entry; SkipCoordinator
            // will time out via its debounce. Don't fire completion, or
            // it would advance the coordinator on a non-event.
            self.pending = nil
        } else {
            p.commandReplied = true
            self.pending = p
        }
    }
    continue
}
if id == MPV_EVENT_PLAYBACK_RESTART {
    Task { @MainActor [weak self] in
        guard let self else { return }
        // Only fire when (a) a pending seek exists, (b) its command
        // already replied (so this PLAYBACK_RESTART is for our seek,
        // not for a natural playlist auto-advance with no seek in
        // flight), and (c) the generation matches.
        guard let p = self.pending,
              p.commandReplied,
              p.generation == self.generation else { return }
        self.pending = nil
        p.completion()
    }
    continue
}
```

**Step 2: Build + smoke (open the debug window; file plays).**
```bash
./scripts/run.sh
```
Expected: clean build, debug window still plays the file. (No skip dispatch active yet.)

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): seek-completion via PLAYBACK_RESTART gated on COMMAND_REPLY"
```

---

## Phase 4 — Atomic migration: Workspace + ContentView + TransportBar + PlayerSurface + KeyCommandView

This is one task with sub-steps. The intermediate state isn't compileable, so a fresh implementer subagent runs the full task in one pass; review runs once on the post-task diff. Phase 4 has no per-step commits — only the final commit at the end.

### Task 4.1: Migrate everything to `MPVSourcePlayer` + delete the AVPlayer source path

**Files:**
- Modify: `App/Models/Workspace.swift`
- Modify: `App/ContentView.swift`
- Modify: `App/Views/PlayerSurface.swift`
- Modify: `App/Views/TransportBar.swift`
- Modify: `App/Views/KeyCommandView.swift`

**Step 1: Survey before editing.**

```bash
grep -n "virtualPlayer\|virtualComposition\|currentPlayer\|skipCoordinatorPlayerID" App
grep -n "KeyCatchingView\b" App/Views/KeyCommandView.swift App/ContentView.swift
```
Confirm the call sites match the changes below. If the codebase has additions to these symbols beyond what the plan describes, surface them before continuing — the plan may need to be updated.

**Step 2: `App/Models/Workspace.swift` edits.**

Replace the field declarations (the lines with `var virtualPlayer: AVPlayer?` and `var virtualComposition: AVMutableComposition?`):
```swift
/// Source-playback engine. Persistent (D2). Lazy-created on first
/// rebuildSourcePlayer that has resolved sources. Stays alive across
/// missing-source / Relink cycles so a successful relink does not pay
/// init cost again.
var sourcePlayer: MPVSourcePlayer?
```

Update the `missingSourceIndices` doc-comment (above the `missingSourceIndices` field):
```swift
/// Indices into `project.sourceVideos` whose bookmark failed to resolve
/// (file moved/renamed/deleted). Recomputed every `rebuildSourcePlayer`.
/// When non-empty, `sourcePlayer`'s playlist is intentionally cleared so
/// the UI can surface a Relink banner — playback would be confusing if
/// we played only the surviving sources, since clip `sourceIndex`es
/// would no longer line up with the concat.
var missingSourceIndices: Set<Int> = []
```

Replace `func rebuildVirtualPlayer() async throws` with:
```swift
func rebuildSourcePlayer() async throws {
    var resolved: [(index: Int, url: URL)] = []
    var missing: Set<Int> = []
    for index in project.sourceVideos.indices {
        do {
            let url = try resolveAndRefreshBookmark(&project.sourceVideos[index])
            resolved.append((index, url))
        } catch {
            missing.insert(index)
        }
    }
    self.missingSourceIndices = missing

    guard !project.sourceVideos.isEmpty, missing.isEmpty else {
        sourcePlayer?.setPlaylist([])
        return
    }

    if sourcePlayer == nil {
        sourcePlayer = try MPVSourcePlayer()
    }
    sourcePlayer?.setPlaylist(resolved.map { $0.url.path(percentEncoded: false) })
    sourcePlayer?.setVolume(project.preferences.scanVolume)
}
```

Rename every caller of `rebuildVirtualPlayer` to `rebuildSourcePlayer` (use `grep -rn 'rebuildVirtualPlayer' App` to find them).

**Keep `Workspace.sourceTime(at:)` as-is** — it's no longer dead; the new source-mode `handleSkip` uses it (Step 3 below).

**Step 3: `App/ContentView.swift` edits.**

Delete `currentPlayer: AVPlayer?` (the computed property) and `@State private var skipCoordinatorPlayerID: ObjectIdentifier?`.

Add a preview-side generation counter:
```swift
/// Bumped on every selectedClipID change so a late preview-mode seek
/// completion is dropped (D12 — also fixes the preexisting AVPlayer
/// cache-hit A→B→A bug previously documented at the .onChange site).
@State private var previewSkipGeneration: UInt64 = 0
```

Replace the existing `.onChange(of: selectedClipID)` reset handler:
```swift
.onChange(of: selectedClipID) { _, _ in
    previewSkipGeneration &+= 1
    workspace.sourcePlayer?.bumpGeneration()
    resetSkipState()
}
```

Replace `resetSkipState()`:
```swift
private func resetSkipState() {
    skipDebounceTask?.cancel()
    skipDebounceTask = nil
    skipCoordinator.reset()
    coarseSeekInFlight = false
}
```

Replace the `PlayerSurface(player: currentPlayer)` ZStack member with a switch:
```swift
switch appMode {
case .scanning, .recordingStarting, .recording:
    MPVPlayerView(player: workspace.sourcePlayer)
case .previewLoading:
    Color.black
case .previewClip(let id):
    PreviewPlayerSurface(player: workspace.previewPlayer(for: id))
}
```

Update the `KeyCommandView(...)` call — drop the `player:` argument.

Replace `handleSkip(_:)` and `applySkipDecision(_:on:)` with the cumulative-coordinate source path + the closure-based preview path, both calling `driveSkipDecision`:

```swift
private func handleSkip(_ delta: Double) {
    if appMode == .recording { recordingController?.appendSkip(delta: delta) }
    let now = CACurrentMediaTime()

    switch appMode {
    case .scanning, .recordingStarting, .recording:
        guard let player = workspace.sourcePlayer else { return }
        let project = workspace.project
        let cumulativeCurrent = project.cumulativeOffset(forSourceIndex: player.playlistPos) + player.timePos
        let total = project.totalSourceDuration
        // SkipCoordinator does NOT walk a playlist; it operates on a
        // single scalar `current/duration`. We feed it cumulative-time
        // semantics so its target lands in [0, total].
        let decision = skipCoordinator.requestSkip(
            deltaSeconds: delta,
            currentPlayerTimeSeconds: cumulativeCurrent.isFinite ? cumulativeCurrent : 0,
            clipDurationSeconds: total > 0 ? total : .greatestFiniteMagnitude,
            nowMonotonicSeconds: now
        )
        let gen = player.generation
        driveSkipDecision(decision, generation: gen) { params, completion in
            // Translate cumulative target back to (sourceIndex, sourceLocal),
            // applying the D9 end-clamp epsilon to ensure mpv never
            // refuses the seek.
            let endEpsilon: Double = 0.05
            let clamped = max(0, min(params.targetSeconds, max(0, total - endEpsilon)))
            let mapped = workspace.sourceTime(at: clamped)
            player.seek(
                playlistPos: mapped.sourceIndex,
                timeSeconds: mapped.sourceLocalSeconds,
                exact: params.exact,
                completion: completion
            )
        }

    case .previewClip(let id):
        guard let player = workspace.previewPlayer(for: id) else { return }
        let durRaw = player.currentItem?.duration.seconds ?? .infinity
        let dur = (durRaw.isFinite && durRaw > 0) ? durRaw : .greatestFiniteMagnitude
        let curr = player.currentTime().seconds
        let decision = skipCoordinator.requestSkip(
            deltaSeconds: delta,
            currentPlayerTimeSeconds: curr.isFinite ? curr : 0,
            clipDurationSeconds: dur,
            nowMonotonicSeconds: now
        )
        let gen = previewSkipGeneration
        driveSkipDecision(decision, generation: gen) { params, completion in
            let t = CMTime(seconds: params.targetSeconds, preferredTimescale: 600)
            let tol: CMTime = params.exact ? .zero : .positiveInfinity
            if !params.exact { coarseSeekInFlight = true }
            player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) { _ in
                Task { @MainActor in
                    // Generation-guard the state mutation so it doesn't
                    // bleed into a fresh preview the user has navigated to.
                    if gen == previewSkipGeneration {
                        coarseSeekInFlight = false
                    }
                    completion()
                }
            }
        }

    case .previewLoading:
        return
    }
}

@MainActor
private func driveSkipDecision(
    _ decision: SkipDecision,
    generation: UInt64,
    issueSeek: @escaping (SeekParams, _ completion: @escaping @MainActor () -> Void) -> Void
) {
    if let s = decision.seek {
        issueSeek(s) {
            // Late-completion guard.
            guard generation == self.currentSkipGeneration() else { return }
            let next = self.skipCoordinator.seekCompleted(
                nowMonotonicSeconds: CACurrentMediaTime()
            )
            self.driveSkipDecision(next, generation: generation, issueSeek: issueSeek)
        }
    }
    if let after = decision.armDebounceSeconds {
        skipDebounceTask?.cancel()
        skipDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            if Task.isCancelled { return }
            guard generation == self.currentSkipGeneration() else { return }
            let next = self.skipCoordinator.burstEnded(
                nowMonotonicSeconds: CACurrentMediaTime()
            )
            self.driveSkipDecision(next, generation: generation, issueSeek: issueSeek)
        }
    }
}

private func currentSkipGeneration() -> UInt64 {
    switch appMode {
    case .scanning, .recordingStarting, .recording:
        return workspace.sourcePlayer?.generation ?? 0
    case .previewClip, .previewLoading:
        return previewSkipGeneration
    }
}
```

Replace `handleTogglePlay`:
```swift
private func handleTogglePlay() {
    switch appMode {
    case .scanning, .recordingStarting, .recording:
        guard let player = workspace.sourcePlayer else { return }
        let wasPlaying = !player.isPaused
        wasPlaying ? player.pause() : player.play()
        if appMode == .recording {
            wasPlaying
                ? recordingController?.appendPause()
                : recordingController?.appendPlay()
        }
    case .previewClip(let id):
        guard let player = workspace.previewPlayer(for: id) else { return }
        let wasPlaying = player.rate != 0
        wasPlaying ? player.pause() : player.play()
    case .previewLoading:
        return
    }
}
```

Update `handleSelectionChange` — replace the `workspace.virtualPlayer?.pause()` line with `workspace.sourcePlayer?.pause()`.

Update `handleClosePreview`:
```swift
private func handleClosePreview() {
    previewSkipGeneration &+= 1
    resetSkipState()
    workspace.previewPlayer(for: selectedClipID ?? UUID())?.pause()
    selectedClipID = nil
}
```

Update `startRecording` — the source-time read pattern is *pause synchronously, yield, then read cached observed values*:
```swift
guard let player = workspace.sourcePlayer else {
    recordingError = "Add a source video before recording."
    return
}
player.pause()
appMode = .recordingStarting

let clipID = UUID()
let filename = "clip-\(clipID).mov"
let url = recordingsDir.appendingPathComponent(filename)
let preferredCameraID = deviceCatalog.selectedCameraID
let preferredMicID = deviceCatalog.selectedMicID

Task {
    // One event-pump tick to flush pause / playlist-pos / time-pos
    // events so the cached @Observable fields reflect the post-pause
    // state. Without this we may capture a pre-pause prefetch state.
    await Task.yield()

    let mappedSourceIndex = player.playlistPos
    let mappedSourceLocal = player.timePos
    await MainActor.run {
        pendingRecording = PendingRecording(
            clipID: clipID,
            filename: filename,
            sourceIndex: mappedSourceIndex,
            startSourceSeconds: mappedSourceLocal
        )
    }
    // ...rest of the existing Task body (capture.prepareForRecording,
    // capture.startRecording, controller wiring, etc) is unchanged.
}
```

> The exact restructure: keep all the existing pre-Task logic (validate folder, build clipID, etc); move the synchronous `player.currentTime()` + `sourceTime(at:)` lines that previously set `pendingRecording` into the Task body, replaced with the pause+yield+read pattern shown above. The `Task { do { try await capture.prepareForRecording(...) } catch { ... } }` block stays intact otherwise.

**Step 4: `App/Views/PlayerSurface.swift`** — rename `PlayerSurface` to `PreviewPlayerSurface` (the file becomes preview-only):

```swift
import SwiftUI
import AVKit

/// AVPlayerView wrapper used by clip-preview only. Source-mode rendering
/// goes through MPVPlayerView (App/Views/MPVPlayerView.swift).
struct PreviewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
```

**Step 5: `App/Views/TransportBar.swift`** — rebind `ScanningTransport` to `sourcePlayer`:

```swift
struct ScanningTransport: View {
    @Bindable var workspace: Workspace
    @Binding var openProjectError: String?

    var body: some View {
        HStack(spacing: 12) {
            Button("Open Project Folder…") { openProjectFolder() }
            Button("Add Source Video…") { addSourceVideo() }
                .disabled(workspace.folder == nil)

            Divider().frame(height: 20)

            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(workspace.sourcePlayer == nil)
            .help(isPlaying ? "Pause" : "Play")

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(
                    value: Bindable(workspace).project.preferences.scanVolume,
                    in: 0...1
                )
                .frame(width: 120)
                .onChange(of: workspace.project.preferences.scanVolume) { _, new in
                    workspace.sourcePlayer?.setVolume(new)
                    try? workspace.saveProject()
                }
            }

            Spacer()
        }
    }

    private var isPlaying: Bool {
        guard let p = workspace.sourcePlayer else { return false }
        return !p.isPaused
    }

    private func togglePlay() {
        guard let player = workspace.sourcePlayer else { return }
        if player.isPaused {
            player.setVolume(workspace.project.preferences.scanVolume)
            player.play()
        } else {
            player.pause()
        }
    }

    // openProjectFolder + addSourceVideo (the existing two helpers at
    // the bottom of this struct) are unchanged.
    // ...
}
```

`RecordingTransport`, `PreviewTransport`, and `VolumeSlider` stay as-is.

**Step 6: `App/Views/KeyCommandView.swift`** — drop the dead `player` parameter:

```swift
struct KeyCommandView: NSViewRepresentable {
    let appMode: AppMode
    let onSkip: (Double) -> Void
    let onTogglePlay: () -> Void
    let onToggleRecord: () -> Void
    let onClosePreview: () -> Void

    func makeNSView(context: Context) -> KeyCatchingView {
        let v = KeyCatchingView()
        apply(to: v)
        return v
    }
    func updateNSView(_ v: KeyCatchingView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: KeyCatchingView) {
        v.appMode = appMode
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        v.onToggleRecord = onToggleRecord
        v.onClosePreview = onClosePreview
    }
}
```

(`KeyCatchingView`'s implementation, and the `NSEvent` monitor's body, are unchanged.)

**Step 7: Build.**

```bash
./scripts/run.sh
```
Expected: clean build. App launches.

**Step 8: Smoke test the verification checklist.**

Walk every checkbox in the design's "Verification checklist (manual smoke)" section:

- [ ] 4K test file plays smoothly end-to-end as source (compare against the pre-swap commit).
- [ ] FF/RW key burst inside a single source: same UX as AVPlayer path.
- [ ] FF/RW key burst that crosses a source boundary: lands in next/previous file at correct local offset.
- [ ] Toggle play/pause via space and the transport bar button.
- [ ] Volume slider audibly changes source playback gain.
- [ ] R-press starts a recording; the resulting clip's `sourceIndex` + `startSourceSeconds` match the displayed frame at R-press (verify by previewing the recorded clip and visually confirming the source frame).
- [ ] Select clip → mpv pauses, preview takes over; close preview → mpv view returns, paused.
- [ ] Source bookmark stale (rename file externally) → Relink banner; mpv playlist cleared; relink restores playback.
- [ ] A → B → A clip-selection round-trip: each new skip on the second visit issues a real seek.
- [ ] No crash on app quit; mpv handle terminates cleanly.
- [ ] Hardened-runtime entitlements (camera + mic) still pass.

If any item fails, debug before committing.

**Step 9: Commit.**

```bash
git commit -am "refactor(source-playback): wire MPVSourcePlayer through Workspace/ContentView/UI

- Workspace.virtualPlayer/virtualComposition replaced by sourcePlayer.
- rebuildVirtualPlayer renamed to rebuildSourcePlayer.
- ContentView.currentPlayer + skipCoordinatorPlayerID deleted.
- handleSkip routes source-mode through cumulative-time math, then
  Workspace.sourceTime(at:) translates to per-file before MPVSourcePlayer.seek.
- driveSkipDecision control-flow helper shared by source + preview paths.
- previewSkipGeneration counter replaces ObjectIdentifier guard for the
  preview side too; fixes preexisting A→B→A AVPlayer cache-hit bug.
- PlayerSurface split into PreviewPlayerSurface; MPVPlayerView used in
  scanning ZStack.
- KeyCommandView dead 'player' param dropped.
- TransportBar.ScanningTransport rebound to MPVSourcePlayer.
- startRecording reads cached @Observable (playlistPos, timePos) after
  pause+yield, avoiding synchronous mpv_get_property on the main actor."
```

---

## Phase 5 — Adversarial implementation review (orchestrator-only)

> **Phase 5 is not an executable subagent task.** It runs at the orchestrator level, not inside a fresh subagent. The orchestrator should run this phase between Phase 4 completing and the branch merging.

**Step 1: Produce the implementation diff.**
```bash
git log --oneline origin/main..HEAD -- \
  App/Source App/Views/MPVPlayerView.swift App/Views/MPVDebugWindow.swift \
  App/Views/PlayerSurface.swift App/Views/TransportBar.swift \
  App/Views/KeyCommandView.swift App/Models/Workspace.swift \
  App/ContentView.swift App/VideoCoach.entitlements \
  App/VideoCoachApp.swift project.yml \
  VideoCoachCore/Sources/VideoCoachCore VideoCoachCore/Tests/VideoCoachCoreTests/WorkspaceCumulativeTests.swift
```

**Step 2: Spawn two reviewer subagents in parallel** — `feature-dev:code-reviewer` and `superpowers:code-reviewer`. Brief them to review the *implementation*, not the design or plan (those have already been reviewed).

**Step 3: Fold findings.** Same pattern as the previous plan. Apply fixes; document in a follow-up commit.

**Step 4: Final smoke + merge prep.** Walk the verification checklist a final time after all review fixes land.

---

## Verification checklist (post-execution)

- [ ] `cd VideoCoachCore && swift test` — all tests pass (existing SkipCoordinator + PreviewCompositor + new `ProjectCumulativeTests`).
- [ ] `./scripts/run.sh` — app builds clean, launches without dyld errors.
- [ ] Phase 1 gate items (a)–(f) all PASS — recorded in Task 1.3's commit message.
- [ ] 4K test file plays smoothly end-to-end as source. Compare against the pre-swap commit.
- [ ] FF/RW (D / right arrow / shift+D / shift+right arrow / and reverse with A / left arrow) responds correctly during a burst, settles to exact frame ~150ms after release.
- [ ] FF/RW that crosses a source boundary lands in the next/previous file at the correct local offset.
- [ ] Space toggles play/pause; volume slider audibly affects source playback.
- [ ] R-press records a clip whose `(sourceIndex, startSourceSeconds)` matches the displayed frame at R-press.
- [ ] Esc / Source button closes a preview; mpv view returns paused.
- [ ] A → B → A clip-selection round-trip: each new skip on the second visit issues a real seek.
- [ ] Sidebar source-rename / Relink flow works with the persistent mpv handle.
- [ ] No crash on app quit; mpv handle terminates cleanly.

---

## Phase 1 outcome → Phase 3.1 hwdec value

Task 3.1 hardcodes `MPVSourcePlayer.hwdecOption = "videotoolbox"`. If Phase 1 picked `hwdec=no` instead, change the constant *before* running Task 3.1. The Phase 1 commit message records the chosen value as the source of truth.
