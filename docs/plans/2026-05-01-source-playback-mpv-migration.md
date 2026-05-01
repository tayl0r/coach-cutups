# Source-Playback Decoder Swap: AVPlayer → libmpv (MPVKit) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `Workspace.virtualPlayer` (`AVPlayer` over `AVMutableComposition`) with `Workspace.sourcePlayer` (`MPVSourcePlayer` over a persistent `mpv_handle`) for source-playback only, so 4K Android-camera HEVC files that AVFoundation mishandles play smoothly. Keep AVPlayer for clip-preview and export.

**Architecture:** App-side `MPVSourcePlayer` class wraps a persistent `mpv_handle` driven by playlist commands. Per-file `time-pos` semantics; cross-boundary skips use atomic `loadfile <path> replace start=<t>`. Seek-completion is `MPV_EVENT_PLAYBACK_RESTART` matched to async-command reply IDs. A playlist-generation counter on `MPVSourcePlayer` replaces the AVPlayer `ObjectIdentifier` stale-completion guard for *both* source and preview paths. A small `driveSkipDecision` control-flow helper hosts the debounce + late-completion + recursion logic that both paths share.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, AVFoundation (preview + export), MPVKit (source playback), CoreImage, CoreVideo, XCTest, SwiftPM.

**Companion design document:** `docs/plans/2026-05-01-source-playback-mpv-migration-design.md` — read this first for the *why* behind every decision (D1–D15) and the rejected alternatives. This plan covers the *what* and *how*.

**Test commands:**
- `cd VideoCoachCore && swift test --filter PlaylistSkipResolverTests` — Phase 2 unit tests
- `./scripts/run.sh` — manual smoke for Phases 1, 3, 4, 5

---

## Phase 1 — Bring-up + de-risk gate

This phase is the load-bearing gate for the entire swap. If any of the gate checks fail, **stop and re-plan** rather than proceeding to Phase 2.

### Task 1.1: Add MPVKit SwiftPM dependency

**Files:**
- Modify: `project.yml`

**Step 1: Modify `project.yml`** to add MPVKit as a top-level package and depend on it from the App target.

Replace the `packages:` block:
```yaml
packages:
  VideoCoachCore:
    path: VideoCoachCore
  MPVKit:
    url: https://github.com/mpvkit/MPVKit
    from: 0.39.0
```

> **Note on the version pin:** MPVKit's `0.39.x` line ships libmpv 0.39 with HEVC + libavcodec built in. If `swift package resolve` (next step) fails to find a 0.39+ tag, fall back to `from: 0.38.0`. Record the resolved version in the commit message.

Replace the App target's `dependencies:` block:
```yaml
    dependencies:
      - package: VideoCoachCore
      - package: MPVKit
        product: MPVKit
```

**Step 2: Regenerate the Xcode project and resolve packages.**
```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project VideoCoach.xcodeproj
```
Expected: clean resolution; the resolved version of MPVKit appears in `VideoCoach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (or wherever xcodegen places it).

**Step 3: Build the project to confirm the link.**
```bash
./scripts/run.sh
```
Expected: app builds and launches with no runtime change yet (no MPVKit symbols are imported anywhere). If the build fails with a missing symbol or framework, the package didn't link cleanly — diagnose before continuing.

**Step 4: Commit.**
```bash
git add project.yml VideoCoach.xcodeproj
git commit -m "build(source-playback): add MPVKit SwiftPM dependency"
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

**Goal:** Build the smallest possible `NSView` + `mpv_render_context` integration that loads a hardcoded path and renders. This is throwaway code in the sense that it gets superseded by the production `MPVPlayerView` in Phase 3, but it has to actually work end-to-end against MPVKit's headers, so we land it as real code in `App/Views/MPVPlayerView.swift` with a hardcoded debug entry point and progressively grow it.

**Files:**
- Create: `App/Views/MPVPlayerView.swift`
- Create: `App/Views/MPVDebugWindow.swift`
- Modify: `App/VideoCoachApp.swift` (add a hidden debug menu)

**Step 1: Read MPVKit's public headers** to confirm the import path and render-API surface for the resolved version.

```bash
xcodebuild -resolvePackageDependencies -project VideoCoach.xcodeproj
find ~/Library/Developer/Xcode/DerivedData -name "MPVKit.h" 2>/dev/null | head -3
find ~/Library/Developer/Xcode/DerivedData -path "*MPVKit*" -name "*.h" 2>/dev/null | head -20
```
Expected: at minimum `client.h` and `render.h` reachable through `import Libmpv` (or `import MPVKit` — header path naming varies by version). **Record the actual import in the commit message** so a future reader can find it.

> **If MPVKit's Swift module is named differently** (e.g. `Libmpv` rather than `MPVKit`), use that name in every `import` below.

**Step 2: Create `App/Views/MPVPlayerView.swift`.**

This is the production view location. Phase 1 lands a minimal version; Phase 3 wires it to a real `MPVSourcePlayer`. For Phase 1 it just owns the mpv handle directly because there is no `MPVSourcePlayer` yet.

```swift
import SwiftUI
import AppKit
import Metal
import QuartzCore
import MPVKit  // adjust to actual module name from Step 1

/// Minimal mpv-rendering NSView. Phase 1 hosts this with its own
/// mpv_handle for the bring-up gate; Phase 3 swaps the handle ownership
/// to MPVSourcePlayer.
final class MPVRenderingNSView: NSView {
    private(set) var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var displayLink: CVDisplayLink?
    private let metalLayer = CAMetalLayer()

    /// Swift-side flag used by the teardown gate. See render(_:) and
    /// detachRender(). Sync via objc_sync — render() is called from the
    /// CVDisplayLink thread, detachRender() from the main thread.
    private var isRenderingFlag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Phase 1 helper — creates an mpv handle and loads a file. Phase 3
    /// removes this and routes through MPVSourcePlayer instead.
    func bringUp(filePath: String, hwdec: String) throws {
        let handle = mpv_create()
        guard let handle else { throw NSError(domain: "MPV", code: -1) }

        // Options BEFORE mpv_initialize.
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "hwdec", hwdec)
        mpv_set_option_string(handle, "prefetch-playlist", "yes")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "keep-open-pause", "no")
        mpv_set_option_string(handle, "pause", "no")
        mpv_set_option_string(handle, "msg-level", "all=warn")
        mpv_set_option_string(handle, "audio-display", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "osd-level", "0")
        mpv_set_option_string(handle, "target-colorspace-hint", "yes")
        mpv_set_option_string(handle, "volume-correct", "no")

        let initRC = mpv_initialize(handle)
        guard initRC >= 0 else {
            mpv_destroy(handle)
            throw NSError(domain: "MPV", code: Int(initRC))
        }
        self.mpv = handle

        try attachRender()

        // Load the file — note "loadfile <path> replace" plus an empty
        // string makes the API surface line up with what we'll call from
        // setPlaylist() in Phase 3.
        var args: [UnsafePointer<CChar>?] = [
            ("loadfile" as NSString).utf8String,
            (filePath as NSString).utf8String,
            ("replace" as NSString).utf8String,
            nil,
        ]
        args.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(handle, buf.baseAddress)
        }
    }

    private func attachRender() throws {
        guard let mpv else { return }
        // SW render API for Phase 1 — simplest and matches MPVKit's
        // baseline support across versions. Phase 3 may swap to an
        // advanced Metal context if MPVKit's headers expose it.
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

        // Display link drives renders.
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.render()
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    private func render() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard let renderContext else { return }
        isRenderingFlag = true
        defer { isRenderingFlag = false }

        let drawable = metalLayer.nextDrawable()
        guard let drawable else { return }

        // SW path: render into a CPU buffer the metal layer can blit.
        // For Phase 1 we keep this simple and correct, not maximally fast.
        let w = Int32(metalLayer.drawableSize.width)
        let h = Int32(metalLayer.drawableSize.height)
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

        drawable.texture.replace(
            region: MTLRegionMake2D(0, 0, Int(w), Int(h)),
            mipmapLevel: 0,
            withBytes: pixelBuffer,
            bytesPerRow: bytesPerRow
        )

        let cmdBuf = MTLCreateSystemDefaultDevice()?.makeCommandQueue()?.makeCommandBuffer()
        cmdBuf?.present(drawable)
        cmdBuf?.commit()
    }

    func detachRender() {
        // Order matters: stop the display link FIRST so no more callbacks
        // can sneak in past mpv_render_context_free.
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        // Wait for any in-flight render to finish before freeing.
        objc_sync_enter(self)
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        objc_sync_exit(self)
    }

    deinit {
        detachRender()
        if let mpv {
            mpv_terminate_destroy(mpv)
        }
    }
}

/// SwiftUI bridge for Phase 1's standalone bring-up window.
struct MPVDebugRepresentable: NSViewRepresentable {
    let filePath: String
    let hwdec: String
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}
```

