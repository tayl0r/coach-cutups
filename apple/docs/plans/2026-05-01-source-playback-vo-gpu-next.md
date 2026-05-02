# Source-Playback Path B: vo=gpu-next + per-mount mpv_handle Implementation Plan (v2)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the GL+IOSurface→Metal bridge (just-shipped Path A) with mpv's `vo=gpu-next` + `wid=<CAMetalLayer*>` embed, so mpv renders directly via Metal (libplacebo → Vulkan → MoltenVK → Metal) into a `CAMetalLayer` we own. Eliminates ~300 lines of bridge code, all GL deprecation warnings, the bridging-header dance, and the `CVDisplayLink` we currently drive ourselves.

**Architectural pivot (v1 → v2):** v1 assumed the persistent `mpv_handle` from the original migration's D2 architecture would survive across view mount/unmount cycles by repointing `wid`. Adversarial review found this is **impossible via public mpv API**: `mpv_set_option` is documented pre-init-only, and `window-id` is registered as `m_property_int64_ro` (read-only) at the property level. Path B and the persistent-handle architecture are mutually exclusive.

v2 commits to **handle-recreation per mount**: `MPVSourcePlayer.init` no longer creates the mpv handle; the handle is created lazily on `attachLayer(_:)` (with `wid` set BEFORE `mpv_initialize`), and torn down on `detachLayer()`. Swift-side state (playlist paths, current position, paused/playing) replays onto the fresh handle each attach. Real unmounts in this app's flow (workspace switch, window close+reopen, relink) already involve user-perceived latency, so the 1–2s of black during state replay is acceptable.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI, libmpv via MPVKit (`Libmpv` module + bundled `MoltenVK.xcframework`), Metal, CAMetalLayer.

**Companion documents:**
- `docs/plans/2026-05-01-source-playback-mpv-migration-design.md` — original mpv-migration design (D2 persistent-handle rationale, D6 hwdec).
- `docs/plans/2026-05-01-source-playback-mpv-migration.md` — executed migration plan (Phase 3.5 render-context lifecycle, click-handling fix `3ab22aa`, the event-pump architecture this plan reuses).
- `docs/plans/2026-05-01-source-playback-metal-render-swap.md` — the just-shipped Path A. **This plan REPLACES Path A's runtime; the SW fallback and the entire `MPVRenderBackend` enum also go away.**
- `~/Library/Developer/Xcode/DerivedData/VideoCoach-aldlfihezaflyucqutmrgkalqixu/SourcePackages/checkouts/MPVKit/Demo/Demo-macOS/Demo-macOS/Player/Metal/` — **the working reference implementation.** `MPVMetalViewController.swift` and `MetalLayer.swift` are the load-bearing files.

**Branch:** `feat/source-playback-metal-direct` (off `feat/impl-phases-1-4-9` at `146a085`).

**Test commands:**
- `xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels` — pixel-content gate (existing).
- `xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' -only-testing:VideoCoachUITests/MPVMountRemountTests/testRemountResumesPlayback` — **NEW** mount/unmount cycle gate (added in Phase 4).

---

## Adversarial review history (plan v1 → v2)

The first draft was reviewed by `feature-dev:code-reviewer`. Findings folded into v2 (this document) before any execution:

| Finding | Where it lives now |
|---------|-------------------|
| **`mpv_set_option(handle, "wid", ...)` is pre-init-only and `mpv_set_property` rejects `wid` (registered as `m_property_int64_ro` in `command.c`).** v1's persistent-handle + repoint-`wid` architecture is impossible via public mpv API. | **Phase 2 (entire phase rewritten).** `MPVSourcePlayer.init` no longer creates the mpv handle. `attachLayer(_:)` creates a fresh handle, sets `wid` *before* `mpv_initialize`, replays cached Swift-side state onto the new handle. `detachLayer()` calls `mpv_terminate_destroy` and clears the handle. The persistent-handle D2 optimization is consciously abandoned for this path; rationale documented in the file header (Phase 6). |
| **`detachLayer()` marked `nonisolated` accessing `handle` is a Swift 5.9 strict-concurrency compile error** (handle is `fileprivate let` on a `@MainActor` class). | Phase 2 — `handle` becomes `private nonisolated(unsafe) var handle: OpaquePointer?` with the same comment pattern the live code uses for `renderContext`. Comment cites `client.h`'s thread-safety guarantees on the mpv handle. |
| **`MPVMetalLayer.wantsExtendedDynamicRangeContent` setter using `DispatchQueue.main.sync` from mpv's render thread can deadlock** if main is in a synchronous mpv API call. | Phase 1 — setter uses `DispatchQueue.main.async` instead. Value write is idempotent; no return value to deliver. Deviation from MPVKit demo noted in the source comment. |
| **Phase 2 + 3 split shipped a non-compileable middle commit** — repeating the anti-pattern the original migration plan's review flagged. | v2 — Phase 2 includes the full `MPVSourcePlayer` rewrite *and* the `MPVRenderingNSView` surgery as a single atomic commit. The diff is large but the tree is never broken. Phase 3 (renumbered, formerly Phase 5) is the cleanup. |
| **`Unmanaged.passUnretained(layer).toOpaque()` for `wid` does not retain — layer could be released before mpv finishes drawing.** | Phase 2 — `MPVSourcePlayer` adds `private var attachedLayer: CAMetalLayer?` set in `attachLayer`, cleared in `detachLayer` *after* `mpv_terminate_destroy` returns. Strong reference is explicit on the player side, independent of which Swift owner happens to retain the layer. |
| **`framebufferOnly = false` audit not performed** — switching to `true` is safe only if no other code reads the source-playback drawable. | Phase 2 — explicit grep audit step before the change. The `GLMetalBridge.present` was the only known reader; deleted in Phase 3. |
| **No automated test for the mount/unmount cycle** — Phase 4 has only manual smoke for the load-bearing assumption that handle recreation correctly replays state. | Phase 4 — adds `MPVMountRemountTests/testRemountResumesPlayback` XCUITest that opens the bring-up window, captures position, closes the window, reopens it, captures position again, asserts playback resumed (not stuck at frame 0). Specific assertions in Task 4.2. |
| **MoltenVK presence in MPVKit's bundled artifacts not explicitly confirmed in the plan.** | Phase 0 — adds Task 0.0 "Confirm MoltenVK.xcframework is present" as a 30-second pre-flight check before the spike. |

---

## Phase 0 — Confirm gpu-next playback works in isolation

The biggest unknown is whether `vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk` + `wid=<CAMetalLayer*>` actually plays our 4K HEVC fixture on this hardware. Before we delete any production code, prove it.

### Task 0.0: Confirm MoltenVK.xcframework is bundled

**Files:** read-only.

**Step 1:** Run:

```bash
ls /Users/taylor/Library/Developer/Xcode/DerivedData/VideoCoach-aldlfihezaflyucqutmrgkalqixu/SourcePackages/artifacts/mpvkit/MoltenVK/
```
Expected: a directory exists, containing `MoltenVK.xcframework`. If it's missing, MPVKit was vended without MoltenVK and `gpu-context=moltenvk` will silently fall through to mpv's auto-detection — escalate before continuing.

Record outcome in the report. **Commit nothing.**

### Task 0.1: Spike — minimal MPVMetalDemo view (throwaway)

**Files:**
- Create: `App/Source/_MPVMetalSpike.swift` (TEMPORARY, deleted at end of Task 0.1)
- Modify: `App/VideoCoachApp.swift` to add a `Window("MPV Metal Spike", id: "mpv-metal-spike") { ... }` scene + a Debug-menu entry. Reverted in Step 4.

**Step 1: Copy the MPVKit demo's `MPVMetalViewController` pattern into `_MPVMetalSpike.swift`** as a single-file SwiftUI representable. Hardcode the fixture path `/tmp/mpv-test-fixture.mp4`. The reference is at `~/Library/Developer/Xcode/DerivedData/VideoCoach-aldlfihezaflyucqutmrgkalqixu/SourcePackages/checkouts/MPVKit/Demo/Demo-macOS/Demo-macOS/Player/Metal/MPVMetalViewController.swift`. Strip parts we don't need for the spike (MPVPlayerDelegate, HDR observers, command/error helpers); keep the load-bearing options:

```swift
mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer)
mpv_set_option_string(mpv, "vo", "gpu-next")
mpv_set_option_string(mpv, "gpu-api", "vulkan")
mpv_set_option_string(mpv, "gpu-context", "moltenvk")
mpv_set_option_string(mpv, "hwdec", "videotoolbox")
mpv_set_option_string(mpv, "ao", "null")  // don't fight production CoreAudio
```