**Step 3: Create `App/Views/MPVDebugWindow.swift`.**

```swift
import SwiftUI

/// Phase 1 / D6 gate. Opens a standalone window that loads the test file
/// through the new mpv pipeline. After the gate is passed, this stays in
/// the codebase as a debug affordance behind a hidden menu item; Phase 3
/// migrates the production scanning path to its own MPVPlayerView wrapper
/// over MPVSourcePlayer.
struct MPVDebugWindow: View {
    @State private var hwdec: String = "videotoolbox"
    @State private var filePath: String =
        "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4"
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
                Button("Reload") { revision &+= 1 }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            MPVDebugRepresentable(filePath: filePath, hwdec: hwdec)
                .id(revision)   // recreate the NSView (and mpv handle) on Reload
                .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}
```

**Step 4: Wire a hidden debug menu item in `App/VideoCoachApp.swift`.**

Read the existing file first:
```bash
cat App/VideoCoachApp.swift
```

Then modify it to add a new `WindowGroup` for the debug window plus a Debug menu. Replacement file (preserve existing content; this is the form expected after the change):

```swift
import SwiftUI

@main
struct VideoCoachApp: App {
    @State private var deviceCatalog = DeviceCatalog()

    var body: some Scene {
        WindowGroup {
            ContentView(deviceCatalog: deviceCatalog)
        }
        .commands {
            DevicesCommands(catalog: deviceCatalog)
            ClipCommands()
            CommandMenu("Debug") {
                Button("Open MPV Bring-up Window") {
                    openWindow("mpv-debug")
                }
            }
        }
        WindowGroup("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }
    }

    private func openWindow(_ id: String) {
        if let url = URL(string: "videocoach://\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

> **If the existing `VideoCoachApp.swift` has different contents** (the snapshot above is plausible but not verified at write-time), preserve all existing scenes/commands and just add the new `CommandMenu("Debug")` and the second `WindowGroup`. Don't blow away other state.

Actually — easier and more reliable: use `@Environment(\.openWindow)` from inside a wrapper. **Use this form instead:**

```swift
import SwiftUI

@main
struct VideoCoachApp: App {
    @State private var deviceCatalog = DeviceCatalog()

    var body: some Scene {
        WindowGroup {
            ContentView(deviceCatalog: deviceCatalog)
                .modifier(DebugMenuInjector())
        }
        .commands {
            DevicesCommands(catalog: deviceCatalog)
            ClipCommands()
        }
        WindowGroup("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }
    }
}

private struct DebugMenuInjector: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .onAppear {
                // No-op; the .commands menu is registered separately above.
            }
    }
}
```

Hmm — `.commands` must register the `CommandMenu`, not the modifier. Replace the `body` of `VideoCoachApp` with:

```swift
@main
struct VideoCoachApp: App {
    @State private var deviceCatalog = DeviceCatalog()
    @Environment(\.openWindow) private var openWindow_unused  // see DebugMenu

    var body: some Scene {
        WindowGroup {
            ContentView(deviceCatalog: deviceCatalog)
        }
        .commands {
            DevicesCommands(catalog: deviceCatalog)
            ClipCommands()
            DebugMenu()
        }
        WindowGroup("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }
    }
}

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

> **If the existing `VideoCoachApp.swift` looks different from the structure above**, preserve its actual shape and just add: (1) the `DebugMenu()` line inside the existing `.commands {}` block; (2) the second `WindowGroup` with `id: "mpv-debug"`; (3) the `DebugMenu` struct at file scope. Don't refactor existing scenes.

**Step 5: Build and launch.**
```bash
./scripts/run.sh
```
Expected: app launches with no behavior regression.

**Step 6: Open the bring-up window.**

In the running app: Debug menu → Open MPV Bring-up Window. The window appears with the test file path pre-filled and `hwdec=videotoolbox` selected. The video should start rendering and playing.

**Step 7: Run the gate checklist (D6 + Phase 1 gate).**

Execute each item; record pass/fail in the commit message.

- **(a) Decoder gate.** Test file plays with `hwdec=videotoolbox` for 60+ seconds. No keyframe-only stutter. If FAIL, switch the picker to `hwdec=no`, click Reload, repeat. **Pass condition:** at least one of these works smoothly. **Record the working value** — it goes into Task 3.1's `MPVSourcePlayer.init`.
- **(b) Hardened-runtime + library validation.** App launched cleanly (no dyld errors). PASS implicit if you got here.
- **(c) Render-context lifecycle.** With the file playing, click Reload 3× in succession. Player must continue playing without leaks, crashes, or render-context errors after each cycle.
- **(d) SwiftUI overlay composition.** Edit `MPVDebugWindow.swift` temporarily to overlay `Color.red.opacity(0.3)` on top of `MPVDebugRepresentable`. Rebuild. Verify the red tint composites correctly over the player surface. Revert the change.
- **(e) HEVC decoder presence.** Watch Console.app filtered by your app — mpv's log line `Using video decoder: hevc` (or similar) should appear within the first second of playback. If a `Failed to recognize file format` or `No video decoder found` message appears, MPVKit's bundled libavcodec is missing HEVC and the swap is invalidated.
- **(f) EOF behavior.** Click Reload to restart the file. Wait for playback to reach the end. Verify mpv parks on the last frame instead of going black or auto-closing.

**Step 8: If all six pass — commit and proceed.** Record the chosen `hwdec` value in the commit message; Task 3.1 reads it from there.

```bash
git add App/Views/MPVPlayerView.swift App/Views/MPVDebugWindow.swift App/VideoCoachApp.swift
git commit -m "feat(source-playback): Phase 1 mpv bring-up window + decoder gate

Phase 1 gate results:
- (a) decoder: hwdec=<videotoolbox|no> plays the test file smoothly
- (b) hardened-runtime: app launches cleanly with MPVKit linked
- (c) lifecycle: 3x reload cycles, no leaks
- (d) overlay: SwiftUI composites correctly over Metal-hosted player
- (e) HEVC: libavcodec hevc decoder present in MPVKit
- (f) EOF: parks on last frame as expected

MPVKit module imported as: <MPVKit|Libmpv>
Resolved version: <X.Y.Z>"
```

**Step 9: If any gate item fails — STOP. Do not proceed to Phase 2.** Update the design doc with what failed, re-plan.

---

## Phase 2 — `PlaylistSkipResolver` pure logic + tests

This phase lives entirely in `VideoCoachCore` and ships with full unit-test coverage before any App-side wiring uses it.

### Task 2.1: Skeleton + same-file happy path

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/PlaylistSkipResolver.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

**Step 1: Write the failing test.**

```swift
// VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift
import XCTest
@testable import VideoCoachCore

final class PlaylistSkipResolverTests: XCTestCase {
    func test_sameFile_withinBounds_landsAtCurrentPlusDelta() {
        let r = PlaylistSkipResolver.resolveSkip(
            currentPlaylistPos: 0,
            currentTimeSeconds: 30,
            fileDurations: [120],
            deltaSeconds: 5
        )
        XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 35))
    }
}
```

**Step 2: Run, expect compile failure.**
```bash
cd VideoCoachCore && swift test --filter PlaylistSkipResolverTests
```
Expected: build failure (`cannot find 'PlaylistSkipResolver' in scope`).

**Step 3: Implement the minimum types + same-file path.**

```swift
// VideoCoachCore/Sources/VideoCoachCore/PlaylistSkipResolver.swift
import Foundation

public struct PlaylistSkipResolution: Equatable, Sendable {
    public let targetPlaylistPos: Int
    public let targetTimeSeconds: Double
    public init(targetPlaylistPos: Int, targetTimeSeconds: Double) {
        self.targetPlaylistPos = targetPlaylistPos
        self.targetTimeSeconds = targetTimeSeconds
    }
}

/// Resolves a relative-time skip across a per-file mpv playlist.
///
/// mpv's `time-pos` is per-file (D3 in the design); a single delta-seconds
/// skip can stay inside the current file or walk forward/backward across
/// playlist entries. This resolver does the math purely so the App-side
/// MPVSourcePlayer.skip can dispatch either an in-file `seek` command or
/// an atomic `loadfile <path> replace start=<t>` (D13).
public enum PlaylistSkipResolver {
    /// Last 50ms of the final file is reserved as a clamp epsilon so we
    /// never issue a seek mpv would refuse (D9). Refused seeks do not fire
    /// MPV_EVENT_PLAYBACK_RESTART and would hang the SkipCoordinator.
    public static let endClampEpsilon: Double = 0.05

    public static func resolveSkip(
        currentPlaylistPos: Int,
        currentTimeSeconds: Double,
        fileDurations: [Double],
        deltaSeconds: Double
    ) -> PlaylistSkipResolution {
        // Empty playlist: defensive — the App path should never call us
        // with no entries, but if it does, return a position the App can
        // safely ignore.
        guard !fileDurations.isEmpty else {
            return PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 0)
        }
        let pos = max(0, min(currentPlaylistPos, fileDurations.count - 1))
        let t = currentTimeSeconds + deltaSeconds
        let dur = fileDurations[pos]
        if t >= 0 && t <= dur {
            return PlaylistSkipResolution(targetPlaylistPos: pos, targetTimeSeconds: t)
        }
        // TODO 2.2/2.3/2.4: clamping + cross-boundary walks.
        return PlaylistSkipResolution(targetPlaylistPos: pos, targetTimeSeconds: max(0, min(t, dur)))
    }
}
```

**Step 4: Run, expect pass.**
```bash
cd VideoCoachCore && swift test --filter PlaylistSkipResolverTests
```
Expected: 1 passing.

**Step 5: Commit.**
```bash
git add VideoCoachCore/Sources/VideoCoachCore/PlaylistSkipResolver.swift \
        VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift
git commit -m "feat(core): PlaylistSkipResolver same-file happy path"
```

---

### Task 2.2: Same-file clamping (negative + past end)

**Files:**
- Modify: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

**Step 1: Failing tests.**

```swift
func test_sameFile_largeNegativeDelta_clampsToZero() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0,
        currentTimeSeconds: 3,
        fileDurations: [120],
        deltaSeconds: -100
    )
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 0))
}

func test_sameFile_singleEntryPlaylist_pastEnd_clampsToDurationMinusEpsilon() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0,
        currentTimeSeconds: 100,
        fileDurations: [120],
        deltaSeconds: 50
    )
    // No file 1 to walk into; clamp to (last duration - epsilon).
    XCTAssertEqual(r.targetPlaylistPos, 0)
    XCTAssertEqual(r.targetTimeSeconds, 120 - PlaylistSkipResolver.endClampEpsilon, accuracy: 1e-9)
}
```

**Step 2: Run, expect failure.** (The "past end" case currently clamps to `dur` exactly, not `dur - epsilon`.)
```bash
cd VideoCoachCore && swift test --filter PlaylistSkipResolverTests
```
Expected: `test_sameFile_singleEntryPlaylist_pastEnd_clampsToDurationMinusEpsilon` fails.

**Step 3: Strengthen the resolver to apply the end-of-playlist epsilon.**

Replace the body of `resolveSkip` with:

```swift
public static func resolveSkip(
    currentPlaylistPos: Int,
    currentTimeSeconds: Double,
    fileDurations: [Double],
    deltaSeconds: Double
) -> PlaylistSkipResolution {
    guard !fileDurations.isEmpty else {
        return PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 0)
    }
    let lastIndex = fileDurations.count - 1
    let pos = max(0, min(currentPlaylistPos, lastIndex))

    // Same-file fast path.
    let t = currentTimeSeconds + deltaSeconds
    if t >= 0 && t <= fileDurations[pos] {
        return PlaylistSkipResolution(targetPlaylistPos: pos, targetTimeSeconds: t)
    }

    // Walk forward when t > duration of current file.
    if t > fileDurations[pos] {
        var residual = t - fileDurations[pos]
        var i = pos + 1
        while i <= lastIndex {
            if residual <= fileDurations[i] {
                return PlaylistSkipResolution(targetPlaylistPos: i, targetTimeSeconds: residual)
            }
            residual -= fileDurations[i]
            i += 1
        }
        // Past the end — clamp to (last, lastDuration - epsilon).
        let clamped = max(0, fileDurations[lastIndex] - endClampEpsilon)
        return PlaylistSkipResolution(targetPlaylistPos: lastIndex, targetTimeSeconds: clamped)
    }

    // Walk backward when t < 0.
    var residual = -t        // positive amount we still owe
    var i = pos - 1
    while i >= 0 {
        if residual <= fileDurations[i] {
            return PlaylistSkipResolution(targetPlaylistPos: i, targetTimeSeconds: fileDurations[i] - residual)
        }
        residual -= fileDurations[i]
        i -= 1
    }
    // Before the start — clamp to (0, 0).
    return PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 0)
}
```

**Step 4: Run, expect pass.**

**Step 5: Commit.**
```bash
git commit -am "feat(core): PlaylistSkipResolver clamping + walk skeletons"
```

---

### Task 2.3: Cross one boundary forward + backward

**Files:**
- Modify: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

**Step 1: Failing tests.**

```swift
func test_crossesOneBoundaryForward_landsInNextFile() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0,
        currentTimeSeconds: 110,
        fileDurations: [120, 90],
        deltaSeconds: 30
    )
    // 110 + 30 = 140. File 0 duration = 120. Residual = 20 into file 1.
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 1, targetTimeSeconds: 20))
}

func test_crossesOneBoundaryBackward_landsInPrevFile() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 1,
        currentTimeSeconds: 5,
        fileDurations: [120, 90],
        deltaSeconds: -10
    )
    // 5 - 10 = -5. Residual 5 walked back into file 0 from end.
    // File 0 duration = 120. Target = 120 - 5 = 115.
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 115))
}
```

**Step 2: Run.** Expected: PASS — the walk loops in 2.2 already cover this.

**Step 3:** No code change needed; if either fails, debug the walk.

**Step 4: Commit.**
```bash
git commit -am "test(core): PlaylistSkipResolver one-boundary cross"
```

---

### Task 2.4: Cross two or more boundaries

**Files:**
- Modify: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

**Step 1: Failing tests.**

```swift
func test_crossesTwoBoundariesForward_skipsThroughMiddleFileEntirely() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0,
        currentTimeSeconds: 100,
        fileDurations: [120, 30, 60],
        deltaSeconds: 80
    )
    // 100 + 80 = 180. File 0 has 20 left → residual 60.
    // File 1 dur = 30 → residual 30.
    // File 2: 30 ≤ 60 → land in file 2 at 30.
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 2, targetTimeSeconds: 30))
}

func test_crossesTwoBoundariesBackward_skipsThroughMiddleFileEntirely() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 2,
        currentTimeSeconds: 10,
        fileDurations: [120, 30, 60],
        deltaSeconds: -50
    )
    // -10 from file 2 start → residual 40 owed.
    // File 1 dur = 30 → consumed; residual 10.
    // File 0 dur = 120 → land at 120 - 10 = 110.
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 110))
}
```

**Step 2: Run, expect pass.** (Walk loop in 2.2 already handles this.)

**Step 3:** No code change.

**Step 4: Commit.**
```bash
git commit -am "test(core): PlaylistSkipResolver multi-boundary cross"
```

---

### Task 2.5: Edge cases (empty, single-entry, exact boundary)

**Files:**
- Modify: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

**Step 1: Failing tests.**

```swift
func test_emptyPlaylist_returnsZeroPosZeroTime() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0, currentTimeSeconds: 0,
        fileDurations: [], deltaSeconds: 5
    )
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 0))
}

func test_zeroDelta_landsExactlyAtCurrent() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 1, currentTimeSeconds: 42.5,
        fileDurations: [60, 60], deltaSeconds: 0
    )
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 1, targetTimeSeconds: 42.5))
}

func test_landsExactlyOnBoundary_goesToStartOfNextFile() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0, currentTimeSeconds: 110,
        fileDurations: [120, 90], deltaSeconds: 10
    )
    // 110 + 10 = 120 == file 0 duration. Same-file path accepts this
    // (t <= duration). Document this behavior; UI consumer may prefer
    // (1, 0) but for now (0, 120) is what mpv would land on with
    // `seek 120 absolute+exact`.
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 0, targetTimeSeconds: 120))
}

func test_singleEntry_clampsForward() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 0, currentTimeSeconds: 10,
        fileDurations: [60], deltaSeconds: 100
    )
    XCTAssertEqual(r.targetPlaylistPos, 0)
    XCTAssertEqual(r.targetTimeSeconds, 60 - PlaylistSkipResolver.endClampEpsilon, accuracy: 1e-9)
}

func test_invalidPos_clampsToValidRange() {
    let r = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: 5, currentTimeSeconds: 0,
        fileDurations: [60, 60], deltaSeconds: 5
    )
    // pos=5 is out of range; clamps to 1 (last valid).
    XCTAssertEqual(r, PlaylistSkipResolution(targetPlaylistPos: 1, targetTimeSeconds: 5))
}
```

**Step 2: Run.** Expected: all PASS (existing logic covers them).

**Step 3:** If anything fails, fix the resolver.

**Step 4: Commit.**
```bash
git commit -am "test(core): PlaylistSkipResolver edge cases (empty, zero, boundary, OOB)"
```

---

## Phase 3 — `MPVSourcePlayer` core class

### Task 3.1: Skeleton + init/deinit (no rendering yet)

**Files:**
- Create: `App/Source/MPVSourcePlayer.swift`

**Step 1: Create the file.**

```swift
import Foundation
import Observation
import MPVKit  // adjust if module name differs (see Task 1.3 commit)

/// Wraps a persistent mpv_handle for source-playback (D2 in the design).
/// One instance per Workspace; setPlaylist() reuses it across rebuilds.
@MainActor
@Observable
public final class MPVSourcePlayer {
    /// hwdec value chosen during Phase 1's gate. Recorded here so a fresh
    /// reader can find it; if Phase 1 picked "no", change this constant
    /// and add a comment referencing the commit.
    private static let hwdecOption = "videotoolbox"   // Phase-1-decided

    private let handle: OpaquePointer

    // Observed state — all updated from the event pump (Task 3.3).
    public private(set) var isPaused: Bool = true
    public private(set) var playlistCount: Int = 0
    public private(set) var playlistPos: Int = 0
    public private(set) var timePos: Double = 0
    public private(set) var currentDuration: Double = 0
    public private(set) var generation: UInt64 = 0

    public init() throws {
        guard let h = mpv_create() else {
            throw MPVSourcePlayerError.createFailed
        }
        // Options BEFORE mpv_initialize.
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
        // Phase 3.6 will replace this with the ordered render-context
        // teardown. For 3.1 we just terminate the handle.
        mpv_terminate_destroy(handle)
    }

    /// Bumps the generation counter (D12). Callers should bump this on
    /// preview-mode entry and on resetSkipState so any in-flight seek
    /// completion is dropped.
    public func bumpGeneration() {
        generation &+= 1
    }
}

public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
}
```

**Step 2: Update `project.yml` to include `App/Source/` in the App target's source roots.**

Read it first (`cat project.yml`). The `sources:` block currently lists `- App` which already covers `App/Source/`. **No change needed unless project.yml uses an explicit file list** (it doesn't, based on the file you read). Confirm by:

```bash
xcodegen generate
./scripts/run.sh
```
Expected: builds clean. (No new behavior; the class isn't instantiated yet.)

**Step 3: Commit.**
```bash
mkdir -p App/Source
git mv App/Source/MPVSourcePlayer.swift App/Source/MPVSourcePlayer.swift  # idempotent if already there
git add App/Source/MPVSourcePlayer.swift
git commit -m "feat(source-playback): MPVSourcePlayer skeleton"
```

> If `mkdir -p` and `git mv` aren't necessary because the file was created by the editor in the right path, just `git add` and commit.

---

### Task 3.2: Event-pump thread

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Why:** The event pump translates mpv's events to `@MainActor` writes on the observed properties (Task 3.3) and dispatches seek-completion (Task 3.9). Stand it up before subscribing to anything so events have a place to land.

**Step 1: Add a stored `Thread` to the class** plus a stop flag.

In `MPVSourcePlayer`, add:

```swift
private var pumpThread: Thread?
private var pumpShouldStop: Bool = false   // written from main, read from pump — accept the data race; guarded by mpv_terminate_destroy semantics
```

After `mpv_initialize` succeeds in `init`, start the pump:

```swift
let pump = Thread { [handle] in
    while true {
        // Block up to 100ms; mpv_wait_event with timeout 0 is non-blocking,
        // negative blocks forever. Short timeout lets pumpShouldStop be
        // observed reasonably promptly without busy-waiting.
        guard let evt = mpv_wait_event(handle, 0.1) else { continue }
        let id = evt.pointee.event_id
        if id == MPV_EVENT_NONE { continue }
        if id == MPV_EVENT_SHUTDOWN { return }
        // Phase 3.3 + 3.9 add per-event handling here.
    }
}
pump.name = "mpv-event-pump"
pump.start()
self.pumpThread = pump
```

Update `deinit` to terminate cleanly:

```swift
deinit {
    // mpv_terminate_destroy makes mpv_wait_event return MPV_EVENT_SHUTDOWN
    // which the pump uses to exit its loop.
    mpv_terminate_destroy(handle)
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: builds clean.

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer event-pump thread"
```

---

### Task 3.3: Property observation → `@Observable` cached values

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Subscribe to properties in `init`** (after `mpv_initialize`, before starting the pump):

```swift
mpv_observe_property(h, 1, "pause",          MPV_FORMAT_FLAG)
mpv_observe_property(h, 2, "playlist-count", MPV_FORMAT_INT64)
mpv_observe_property(h, 3, "playlist-pos",   MPV_FORMAT_INT64)
mpv_observe_property(h, 4, "time-pos",       MPV_FORMAT_DOUBLE)
mpv_observe_property(h, 5, "duration",       MPV_FORMAT_DOUBLE)
```

**Step 2: Handle property-change events in the pump.**

Replace the pump body's `// Phase 3.3 + 3.9 add ...` placeholder with:

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
                let v = data.assumingMemoryBound(to: Int32.self).pointee
                self.isPaused = (v != 0)
            }
        case 2:
            if let data = prop?.data {
                let v = data.assumingMemoryBound(to: Int64.self).pointee
                self.playlistCount = Int(v)
            }
        case 3:
            if let data = prop?.data {
                let v = data.assumingMemoryBound(to: Int64.self).pointee
                self.playlistPos = Int(max(0, v))
            }
        case 4:
            if let data = prop?.data {
                let v = data.assumingMemoryBound(to: Double.self).pointee
                if v.isFinite { self.timePos = v }
            }
        case 5:
            if let data = prop?.data {
                let v = data.assumingMemoryBound(to: Double.self).pointee
                if v.isFinite { self.currentDuration = v }
            }
        default: break
        }
    }
    continue
}
```

> **Note:** `mpv_event_property.data` is `nil` when the property became unset (e.g., `time-pos` after `loadfile` before the new file's first frame). The `if let data = prop?.data` guard handles this; the cached value sticks at its last known good value.

**Step 3: Build.**
```bash
./scripts/run.sh
```
Expected: builds clean.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): cache mpv property observations as @Observable state"
```