Inline a quick-and-dirty `CAMetalLayer` subclass that filters 1×1 drawableSize (the MoltenVK workaround). EDR can be skipped for the spike.

The view's NSView sets `view.layer = metalLayer` and `wantsLayer = true`. `viewDidLayout` updates `metalLayer.frame` and `drawableSize` based on `window.screen.backingScaleFactor`.

**Step 2: Wire** the spike into the Debug menu and a Window scene exactly like the existing GL Bridge Demo (`gl-bridge-demo`) entry — same pattern.

**Step 3: Build + open Debug → MPV Metal Spike.** Expected: the fixture's first second of video plays. Visually verify (the implementer should `screencapture` the window to a path under `/tmp/` and `Read` the image): not flipped, not garbled, audio silent.

If the window stays black: enable `mpv_request_log_messages(mpv, "debug")` and capture the log. Common failure: HDR mode kicks in and Metal API validation crashes — disable Metal API validation in the scheme as the demo's comment recommends. Less common: `gpu-context=moltenvk` falls through silently — Task 0.0 catches this case ahead of time.

**Step 4: Revert wiring + delete the spike file.** Commit nothing — this phase is a gate, not delivered code.

If the gate fails (video doesn't play after a reasonable debug pass), STOP and report. Do NOT proceed — the rest of the plan assumes gpu-next playback works.

---

## Phase 1 — Add the MPVMetalLayer subclass

### Task 1.1: Create `App/Source/MPVMetalLayer.swift`

**Files:**
- Create: `App/Source/MPVMetalLayer.swift`

**Step 1:** Write:

```swift
// App/Source/MPVMetalLayer.swift
import Foundation
import AppKit

/// CAMetalLayer subclass for libmpv's vo=gpu-next + gpu-context=moltenvk path.
/// Two workarounds adapted from MPVKit's official Metal demo:
///
/// 1. drawableSize setter filters out 1×1 — MoltenVK sometimes sets the
///    drawableSize to 1×1 during its presentation completion path, which
///    causes flicker and can leave the layer permanently at 1×1.
///    https://github.com/mpv-player/mpv/pull/13651
///
/// 2. wantsExtendedDynamicRangeContent setter trampolines onto the main
///    thread because activating screen EDR mode only works from the main
///    thread; mpv's render thread will set this from the wrong queue.
///    Uses DispatchQueue.main.async (NOT .sync as in the demo) — .sync can
///    deadlock if main is mid-`mpv_*` API call when the render thread sets
///    EDR. Value write is idempotent; no return needed.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}
```

**Step 2: Build.**

```bash
xcodegen generate
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```
Expected: clean build. The class is unreferenced; just verifies compilation.

**Step 3: Commit.**

```bash
git add App/Source/MPVMetalLayer.swift project.yml
git commit -m "feat(render): add MPVMetalLayer subclass for vo=gpu-next embed"
```

---

## Phase 2 — Atomic refactor: MPVSourcePlayer + MPVRenderingNSView

This is the single largest commit in the plan. The whole switch from "persistent handle + render-context attach" to "per-mount handle + layer attach" is here. Tree is never non-compileable.

### Task 2.1: Atomic refactor

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift` (major rewrite)
- Modify: `App/Views/MPVPlayerView.swift` (large simplification)

**Step 1: Rewrite `MPVSourcePlayer` storage and lifecycle.**

The handle is no longer created in `init`. It's created in `attachLayer(_:)` and torn down in `detachLayer()`. The Swift object survives across attach cycles; only the C handle is recreated.

Storage changes:
- `private nonisolated(unsafe) var handle: OpaquePointer?` (was `fileprivate let handle: OpaquePointer`). Comment: "nonisolated(unsafe) because the event-pump and detachLayer access the handle off-main; mpv's C API on a single handle is documented thread-safe in client.h. nil between detach and re-attach."
- `private var attachedLayer: CAMetalLayer?` — strong reference to the layer that's currently embedded. Set on `attachLayer`, cleared *after* `mpv_terminate_destroy` returns in `detachLayer`. Ensures the layer's lifetime is bounded by mpv's use.
- `private let audioOff: Bool` — moved from constructor parameter into stored property so each fresh handle gets the same audio config.
- `private var pumpThread: Thread?` — already there; reset on each attach.
- `renderContext`, `renderLock` — **deleted**.

Cached state (already present, used for replay):
- `playlistPaths: [String]` — already cached.
- `playlistPos: Int`, `timePos: Double`, `isPaused: Bool` — already observed via the event pump.
- `generation: UInt64` — already incremented on `setPlaylist`/`bumpGeneration`.
- `pending: PendingSeek?` — dropped on detach (call `dropPending()`).

**Step 2: Refactor `init`.**

```swift
public init(audioOff: Bool = false) {
    self.audioOff = audioOff
    // Handle is created lazily in attachLayer. This makes the player Swift-side
    // construct cheap and aligns lifecycle with the layer it draws into.
}
```

The constructor no longer throws — it can't fail because nothing happens.

**Step 3: Add `attachLayer(_ layer: CAMetalLayer)`.**

```swift
public func attachLayer(_ layer: CAMetalLayer) throws {
    precondition(handle == nil, "attachLayer called twice without intervening detachLayer")

    guard let h = mpv_create() else { throw MPVSourcePlayerError.createFailed }

    // wid MUST be set before mpv_initialize. The MPV_FORMAT_INT64 value is
    // the integer reinterpretation of an unretained pointer to the layer.
    // attachedLayer holds the strong reference for the duration of this attach.
    var wid: Int64 = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)

    for (k, v) in [
        ("vo", "gpu-next"),
        ("gpu-api", "vulkan"),
        ("gpu-context", "moltenvk"),
        ("hwdec", Self.hwdecOption),
        ("prefetch-playlist", "yes"),
        ("keep-open", "yes"),
        ("keep-open-pause", "yes"),
        ("pause", "yes"),
        ("msg-level", "all=warn"),
        ("audio-display", "no"),
        ("osc", "no"),
        ("osd-level", "0"),
        ("target-colorspace-hint", "yes"),
    ] {
        mpv_set_option_string(h, k, v)
    }
    if audioOff {
        mpv_set_option_string(h, "ao", "null")
    }

    let rc = mpv_initialize(h)
    guard rc >= 0 else {
        mpv_destroy(h)
        throw MPVSourcePlayerError.initializeFailed(code: Int(rc))
    }

    self.handle = h
    self.attachedLayer = layer

    // Replay observed properties — same set as the original init.
    mpv_observe_property(h, 1, "pause",          MPV_FORMAT_FLAG)
    mpv_observe_property(h, 2, "playlist-count", MPV_FORMAT_INT64)
    mpv_observe_property(h, 3, "playlist-pos",   MPV_FORMAT_INT64)
    mpv_observe_property(h, 4, "time-pos",       MPV_FORMAT_DOUBLE)

    startEventPump()

    // Replay Swift-side state onto the fresh handle.
    if !playlistPaths.isEmpty {
        runCommandSync(["loadfile", playlistPaths[0], "replace"])
        for p in playlistPaths.dropFirst() {
            runCommandSync(["loadfile", p, "append"])
        }
        // Restore position.
        if playlistPos > 0 && playlistPos < playlistPaths.count {
            runCommandSync(["playlist-play-index", String(playlistPos)])
        }
        if timePos > 0 {
            // Use loadfile-with-start would have been simpler at first-load
            // time, but at replay time we need an explicit seek because the
            // loadfile already happened above.
            runCommandSync(["seek", String(timePos), "absolute+keyframes"])
        }
        // Restore paused state — default of paused=yes was set at handle init,
        // so only un-pause if we were playing.
        if !isPaused {
            var flag: Int32 = 0
            mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag)
        }
    }
}
```

> **Replay ordering note:** `mpv_initialize` runs with `pause=yes` so video doesn't start before our state replay finishes. After replay, we explicitly unpause if `isPaused == false`. This avoids a 0–1 frame flash of "from-the-top" content while we seek to `timePos`.

**Step 4: Add `detachLayer()`.**

```swift
public nonisolated func detachLayer() {
    guard let h = handle else { return }
    self.handle = nil  // event pump exits when wait_event returns SHUTDOWN

    // Drop any pending strdup'd argv from in-flight async commands.
    DispatchQueue.main.sync { [weak self] in
        MainActor.assumeIsolated { self?.dropPending() }
    }

    mpv_set_wakeup_callback(h, nil, nil)
    mpv_terminate_destroy(h)

    // Wait for the event pump to exit cleanly. terminate_destroy makes
    // mpv_wait_event return MPV_EVENT_SHUTDOWN; the pump's loop checks
    // for that and returns.
    pumpThread?.cancel()  // best-effort wake; the SHUTDOWN event also wakes it
    pumpThread = nil

    // Clear the layer reference AFTER mpv is fully torn down. mpv may have
    // still been holding the layer's underlying VkSurfaceKHR until terminate
    // returned; releasing the layer earlier could free the IOSurface
    // mpv's MoltenVK context was sampling.
    DispatchQueue.main.sync { [weak self] in
        MainActor.assumeIsolated { self?.attachedLayer = nil }
    }
}
```

> **Why the `DispatchQueue.main.sync`-trampolines:** `detachLayer` is `nonisolated` because `deinit` (which is always nonisolated) calls it. Updating `@MainActor` properties (`pending`, `attachedLayer`) from a nonisolated context requires a hop. `.sync` is fine here because we're not waiting on mpv's render thread — we're waiting on main, which is doing its own work but won't block forever on us.

**Step 5: Refactor `setPlaylist`, `play`, `pause`, `togglePlay`, `setVolume`, `seek`.**

All of these need to guard on `handle != nil` and do the right thing when the handle is detached:
- `setPlaylist(_:)` — update `playlistPaths` + `bumpGeneration` always; if `handle != nil`, also issue the loadfile commands. If detached, state replays on next `attachLayer`.
- `play` / `pause` / `togglePlay` — update `isPaused` always; if `handle != nil`, also issue the property write. If detached, state replays on next attach.
- `setVolume(_:)` — store in a new `private var volume: Double = 1.0` field; replay on attach. If `handle != nil`, also issue the property write.
- `seek(...)` — if `handle == nil`, fire completion immediately (defensive — no in-flight seek across detach). If `handle != nil`, current behavior.

This makes the player "headless" between detach and reattach — a `setPlaylist` from `Workspace` while no view is mounted updates Swift-side state, and the next attach replays.

**Step 6: Refactor `bumpGeneration`, `dropPending`, `runCommandSync`, `issueAsync`.**

These all need to guard on `handle != nil`. `runCommandSync` becomes a no-op if detached (state replay handles it); `issueAsync` for `seek` already gated by `seek`'s top-level check.

**Step 7: Refactor `deinit`.**

```swift
deinit {
    detachLayer()  // idempotent if already detached
}
```

**Step 8: Refactor `MPVSourcePlayerError`.**

Drop `alreadyAttached` and `renderContextFailed(code:)`. Keep `createFailed` and `initializeFailed(code:)`.

**Step 9: Rewrite `MPVRenderingNSView`.**

Storage changes:
- `private let metalLayer = MPVMetalLayer()` (was `CAMetalLayer()`)
- Delete: `device`, `commandQueue`, `displayLink`, `bridge`, `backend`.
- `framebufferOnly` setting goes to `true`.
- `init(frame: NSRect)` no longer takes a `backend:` parameter (the enum is gone).

Lifecycle:
- `bringUp(filePath:hwdec:)` — creates an `MPVSourcePlayer(audioOff: true)`, calls `try p.attachLayer(metalLayer)`, then `p.setPlaylist([filePath])`, then `p.play()`.
- `attach(player:)` — `try player.attachLayer(metalLayer)`. (The "shared player" path.)
- `updatePlayer(_:)` — on identity change, `sharedPlayer?.detachLayer()`, set sharedPlayer = nil, then `try newPlayer.attachLayer(metalLayer)`. The do/catch wraps the throws.
- `tearDown()` — `ownedPlayer?.detachLayer(); ownedPlayer = nil` or `sharedPlayer?.detachLayer(); sharedPlayer = nil`. No CVDisplayLink to stop, no bridge to nil.

Size tracking:
- Keep `setFrameSize`, `viewDidChangeBackingProperties`, `viewDidMoveToWindow` overrides.
- `updateDrawableSize()` body unchanged (sets `metalLayer.drawableSize` based on `bounds * backingScaleFactor`).
- Set `view.layer = metalLayer` and `wantsLayer = true` in `init(frame:)` exactly like Path A's `MPVRenderingNSView` — that's the right pattern; don't replicate the demo's `view.layer = metalLayer; view.wantsLayer = true` in viewDidLoad ordering.

Click handling:
- `acceptsFirstResponder` → still true.
- `mouseDown(with:)` → still `window?.makeFirstResponder(self)` then `super.mouseDown(with:)`. The view is the click target; mpv only owns the layer's backing surface.

**Step 10: Delete from `MPVPlayerView.swift`** at file scope:
- `enum MPVRenderBackend` and the `static var production` getter.
- `private let mpvGetProcAddress` `@convention(c)` closure.
- The `import Libmpv` if it's now unused (likely still needed for `MPVSourcePlayerError`).

**Step 11: framebufferOnly audit.**

Before flipping to `framebufferOnly = true`, run:

```bash
grep -rn 'framebufferOnly\|drawable.texture' /Users/taylor/dev/coach-cutups-2/App /Users/taylor/dev/coach-cutups-2/Tests 2>/dev/null
```

Expected matches: only inside `App/Source/GLMetalBridge.swift` (which Phase 3 deletes), and the `framebufferOnly` line in `MPVPlayerView.swift` itself. Record the grep output in the commit message. If unexpected matches show up (e.g. a thumbnail extractor), STOP and report — those callers need separate handling.

**Step 12: Build + run XCUITest.**

```bash
xcodegen generate
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVBringUpWindowTests/testBringUpWindowOpensAndRendersPixels
```
Expected: build green, test PASS, `/tmp/xcui-mpv-bringup.png` shows correct video frames (right-side-up, fixture content). The implementer should `Read` the PNG to visually confirm.

If the bring-up window is black: enable `msg-level=all=info` temporarily and capture mpv's log; common failure is the gpu-next VO failing silently because of an option mismatch. Less common: the layer isn't sized when `wid` is set; the order matters. The implementer should compare against Phase 0.1's working spike to find the deviation.

**Step 13: Commit.**

```bash
git add App/Source/MPVSourcePlayer.swift App/Views/MPVPlayerView.swift
git commit -m "refactor(source-playback): vo=gpu-next + per-mount mpv_handle (Path B)