---

### Task 3.4: `setPlaylist` + `play/pause/togglePlay/setVolume`

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add the public methods.**

```swift
public func setPlaylist(_ paths: [String]) {
    runCommand(["playlist-clear"])
    for p in paths {
        runCommand(["loadfile", p, "append"])
    }
    bumpGeneration()
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

private func runCommand(_ args: [String]) {
    var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { cstrings.forEach { if let p = $0 { free(p) } } }
    cstrings.withUnsafeMutableBufferPointer { buf in
        // mpv_command takes UnsafeMutablePointer<UnsafePointer<CChar>?>; cast away mutability.
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command(handle, p)
    }
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: builds clean.

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer playlist + play/pause/volume"
```

---

### Task 3.5: Render-context attach/detach with teardown gate

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`
- Modify: `App/Views/MPVPlayerView.swift` (Phase 1's bring-up file)

**Step 1: Move the render-context lifecycle out of `MPVRenderingNSView` and into `MPVSourcePlayer`.**

Add to `MPVSourcePlayer`:

```swift
import QuartzCore

/// Returned by attachRender so the view can drive renders from its
/// CADisplayLink without holding the OpaquePointer itself.
public struct MPVRenderHandle {
    let context: OpaquePointer
}

private var renderContext: OpaquePointer?
private let renderLock = NSLock()  // synchronizes render() and detachRender()

public func attachRender() throws -> MPVRenderHandle {
    renderLock.lock(); defer { renderLock.unlock() }
    guard renderContext == nil else {
        // The view layer is responsible for not double-attaching; if we
        // get here something's leaked.
        throw MPVSourcePlayerError.alreadyAttached
    }
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
    return MPVRenderHandle(context: ctx)
}

public func detachRender() {
    renderLock.lock(); defer { renderLock.unlock() }
    if let ctx = renderContext {
        mpv_render_context_free(ctx)
        renderContext = nil
    }
}

/// Called by the view's CADisplayLink. Locks against detachRender to
/// honor the "only one mpv_render_* function at a time" rule.
public func renderInto(layer: CAMetalLayer, drawableSize: CGSize) {
    // Try-lock so a teardown can pre-empt cleanly without blocking us
    // here (we're on the displaylink thread).
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
    if let cmdBuf = layer.device?.makeCommandQueue()?.makeCommandBuffer() {
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
```

Update the error enum:
```swift
public enum MPVSourcePlayerError: Error {
    case createFailed
    case initializeFailed(code: Int)
    case alreadyAttached
    case renderContextFailed(code: Int)
}
```

Update `deinit` to detach render before terminating:
```swift
deinit {
    detachRender()
    mpv_terminate_destroy(handle)
}
```

**Step 2: Refactor `App/Views/MPVPlayerView.swift`.**

Replace `MPVRenderingNSView`'s render/lifecycle ownership with delegation to `MPVSourcePlayer`. The Phase 1 standalone `bringUp(filePath:hwdec:)` path stays — it now creates a private `MPVSourcePlayer`, calls `setPlaylist([filePath])`, and delegates rendering through it.

```swift
import SwiftUI
import AppKit
import Metal
import QuartzCore
import MPVKit

final class MPVRenderingNSView: NSView {
    private let metalLayer = CAMetalLayer()
    /// In Phase 1 / debug-window usage we own the player. In Phase 3+
    /// production usage the view holds a weak ref — Workspace owns the
    /// player. See setPlayer below.
    private var ownedPlayer: MPVSourcePlayer?
    private weak var sharedPlayer: MPVSourcePlayer?
    private var player: MPVSourcePlayer? { ownedPlayer ?? sharedPlayer }
    private var displayLink: CVDisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // Phase 1 standalone path.
    func bringUp(filePath: String, hwdec: String) throws {
        // hwdec is now baked into MPVSourcePlayer; the parameter here
        // exists for the bring-up window's hwdec picker. After Phase 1
        // closes we can drop it from the picker. For now it's logged.
        NSLog("[MPV-debug] requested hwdec=\(hwdec); MPVSourcePlayer is using its compiled-in default")
        let p = try MPVSourcePlayer()
        try attachRenderAndStart(player: p)
        self.ownedPlayer = p
        p.setPlaylist([filePath])
        p.play()
    }

    // Phase 3+ shared-player path.
    func attach(player: MPVSourcePlayer) throws {
        try attachRenderAndStart(player: player)
        self.sharedPlayer = player
    }

    private func attachRenderAndStart(player: MPVSourcePlayer) throws {
        _ = try player.attachRender()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard let self else { return kCVReturnError }
                self.renderTick()
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            self.displayLink = link
        }
    }

    private func renderTick() {
        // CV display link callbacks are off-main; route through the
        // player's renderInto which handles the lock against detach.
        let layer = self.metalLayer
        let size = layer.drawableSize
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.player?.renderInto(layer: layer, drawableSize: size)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            tearDown()
        }
    }

    private func tearDown() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // Phase 1 owned-player path: the view owns the player; deinit drops it.
        // Shared path: just detach, the workspace keeps the player.
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
    func makeNSView(context: Context) -> MPVRenderingNSView {
        let v = MPVRenderingNSView(frame: .zero)
        do { try v.bringUp(filePath: filePath, hwdec: hwdec) }
        catch { NSLog("[MPV-debug] bringUp failed: \(error)") }
        return v
    }
    func updateNSView(_ nsView: MPVRenderingNSView, context: Context) {}
}

/// Production representable — used by ContentView in Phase 5. Reads the
/// player from Workspace; the view does not own it.
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
        // No-op; the view is recreated on player identity change because
        // the parent uses .id(player.generation).
    }
}
```

**Step 3: Run the bring-up window again.**
```bash
./scripts/run.sh
```
Open Debug → MPV Bring-up Window. Expected: still plays the test file. Reload 3× — no leaks/crashes.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): move render lifecycle into MPVSourcePlayer"
```

---

### Task 3.6: Skip primitive — in-file seek with reply-ID completion

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add the completion-tracking storage.**

```swift
import VideoCoachCore  // for PlaylistSkipResolver

/// One in-flight seek's completion data, keyed by mpv_command_async reply ID.
private struct PendingSeek {
    let generation: UInt64
    let completion: @MainActor () -> Void
}
private var pendingSeeks: [UInt64: PendingSeek] = [:]
private var nextReplyID: UInt64 = 100  // any non-zero is fine
```

**Step 2: Add `skip` and `seekWithinCurrent`.**