MPVSourcePlayer no longer creates the mpv handle in init; attachLayer
creates a fresh handle with wid set before mpv_initialize, replays
Swift-side state (playlist, position, paused), and starts the event
pump. detachLayer terminates the handle and clears the layer ref.
This abandons the persistent-handle D2 optimization for this path
because mpv's wid option/property is pre-init-only — see plan v2
review history for the rationale.

MPVRenderingNSView is simplified: no CVDisplayLink, no MTLDevice cache,
no command queue, no bridge, no backend enum. The view owns an
MPVMetalLayer (CAMetalLayer subclass with MoltenVK workarounds).
mpv writes pixels directly via libplacebo → Vulkan → MoltenVK → Metal.

framebufferOnly audit: only reader was GLMetalBridge.present; deleted in
the next commit. No other callers reference the source-playback
drawable's texture."
```

---

## Phase 3 — Delete the GL bridge

Only after Phase 2's XCUITest is green.

### Task 3.1: Remove GL+IOSurface code

**Files to delete:**
- `App/Source/GLMetalBridge.swift`
- `App/Source/CGLBridge.h`
- `App/VideoCoach-Bridging-Header.h`
- `App/Views/GLBridgeDemoView.swift`
- `Tests/AppTests/GLMetalBridgeTests.swift`
- `Tests/AppTests/GLMetalBridgeRenderTests.swift`

**Files to modify:**
- `project.yml`:
  - Remove `SWIFT_OBJC_BRIDGING_HEADER` from both `VideoCoach` and `VideoCoachTests` target settings.
  - Keep the `VideoCoachTests` target itself (Phase 4 adds tests there); leave `sources: [Tests/AppTests]` even if the directory becomes empty.
- `App/VideoCoachApp.swift`:
  - Remove `Window("GL Bridge Demo", id: "gl-bridge-demo") { ... }`.
  - Remove the `Button("GL Bridge Demo (Red)")` Debug-menu entry.
  - Remove the entire `Render Backend` submenu (no backend choice anymore).
  - Remove `@AppStorage(MPVRenderBackend.userDefaultsKey)` line (the enum is already gone from Phase 2).

**Step 1: Delete files + edits.**

**Step 2: Build.**

```bash
xcodegen generate
xcodebuild build -scheme VideoCoach -destination 'platform=macOS,arch=arm64'
```
Expected: green.

**Step 3: Run XCUITest.** Bring-up window should still pass.

**Step 4: Commit.**

```bash
git add -A
git commit -m "chore(render): delete GL+IOSurface bridge (replaced by vo=gpu-next)