```swift
public func skip(
    deltaSeconds: Double,
    exact: Bool,
    completion: @escaping @MainActor () -> Void
) {
    let durations = readPlaylistDurations()  // helper below
    let resolution = PlaylistSkipResolver.resolveSkip(
        currentPlaylistPos: playlistPos,
        currentTimeSeconds: timePos,
        fileDurations: durations,
        deltaSeconds: deltaSeconds
    )
    if resolution.targetPlaylistPos == playlistPos {
        seekAsync(targetSeconds: resolution.targetTimeSeconds, exact: exact, completion: completion)
    } else {
        // Cross-boundary path (Task 3.7).
        loadFileReplaceAsync(
            playlistPos: resolution.targetPlaylistPos,
            startSeconds: resolution.targetTimeSeconds,
            completion: completion
        )
    }
}

public func seekWithinCurrent(
    toSeconds: Double,
    exact: Bool,
    completion: @escaping @MainActor () -> Void
) {
    seekAsync(targetSeconds: toSeconds, exact: exact, completion: completion)
}

private func seekAsync(
    targetSeconds: Double,
    exact: Bool,
    completion: @escaping @MainActor () -> Void
) {
    let id = nextReplyID
    nextReplyID &+= 1
    pendingSeeks[id] = PendingSeek(generation: generation, completion: completion)
    let flags = exact ? "absolute+exact" : "absolute+keyframes"
    runCommandAsync(replyID: id, args: ["seek", "\(targetSeconds)", flags])
}

private func runCommandAsync(replyID: UInt64, args: [String]) {
    var cstrings = args.map { strdup($0) } + [UnsafeMutablePointer<CChar>?(nil)]
    defer { cstrings.forEach { if let p = $0 { free(p) } } }
    cstrings.withUnsafeMutableBufferPointer { buf in
        let p = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        _ = mpv_command_async(handle, replyID, p)
    }
}

/// Reads durations of every playlist entry. Used by skip() to drive
/// PlaylistSkipResolver. Falls back to currentDuration for the entry we're
/// in if mpv has no per-entry duration loaded yet for prefetched ones.
private func readPlaylistDurations() -> [Double] {
    var out: [Double] = []
    for i in 0..<playlistCount {
        let key = "playlist/\(i)/duration"
        var value: Double = 0
        let rc = key.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &value) }
        if rc >= 0, value.isFinite, value > 0 {
            out.append(value)
        } else if i == playlistPos {
            out.append(currentDuration)
        } else {
            // Unknown duration for a not-yet-loaded entry. Use a large
            // sentinel so skip math doesn't walk past it; in practice the
            // user would have to skip across an unloaded source which is
            // an edge case we can refine later.
            out.append(.infinity)
        }
    }
    return out
}
```