Removes GLMetalBridge, CGLBridge.h, the bridging header, the
GLBridgeDemo fixture, the MPVRenderBackend enum, the Debug-menu
render-backend toggle, and the two GLMetalBridge unit tests. The
VideoCoachTests target stays in project.yml (empty sources dir);
Phase 4 adds the mount/unmount integration test there."
```

---

## Phase 4 — Verification

### Task 4.1: Production smoke + first-responder regression

**Step 1: Launch via `./scripts/run.sh`.** Auto-load opens the user's project. Confirm:
- Source video plays (right-side-up, no flicker, no black).
- JKL scrub works.
- Click in player → click TextField → click in player again → focus returns.
- Pause/resume responsive.

**Step 2: Capture sustained CPU%.** 60s of 4K HEVC playback in Activity Monitor. Record in the plan's "Baseline measurements" section. Compare against Path A's baseline (from `feat/impl-phases-1-4-9` history). Path B should be ≈ Path A or modestly better.

### Task 4.2: Mount/remount XCUITest

**Files:**
- Create: `AppUITests/MPVMountRemountTests.swift`

**Step 1: Write the test.**

```swift
import XCTest

final class MPVMountRemountTests: XCTestCase {
    func testRemountResumesPlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VIDEOCOACH_TEST_FIXTURE"] = "/tmp/mpv-test-fixture.mp4"
        app.launch()