**Step 3: Build.**
```bash
./scripts/run.sh
```
Expected: clean build. Skip isn't yet wired to anything; nothing visible to test.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer in-file skip primitive"
```

---

### Task 3.7: Skip primitive — atomic cross-boundary `loadfile`

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Add the cross-boundary helper.**

```swift
private func loadFileReplaceAsync(
    playlistPos: Int,
    startSeconds: Double,
    completion: @escaping @MainActor () -> Void
) {
    // Read the path of the target playlist entry.
    let key = "playlist/\(playlistPos)/filename"
    var raw: UnsafeMutablePointer<CChar>?
    let rc = key.withCString { mpv_get_property(handle, $0, MPV_FORMAT_STRING, &raw) }
    guard rc >= 0, let raw else {
        // Couldn't resolve path — best we can do is jump via playlist-pos.
        let id = nextReplyID; nextReplyID &+= 1
        pendingSeeks[id] = PendingSeek(generation: generation, completion: completion)
        runCommandAsync(replyID: id, args: ["playlist-play-index", "\(playlistPos)"])
        return
    }
    let path = String(cString: raw)
    mpv_free(raw)

    let id = nextReplyID; nextReplyID &+= 1
    pendingSeeks[id] = PendingSeek(generation: generation, completion: completion)
    runCommandAsync(replyID: id, args: [
        "loadfile", path, "replace", "0", "start=\(startSeconds)"
    ])
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 3: Commit.**
```bash
git commit -am "feat(source-playback): MPVSourcePlayer cross-boundary loadfile-replace"
```

---

### Task 3.8: `MPV_EVENT_PLAYBACK_RESTART` completion dispatch

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift`

**Step 1: Extend the pump to handle command-reply + playback-restart.**

Above the `if id == MPV_EVENT_PROPERTY_CHANGE` block, add:

```swift
if id == MPV_EVENT_COMMAND_REPLY {
    // Command was acknowledged. The seek itself may not be settled yet —
    // we wait for PLAYBACK_RESTART for that. Errors on the reply are
    // logged but don't cancel the pending completion (mpv's seek-issued
    // error path is rare; if it happens the SkipCoordinator will time
    // out via its debounce naturally).
    if evt.pointee.error < 0 {
        let id = evt.pointee.reply_userdata
        Task { @MainActor [weak self] in
            // Drop the pending entry so a later spurious PLAYBACK_RESTART
            // doesn't fire it.
            self?.pendingSeeks.removeValue(forKey: id)
        }
    }
    continue
}
if id == MPV_EVENT_PLAYBACK_RESTART {
    // Settle: fire the most recent pending seek's completion. mpv only
    // emits one PLAYBACK_RESTART per seek/loadfile, so taking the
    // newest pending entry is correct.
    Task { @MainActor [weak self] in
        guard let self else { return }
        guard let (id, pending) = self.pendingSeeks
            .max(by: { $0.key < $1.key }) else { return }
        self.pendingSeeks.removeValue(forKey: id)
        // Generation guard (D12): drop completions for stale playlist
        // generations.
        guard pending.generation == self.generation else { return }
        pending.completion()
    }
    continue
}
```

**Step 2: Build.**
```bash
./scripts/run.sh
```
Expected: clean build.

**Step 3: Smoke (still no UI integration; just make sure the bring-up window still plays).**
Open Debug → MPV Bring-up Window → file plays.

**Step 4: Commit.**
```bash
git commit -am "feat(source-playback): seek-completion via MPV_EVENT_PLAYBACK_RESTART"
```

---

## Phase 4 — Workspace migration

### Task 4.1: `Workspace.sourcePlayer` field; delete `virtualPlayer`/`virtualComposition`

**Files:**
- Modify: `App/Models/Workspace.swift`

**Step 1: Replace the field declarations.**

In `Workspace`, replace lines 20–21:
```swift
var virtualPlayer: AVPlayer?
var virtualComposition: AVMutableComposition?
```
with:
```swift
/// Source-playback engine. Persistent (D2). Lazy-created on first
/// rebuildSourcePlayer that actually has resolved sources.
var sourcePlayer: MPVSourcePlayer?
```

Update lines 24–28's doc comment to reflect that `sourcePlayer` may be
nil while sources are missing:
```swift
/// Indices into `project.sourceVideos` whose bookmark failed to resolve
/// (file moved/renamed/deleted). Recomputed every `rebuildSourcePlayer`.
/// When non-empty, `sourcePlayer`'s playlist is intentionally cleared so
/// the UI can surface a Relink banner — playback would be confusing if
/// we played only the surviving sources, since clip `sourceIndex`es
/// would no longer line up with the concat.
var missingSourceIndices: Set<Int> = []
```

**Step 2: Don't compile yet — Tasks 4.2 and 4.3 fix the call sites.**

---

### Task 4.2: `rebuildVirtualPlayer` → `rebuildSourcePlayer`

**Files:**
- Modify: `App/Models/Workspace.swift`

**Step 1: Replace `rebuildVirtualPlayer`** (lines 84–135) with:

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
        // Clear the playlist but keep the handle alive (D2 — handle is
        // persistent so a successful relink doesn't pay init cost).
        sourcePlayer?.setPlaylist([])
        return
    }

    if sourcePlayer == nil {
        sourcePlayer = try MPVSourcePlayer()
    }
    sourcePlayer?.setPlaylist(resolved.map { $0.url.path })
    sourcePlayer?.setVolume(project.preferences.scanVolume)
}
```

**Step 2: Update every caller of `rebuildVirtualPlayer`.**

Search and replace:
```bash
grep -rn 'rebuildVirtualPlayer' App
```
Expected matches: a handful of `await rebuildVirtualPlayer()` in `openProject`, `addSourceVideo`, `removeSourceVideo`, `reorderSourceVideos`, `relinkSource`. Rename each to `rebuildSourcePlayer`.

**Step 3: Delete `sourceTime(at:)`** (lines 443–456 — the helper that walked cumulative durations to map a global concat time to `(sourceIndex, sourceLocalSeconds)`). Verify it has no other callers:
```bash
grep -rn 'sourceTime' App VideoCoachCore
```
Expected: only the one call in `ContentView.startRecording` at the line that reads the global player time. Task 4.3 rewrites that call site.

**Step 4: Don't build yet — `ContentView` still references `virtualPlayer`. Task 5.x lands those edits in one commit per call site.**

---

### Task 4.3: Update `startRecording` source-time read (in `ContentView`)

> Tasks 4.3+ live in `App/ContentView.swift`. Logically Phase 5 (UI wiring) but kept here so the Workspace migration and recording integration land together.

**Files:**
- Modify: `App/ContentView.swift`

**Step 1: Replace `startRecording`'s source-time capture.**

Find the block in `startRecording` (around line 632):
```swift
guard let player = workspace.virtualPlayer else { ... }
player.pause()
...
let global = player.currentTime().seconds
let mapped = workspace.sourceTime(at: global.isFinite ? global : 0)
pendingRecording = PendingRecording(
    clipID: clipID,
    filename: filename,
    sourceIndex: mapped.sourceIndex,
    startSourceSeconds: mapped.sourceLocalSeconds
)
```

Replace with:
```swift
guard let player = workspace.sourcePlayer else {
    recordingError = "Add a source video before recording."
    return
}
player.pause()
appMode = .recordingStarting

// One event-pump tick to flush pause / playlist-pos / time-pos events
// (the fields below are @Observable cached values, not synchronous mpv
// reads). Without this yield we may capture a pre-pause prefetch state.
await Task.yield()

pendingRecording = PendingRecording(
    clipID: clipID,
    filename: filename,
    sourceIndex: player.playlistPos,
    startSourceSeconds: player.timePos
)
```

> **Note:** `startRecording` is currently a synchronous function that spawns `Task { ... }`. The `await Task.yield()` lives inside that inner Task — i.e., move the `pause + yield + read pendingRecording` block into the existing `Task { ... }`'s prologue, keeping the synchronous function shape intact.

Reorganize `startRecording` to:
1. Synchronous: validate folder, build clipID/filename, set `appMode = .recordingStarting`, capture preferred camera/mic IDs.
2. Inside the `Task { ... }`: call `player.pause()`, `await Task.yield()`, read `(playlistPos, timePos)`, set `pendingRecording`, then proceed with the existing `prepareForRecording` / `startRecording` / clip-creation flow.

**Step 2: Don't build yet — `currentPlayer` still expects `AVPlayer?` at the top of ContentView. Task 5.4 fixes that.**

---

### Task 4.4: Commit Phase 4

This is one commit covering Tasks 4.1–4.3 because the project does not build between them.

**Step 1: Build + smoke.** After Task 5.x lands.

**Step 2: Commit (after the project builds again at the end of Phase 5):**
```bash
git commit -am "refactor(source-playback): Workspace.virtualPlayer → sourcePlayer; delete sourceTime(at:)"
```

> Phase 4 is logically a single-commit phase but its diff isn't compileable in isolation — it lands together with Phase 5 in one commit. Marking it as a separate phase here preserves the *logical* order in the plan even though the *git* history collapses it.

---

## Phase 5 — UI wiring

### Task 5.1: Drop the dead `player` parameter from `KeyCommandView`

**Files:**
- Modify: `App/Views/KeyCommandView.swift`

**Step 1: Delete the dead parameter.**

Replace the struct definition:
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

**Step 2: Update the call site in `ContentView`.**

Find the `KeyCommandView(...)` call (around line 245). Remove the `player: currentPlayer,` argument.

---

### Task 5.2: Split `PlayerSurface` — preview-only AVPlayer wrapper

**Files:**
- Modify: `App/Views/PlayerSurface.swift`

**Step 1: Rename the existing wrapper to `PreviewPlayerSurface`.**

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

> `PlayerSurface` (the type name) is not preserved — it's deleted and replaced by `PreviewPlayerSurface`. ContentView's call sites switch over in Task 5.4.

---

### Task 5.3: `TransportBar.ScanningTransport` — bind to `sourcePlayer`

**Files:**
- Modify: `App/Views/TransportBar.swift`

**Step 1: Replace the `ScanningTransport` body.**

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

    // openProjectFolder / addSourceVideo unchanged.
    // ...
}
```

> The two helper methods `openProjectFolder` and `addSourceVideo` at the bottom of the existing struct stay as-is.

---

### Task 5.4: `ContentView` — delete `currentPlayer`, install MPVPlayerView in scanning mode

**Files:**
- Modify: `App/ContentView.swift`

**Step 1: Delete `currentPlayer`** (lines 374–384) and `skipCoordinatorPlayerID` (line 18), and `coarseSeekInFlight` (line 23) is **kept** (still used by preview StrokeReplayLayer).

```swift
@State private var workspace = Workspace()
@State private var skipCoordinator = SkipCoordinator(burstWindowSeconds: 0.15)
@State private var skipDebounceTask: Task<Void, Never>?
/// True while a coarse (keyframe-tolerant) FF/RW seek is in flight.
/// StrokeReplayLayer reads this via the overlay representable and freezes
/// its periodic redraw so strokes don't flash to wrong positions during
/// the keyframe-decode window. Preview-mode only.
@State private var coarseSeekInFlight: Bool = false
@State private var selectedClipID: Clip.ID?
@State private var appMode: AppMode = .scanning
// ... rest unchanged
```

**Step 2: Replace the `PlayerSurface(...)` call sites in `mainSplit`.**

Find the player-surface ZStack (around line 220). Replace:
```swift
PlayerSurface(player: currentPlayer)
```
with:
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

`KeyCommandView(...)` no longer takes `player:`. Update its call accordingly (Task 5.1 covered the type; this is the call-site change).

---

### Task 5.5: `driveSkipDecision` helper + branch `handleSkip`

**Files:**
- Modify: `App/ContentView.swift`

**Step 1: Add the helper** below the existing `applySkipDecision` function (we replace `applySkipDecision`'s call sites and rewrite it to use the helper).

```swift
/// Shared control-flow for SkipCoordinator-driven skips (D1). Both
/// source-mode and preview-mode call this; the differences (player API,
/// coarseSeekInFlight visualization) live in the closures.
@MainActor
private func driveSkipDecision(
    _ decision: SkipDecision,
    generation: UInt64,
    issueSeek: @escaping (SeekParams, _ completion: @escaping @MainActor () -> Void) -> Void
) {
    if let s = decision.seek {
        issueSeek(s) { [self] in
            // Late-completion guard: drop if generation moved.
            guard generation == currentSkipGeneration() else { return }
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
            guard generation == currentSkipGeneration() else { return }
            let next = self.skipCoordinator.burstEnded(
                nowMonotonicSeconds: CACurrentMediaTime()
            )
            self.driveSkipDecision(next, generation: generation, issueSeek: issueSeek)
        }
    }
}

/// Returns the generation counter that's currently load-bearing for
/// stale-skip checks. For source mode this is sourcePlayer.generation;
/// for preview mode we maintain a separate counter that bumps on
/// selectedClipID change.
private func currentSkipGeneration() -> UInt64 {
    switch appMode {
    case .scanning, .recordingStarting, .recording:
        return workspace.sourcePlayer?.generation ?? 0
    case .previewClip, .previewLoading:
        return previewSkipGeneration
    }
}
```

Add a `@State` field:
```swift
/// Bumped on every selectedClipID change so a late preview-mode
/// completion can be dropped (D12 also covers the AVPlayer cache-hit
/// A→B→A bug previously documented at ContentView.swift:96-101).
@State private var previewSkipGeneration: UInt64 = 0
```

In the `.onChange(of: selectedClipID)` handler, bump it:
```swift
.onChange(of: selectedClipID) { _, _ in
    previewSkipGeneration &+= 1
    workspace.sourcePlayer?.bumpGeneration()
    resetSkipState()
}
```

**Step 2: Rewrite `handleSkip`.**

```swift
private func handleSkip(_ delta: Double) {
    if appMode == .recording { recordingController?.appendSkip(delta: delta) }
    let now = CACurrentMediaTime()

    switch appMode {
    case .scanning, .recordingStarting, .recording:
        guard let player = workspace.sourcePlayer else { return }
        let dur = player.currentDuration > 0 ? player.currentDuration : .greatestFiniteMagnitude
        let decision = skipCoordinator.requestSkip(
            deltaSeconds: delta,
            currentPlayerTimeSeconds: player.timePos,
            clipDurationSeconds: dur,
            nowMonotonicSeconds: now
        )
        let gen = player.generation
        driveSkipDecision(decision, generation: gen) { params, completion in
            // mpv path: skip() handles cross-boundary internally.
            player.skip(deltaSeconds: params.targetSeconds - player.timePos,
                        exact: params.exact,
                        completion: completion)
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
                    coarseSeekInFlight = false
                    completion()
                }
            }
        }

    case .previewLoading:
        return
    }
}
```

**Step 3: Delete the old `applySkipDecision` function** entirely (it's been replaced by the closure form passed into `driveSkipDecision`).

**Step 4: Adjust `resetSkipState` — drop `skipCoordinatorPlayerID`.**
```swift
private func resetSkipState() {
    skipDebounceTask?.cancel()
    skipDebounceTask = nil
    skipCoordinator.reset()
    coarseSeekInFlight = false
}
```

**Step 5: Adjust `handleClosePreview` — bump preview generation.**
```swift
private func handleClosePreview() {
    previewSkipGeneration &+= 1
    resetSkipState()
    workspace.previewPlayer(for: selectedClipID ?? UUID())?.pause()
    selectedClipID = nil
}
```

---

### Task 5.6: Rewrite `handleTogglePlay` for source mode

**Files:**
- Modify: `App/ContentView.swift`

**Step 1: Replace `handleTogglePlay`.**

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

---

### Task 5.7: Pause source on selection change

**Files:**
- Modify: `App/ContentView.swift`

**Step 1: Update `handleSelectionChange`.** Replace the early lines:
```swift
workspace.virtualPlayer?.pause()
```
with:
```swift
workspace.sourcePlayer?.pause()
```

(The rest of `handleSelectionChange` is unchanged.)

---

### Task 5.8: Build, smoke, commit Phase 4 + 5

**Step 1: Build.**
```bash
./scripts/run.sh
```
Expected: clean build. App launches.

**Step 2: Smoke test the verification checklist from the design.**

Walk through each checkbox in the design's "Verification checklist (manual smoke)" section. Record results.

- [ ] 4K test file plays smoothly, end-to-end (vs. previous commit).
- [ ] FF/RW key burst inside a single source: same UX as AVPlayer path.
- [ ] FF/RW key burst across a source boundary: lands in next file at correct local offset.
- [ ] Toggle play/pause via space and the transport bar button.
- [ ] Volume slider audibly changes source playback gain.
- [ ] R-press starts a recording; resulting clip's `sourceIndex` + `startSourceSeconds` are correct.
- [ ] Select clip → mpv pauses, preview takes over; close preview → mpv view returns, paused.
- [ ] Source bookmark stale (rename file externally) → Relink banner; mpv playlist cleared; relink restores playback.
- [ ] No crash / hang on app quit.
- [ ] Hardened-runtime entitlements (camera + mic) still pass.

**Step 3: Commit.**
```bash
git commit -am "refactor(source-playback): wire MPVSourcePlayer through ContentView/TransportBar/PlayerSurface

Replaces AVPlayer source-playback with MPVSourcePlayer behind no
abstraction (D1). Adds driveSkipDecision control-flow helper shared by
source and preview paths. Drops sourceTime(at:), virtualComposition,
currentPlayer, skipCoordinatorPlayerID, KeyCommandView's dead player
parameter. Generation counter (D12) replaces ObjectIdentifier guards."
```

---

## Phase 6 — Adversarial implementation review

The design has already had two adversarial review passes folded in. The implementation should also get a review before merging.

### Task 6.1: Run two parallel review passes on the implementation diff

**Step 1: Stack the implementation commits and produce a diff.**
```bash
git log --oneline origin/main..HEAD -- App/Source App/Views/MPVPlayerView.swift App/Views/MPVDebugWindow.swift App/Views/PlayerSurface.swift App/Views/TransportBar.swift App/Views/KeyCommandView.swift App/Models/Workspace.swift App/ContentView.swift App/VideoCoach.entitlements project.yml VideoCoachCore/Sources/VideoCoachCore/PlaylistSkipResolver.swift VideoCoachCore/Tests/VideoCoachCoreTests/PlaylistSkipResolverTests.swift
```

**Step 2: Spawn two reviewer subagents in parallel** — `feature-dev:code-reviewer` and `superpowers:code-reviewer`. Their prompts should ask them to find issues in the implementation, not the design (which they've already reviewed).

**Step 3: Fold findings.** Same pattern as the previous plan (`docs/plans/2026-04-29-preview-perf-skip-coalesce-and-gpu-compositor.md` Phase 4): apply fixes inline, document them in this plan's commit messages.

**Step 4: Final smoke + merge prep.** Walk the verification checklist a final time after all review fixes land.

---

## Verification checklist (post-execution)

- [ ] `cd VideoCoachCore && swift test` — all tests pass (PlaylistSkipResolver suite + existing SkipCoordinator suite + existing PreviewCompositor suite).
- [ ] `./scripts/run.sh` — app builds clean, launches without dyld errors.
- [ ] Phase 1 gate items (a)–(f) all PASS — recorded in Task 1.3's commit message.
- [ ] 4K test file (`/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4`) plays smoothly end-to-end as source. Compare against the pre-swap commit.
- [ ] FF/RW (D / right arrow / shift+D / shift+right arrow / and reverse with A / left arrow) responds correctly during a burst, settles to exact frame ~150ms after release.
- [ ] FF/RW that crosses a source boundary lands in the next/previous file at the correct local offset.
- [ ] Space toggles play/pause; volume slider audibly affects source playback.
- [ ] R-press records a clip whose `(sourceIndex, startSourceSeconds)` matches the displayed frame at R-press (verify by previewing the recorded clip and visually confirming the source frame).
- [ ] Esc / Source button closes a preview; mpv view returns paused.
- [ ] A → B → A clip-selection round-trip: each new skip on the second visit issues a real seek (no silent first-keypress drop).
- [ ] Sidebar source-rename / Relink flow works with the persistent mpv handle.
- [ ] No crash on app quit; mpv handle terminates cleanly.

---

## Phase 1 outcome → Phase 3.1 hwdec value

Task 3.1 hardcodes `MPVSourcePlayer.hwdecOption = "videotoolbox"`. If Phase 1's Task 1.3 picked `hwdec=no` instead, change the constant accordingly **before** running Task 3.1. The Phase 1 commit message records the chosen value as the source of truth.