        // Open bring-up window (mounts MPVRenderingNSView, attaches layer to mpv).
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open MPV Bring-up Window"].click()

        let bringUp = app.windows["MPV Bring-up"]
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5))

        // Let it play for 2s, then capture a screenshot of the player area.
        Thread.sleep(forTimeInterval: 2.0)
        let firstShot = bringUp.screenshot()
        firstShot.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-mount-remount-1.png"),
            atomically: true, options: []
        )

        // Close the bring-up window — view leaves window, MPVRenderingNSView's
        // viewWillMove(toWindow: nil) calls tearDown which detachLayer's.
        bringUp.buttons[XCUIIdentifierCloseWindow].click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(bringUp.exists)

        // Reopen — fresh MPVRenderingNSView, fresh mpv_handle, layer
        // reattached. The owned-player path constructs a brand-new
        // MPVSourcePlayer for the bring-up window, so this test specifically
        // exercises the "fresh player + attach + play" case rather than
        // the "shared persistent player + reattach" production case.
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open MPV Bring-up Window"].click()
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.0)

        let secondShot = bringUp.screenshot()
        secondShot.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-mount-remount-2.png"),
            atomically: true, options: []
        )

        // Pixel-content assertion: both screenshots must contain non-black
        // pixels in the player region (i.e., video is rendering, not stuck).
        // The brittle alternative would be exact-match — we don't know the
        // playback position post-remount, so non-black-in-region is what we
        // assert.
        XCTAssertTrue(hasNonBlackPixels(in: firstShot, region: bringUpVideoRect()),
                      "First mount: no video pixels in player area")
        XCTAssertTrue(hasNonBlackPixels(in: secondShot, region: bringUpVideoRect()),
                      "Remount: no video pixels in player area — possible attachLayer / state-replay regression")
    }

    private func bringUpVideoRect() -> CGRect {
        // Approximate; the bring-up window's exact layout is in MPVDebugWindow.swift.
        // The video occupies most of the window minus the controls strip at top.
        return CGRect(x: 50, y: 100, width: 700, height: 400)
    }

    private func hasNonBlackPixels(in screenshot: XCUIScreenshot, region: CGRect) -> Bool {
        // Sample N pixels in the region; require at least one channel > 16
        // on at least one pixel. Black-frame-detection threshold per ITU-R.
        guard let cg = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        // Implementation left to the implementer — sample 10 pixels in the
        // region using a CGContext readback. Return true if any non-black.
        // …
    }
}
```

The test as written is an outline — the implementer fills in the `hasNonBlackPixels` body using `CGContext`/`CGImage` pixel sampling. The assertion is intentionally lenient (any non-black pixel) because the second mount may be at a different playback position.

> **Why this test is load-bearing:** the entire architectural pivot in Phase 2 hinges on "handle recreation correctly resumes playback." If the second screenshot is all-black, either (a) the fresh mpv_handle isn't picking up the layer, (b) the state replay didn't run, or (c) the event pump is wedged. Any of these would also break production but might escape `testBringUpWindowOpensAndRendersPixels` because that test only opens the window once.

**Step 2: Build + run.**

```bash
xcodebuild test -scheme VideoCoach -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoCoachUITests/MPVMountRemountTests/testRemountResumesPlayback
```

If the macOS 26 automation-consent gate blocks: skip the test, run the manual equivalent (open bring-up → close → reopen → eyeball). This was acceptable for Path A's Phase 3.2; same precedent here.

**Step 3: Commit.**

```bash
git add AppUITests/MPVMountRemountTests.swift project.yml
git commit -m "test(render): mount/remount XCUITest for vo=gpu-next handle lifecycle"
```

### Task 4.3: 4K HEVC stress test

**Step 1: Manual.** Play a 4K HEVC source for 5 minutes; watch dropped frames + thermal in Activity Monitor. Record results.

If stutter persists: capture mpv's log with `msg-level=all=info` for 10s of playback and inspect for `vo:` warnings or `decoder:` issues. The gpu-next VO has its own diagnostics that the previous render-context path didn't surface.

---

## Phase 5 — History note

### Task 5.1: Top-of-file comment in MPVSourcePlayer

**Files:**
- Modify: `App/Source/MPVSourcePlayer.swift` — add at top.

```swift
// Render path history:
//   Phase 1 of mpv migration: vo=libmpv + MPV_RENDER_API_TYPE_SW
//     (per-frame CPU staging copy; intentional bring-up choice).
//   Phase 7: vo=libmpv + MPV_RENDER_API_TYPE_OPENGL bridged via IOSurface
//     to a Metal layer (Path A). Eliminated CPU staging copy but pulled
//     in deprecated GL APIs. Persistent mpv handle survived view mount/
//     unmount cycles via attachRenderGL/detachRenderGL.
//   Phase 8 (current): vo=gpu-next + wid=<CAMetalLayer*> (Path B). mpv
//     renders directly via libplacebo → Vulkan → MoltenVK → Metal into a
//     layer we own. The mpv_handle is created on attachLayer (with wid
//     set before mpv_initialize) and torn down on detachLayer; persistent-
//     handle is not possible because mpv's wid option/property is read-
//     only at runtime (verified in plan v2 review). Swift-side fields
//     (playlist paths, position, paused) replay onto the fresh handle on
//     each attach. The MPVKit demo's MPVMetalViewController is the
//     load-bearing reference implementation.
```

**Step 1: Edit, build, commit.**

```bash
git add App/Source/MPVSourcePlayer.swift
git commit -m "docs(source-playback): record render-path history in module header"
```

---

## Baseline measurements

(Filled in during Phase 4.1.)

| Build | Avg CPU% (60s, 4K HEVC) | Dropped frames (60s) | Resident memory |
|---|---|---|---|
| `feat/impl-phases-1-4-9` (Path A: GL+IOSurface→Metal) | _TBD by Phase 4.1_ | _TBD_ | _TBD_ |
| `feat/source-playback-metal-direct` (Path B: vo=gpu-next) | _TBD by Phase 4.1_ | _TBD_ | _TBD_ |

---

## Things this plan does NOT cover

- **HDR fidelity** — `target-colorspace-hint=yes` carries over. mpv's gpu-next VO supports HDR more cleanly than the GL bridge could; if a user files "HDR looks different" it's a separate investigation.
- **Vulkan validation noise** — disabling Metal API validation in the scheme is a known workaround for HDR-related crashes (KhronosGroup/MoltenVK#2226); revisit only if observed.
- **Per-mount cost optimization** — handle recreation costs ~1–2s on real unmount events. Acceptable per the architectural pivot rationale. If the cost becomes a UX issue, the future fix is keeping the view mounted across workspace switches (a SwiftUI-side change, not a render-path change).

---

## Execution handoff

**1. Subagent-Driven (this session)** — orchestrator dispatches per task, treats Phase 2 as a single atomic step.

**2. Parallel Session** — open a new session with `superpowers:executing-plans`. Lower urgency since the branch is isolated and v1 already shipped to `feat/impl-phases-1-4-9` as the safe-fallback baseline.
