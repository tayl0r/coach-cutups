# Source-Playback Decoder Swap: AVPlayer → libmpv (MPVKit)

**Status:** Design (pre-implementation plan)
**Date:** 2026-05-01
**Branch (origin):** `feat/impl-phases-1-4-9`

## Why

AVFoundation's HEVC decoder mishandles certain Android-camera 4K HEVC files —
playback shows keyframes only and decode stalls between IDRs. The same files
play smoothly in IINA / VLC (both use ffmpeg/libavcodec). QuickTime, which
shares AVPlayer's decoder, has the same problem.

A separate plan
(`docs/plans/2026-04-29-preview-perf-skip-coalesce-and-gpu-compositor.md`,
already shipped on this branch) fixed compositor-side preview lag. **It did not
solve this issue** — the bottleneck is in AVFoundation's decoder, not the
compositor.

User-stated constraint: do not transcode source files. Swap the decoder.

Test file: `/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4`.

## Scope

Swap the **source-playback decoder only** (the `Workspace.virtualPlayer` path).
Keep AVPlayer for:

- Clip preview (`previewPlayer(for:)`, `PreviewCompositor`).
- Export pipeline (`CompilationExporter`, `CompilationCompositor`).

Both keep AVFoundation; neither hits the broken decode path under the same
conditions (preview replays the recorded webcam composition; export reads from
already-known-good source ranges and is offline).

## Decoder pick: libmpv via MPVKit

`kingslay/MPVKit` SwiftPM package — ships libmpv as an XCFramework. Same engine
IINA wraps. Smaller binary than VLCKit (~20 MB vs ~50 MB), better Metal fit,
direct `mpv_command` access for frame-accurate seek and playlist control.

### Rejected: VLCKit

Higher-level abstractions over libavcodec; harder to drive frame-accurate
timecode through the public API; binary is ~2.5× the size. The work shape
would have been similar but with more wrapping to fight.

### Rejected: roll our own libavcodec wrapper

Significant ongoing maintenance for no incremental win — MPVKit is already a
thin shell over the same engine.

### Rejected: transcode/remux source files to a friendlier codec

User-rejected up front. Sources are large (multi-GB 4K), the user's mental
model is "this is the source," and any transcode either compromises quality
or doubles disk footprint.

---

## Decisions

This section captures every fork that came up during brainstorming, the option
chosen, and the options rejected (with reasoning). Future-Claude reading this
should be able to reconstruct *why* the design is the shape it is, not just
*what* the shape is.

### D1 — Abstraction shape: no protocol; control-flow helper, not a player abstraction

**Chosen.** No `SourcePlayer` protocol. `Workspace.sourcePlayer` is a concrete
`MPVSourcePlayer?`. Source-mode and preview-mode each have their own seek
primitive (one calls `MPVSourcePlayer.skip`, the other calls
`AVPlayer.seek`). The *control flow* around the seek primitive — debounce-task
arming, late-completion guard, recursion on `seekCompleted` — is extracted
into a single small helper that takes the seek primitive as a closure:

```swift
@MainActor
private func driveSkipDecision(
    _ decision: SkipDecision,
    generation: UInt64,
    issueSeek: @escaping (SeekParams, _ completion: @MainActor @escaping () -> Void) -> Void
)
```

`generation` is the playlist/player generation counter (D12) the caller
captured at decision-issue time. Both source-mode (`applySourceSkip`) and
preview-mode (`applyPreviewSkip`) call into `driveSkipDecision` and pass a
closure that knows how to issue a seek and signal completion in their
respective worlds. The control flow that's easy to get subtly wrong (the
recursion, the debounce-task cancel/re-arm, the late-completion guard) lives
in one place.

**Rejected — A: `SourcePlayer` protocol with two adopters.** Cleanest in
principle: one `applySkipDecision` body works for both, fakes are easy. But
the user explicitly does not care about future-flex or migration; the
testability win is small (the executor is glue, the decision logic is
already covered by `SkipCoordinatorTests`). Cost: a 6-method protocol surface
+ two conformances + an adapter at every call site.

**Rejected — C: concrete wrapper holding either internally.** Worst of both
— write the dispatch shape, write both impls, *and* the consumer indirection.

**Rejected — fully duplicated executors (~30 lines each).** Was the original
plan; moved off after the second adversarial review pass pointed out that
the executor's control flow (recursion + debounce + late-guard) is *not*
trivially glue and structurally identical implementations are easy to drift
apart silently. The control-flow helper is strictly less code than two
duplicates and removes the drift risk.

**Practical implication:** AVPlayer's seek-completion (closure on a private
queue) and mpv's settle (`MPV_EVENT_PLAYBACK_RESTART`, see D11) are still
different shapes; the closures bridge them into the helper's uniform
"completion: () -> Void" expectation. The bridging is small — a few lines
each.

### D2 — mpv handle lifecycle: one persistent handle, playlist-driven

**Chosen.** A single `mpv_handle` lives for the lifetime of the
`MPVSourcePlayer` instance. `Workspace.rebuildSourcePlayer` lazy-creates it on
first need and reuses it on subsequent rebuilds. Concat happens via
`playlist-clear` + `loadfile <path> append` per source, not by building a
unified composition.

**Rejected — recreate handle per rebuild.** mpv's `mpv_handle` is heavyweight
and intended to be persistent. Tearing it down on every `addSourceVideo` /
`reorderSourceVideos` / `relinkSource` would mean rebuilding the Metal layer
binding, the render context, and the event-pump thread — visible flicker, no
upside. Either way the playlist is the unit of concat.

### D3 — Time semantics: per-file timeline (not global concat timeline)

**Chosen.** mpv's `time-pos` is the position within the *current* file;
`playlist-pos` is the index. This is the natural mpv shape and we adopt it
end-to-end.

`Workspace.sourceTime(at globalSeconds:)` (the helper that walked cumulative
durations to map a global concat time to `(sourceIndex, sourceLocalSeconds)`)
becomes irrelevant for the recording path: `startRecording` reads
`(sourcePlayer.playlistPos, sourcePlayer.timePos)` directly. The helper has
no other consumers and is **deleted**.

**Rejected — preserve a global concat-timeline abstraction over the playlist.**
Would require maintaining cumulative-offset math on the Workspace side and
translating every mpv read/write through it. The original AVPlayer global
timeline was a free side-effect of `AVMutableComposition`; recreating it on
top of mpv playlist would be pure overhead.

**Practical implication:** FF/RW that crosses a source boundary requires
explicit `playlist-next/prev` + `seek` math (see D4). The current scanning UX
(no scrubber, just play-through and FF/RW) is well-served by per-file
semantics; cross-boundary scanning is rare.

### D4 — Cross-boundary skip: explicit playlist walk in a pure helper

**Chosen.** Pure function `resolveSkip(currentPlaylistPos, currentTime,
fileDurations, delta)` returns a `(targetPlaylistPos, targetTimeSeconds)`.
Lives in `VideoCoachCore` so it's unit-testable. The instance method
`MPVSourcePlayer.skip` calls the resolver, then issues either a same-file
seek or `playlist-pos <i>` followed by a seek to the residual offset.

**Rejected — let mpv handle it via a single absolute seek.** mpv has no
native global-timeline absolute-seek across playlist entries; every seek is
within the current file. Pretending otherwise would be a foot-gun.

**Rejected — disallow cross-boundary skips, force the user to switch files
manually via UI.** Out of scope; the seed assumes the existing scanning UX
keeps working.

### D5 — MPVKit lives at the App level; not in VideoCoachCore

**Chosen.** Add MPVKit as a SwiftPM package via `project.yml`'s top-level
`packages` block. `MPVSourcePlayer` and `MPVPlayerView` live in `App/`.

**Rejected — add MPVKit to `VideoCoachCore/Package.swift`.** Core is
explicitly UI-free (no AppKit/Metal links); MPVKit pulls both in via its
embedded view code. Putting it in Core leaks UI into a layer that's supposed
to be reachable from XCTest as a pure library.

**Rejected — new intermediate `VideoCoachPlayer` SwiftPM target.**
Over-engineered for one player wrapper.

### D6 — Hardware decode: Phase 1 decides; default to `videotoolbox`, fall back to `no`

**Chosen.** **Do not lock the `hwdec` value in this design.** Phase 1 (the
standalone bring-up gate) tests the actual test file under both
`hwdec=videotoolbox` and `hwdec=no` and picks the first one that plays
smoothly. The `MPVSourcePlayer` ships with whichever value Phase 1
validated, recorded in the implementation plan as a concrete option string.

**Why the assumption "VideoToolbox shares AVFoundation's broken decoder"
isn't safe to bake in:** VideoToolbox is a lower-level API than AVPlayer.
mpv's `vt` hwaccel constructs `VTDecompressionSession` directly, not
through `AVPlayerItem`'s session-management layer (which is the layer that
shows the keyframe-only symptom under AVFoundation). It's plausible that
the broken behavior lives in AVFoundation's session layer rather than in
VideoToolbox proper, in which case `hwdec=videotoolbox` works fine and
software decode would be a pointless thermal cost on every clip.

**Rejected — pin `hwdec=no` at init.** Software HEVC at 4K30 sustained is
non-trivial CPU work even on Apple silicon. An M-series MacBook running
other workloads (a record session also exercises the camera + mic capture
pipeline) can plausibly thermal-throttle. Unverified for our test file.

**Rejected — `hwdec=auto-safe`.** mpv's auto-fallback heuristics are version-
dependent and harder to reason about than a pinned choice; if the
auto-pick lands on a broken path we'd debug "why does it stutter sometimes."

**Phase 1 gate (concrete):**

1. Load the test file with `hwdec=videotoolbox`. Play 60+ seconds. **Pass
   condition:** smooth playback, no keyframe-only stutter, no decoder
   stalls between IDRs visible in `mpv_log`.
2. If 1 fails: load the same file with `hwdec=no`. Play 60+ seconds.
   **Pass condition:** smooth playback AND CPU% on the M-series machine
   stays under ~60% sustained on a single P-core (rough; a "fans don't
   audibly ramp during a 5-minute play" smoke is fine).
3. If both fail: stop and re-plan. The decoder swap isn't the right fix
   and we're back to "transcode source files" or "live with it."

### D7 — Test strategy: pure-logic tests + manual smoke for integration

**Chosen.** Unit-test `resolveSkip` exhaustively (boundary, multi-boundary,
clamping, empty playlist). Manual smoke test for actual mpv playback,
boundary-crossing FF/RW with the test file, R-press recording integration,
preview-mode swap.

**Rejected — XCTest harness that boots an mpv instance and asserts on
playback.** Slow, flaky (real decoder + display link + GPU), and the
interesting failures (smooth playback of a specific file, no decoder stall)
aren't expressible as assertions.

**Rejected — pixel tests like the previous plan.** That plan tested a custom
`AVVideoCompositing`, which is deterministic. Here we're delegating to
upstream mpv; pixel tests would be testing mpv, not us.

### D8 — Source player paused when previewing a clip; render-context detached

**Chosen.** `handleSelectionChange` calls `sourcePlayer?.pause()` when
entering preview (mirrors today's `virtualPlayer?.pause()`). When
`MPVPlayerView` is removed from the view hierarchy (preview takes over), it
detaches its render context from the still-alive `MPVSourcePlayer`. Returning
to scanning re-mounts the view and reattaches.

**Rejected — destroy the mpv handle on preview entry, recreate on return.**
Cost without benefit; a paused mpv handle holding decoded state is fine.

**Rejected — let mpv keep playing audio while preview takes over the visual.**
Audio would bleed into the preview's audio mix; user-hostile.

### D9 — End-of-file behavior: `keep-open=yes` + explicit clamp; pin `keep-open-pause`

**Chosen.** Set `keep-open=yes` AND `keep-open-pause=no`: park on the last
frame at EOF of the last playlist entry without auto-pausing. (Default
`keep-open-pause=yes` would re-enter pause every time playback rolled into
the parked tail; we want the user's pause/play state preserved.)

`PlaylistSkipResolver.resolveSkip` clamps the target to
`max(0, currentDuration - epsilon)` for forward seeks at EOF and to
`max(0, ...)` for backward seeks at start. Specifically: if the resolved
`(targetPlaylistPos, targetTimeSeconds)` would be at or past
`fileDurations[last]`, clamp to `(last, fileDurations[last] - 0.05)`. This
ensures we never issue a seek mpv would refuse — a refused seek does not
fire `MPV_EVENT_PLAYBACK_RESTART` (see D11), which would hang the
SkipCoordinator's `flying` state.

**Rejected — let mpv close on EOF (default).** View would go black or unload;
visually surprising for the user.

**Rejected — leave `keep-open-pause` at default (`yes`).** Behavior at EOF
becomes "play, hit end, mpv auto-pauses" which is an inadvertent state
change relative to whatever the user did with space.

**Phase 1 gate (concrete):** scan to the last second of the last source;
press FF (no-op or near-no-op clamp expected); press RW (should retreat
correctly); leave parked for 5+ seconds and press space (should toggle
play/pause as usual without unloading).

### D10 — Cross-file pre-decode: `prefetch-playlist=yes`

**Chosen.** Reduces the gap when playback rolls from one source into the
next during scanning.

**Rejected — leave at default (off).** Visible stutter on auto-advance would
be a regression from `AVMutableComposition`'s seamless behavior.

### D11 — Seek-completion signal: `MPV_EVENT_PLAYBACK_RESTART`, not `time-pos`

**Chosen.** The "seek has settled, decoder has the new frame ready" signal
that drives `SkipCoordinator.seekCompleted` is `MPV_EVENT_PLAYBACK_RESTART`,
not a property change on `time-pos`. The event pump observes the event and,
on receipt, bounces to `@MainActor` and fires the seek's stored completion
closure.

`mpv_command_async` is used for every seek (and every `loadfile ... start=<t>`
in the cross-boundary case, see D13). The async reply ID is captured and
matched at the event-pump side; the stored completion closure is keyed on
the same ID. This unambiguously associates the `PLAYBACK_RESTART` with the
seek that triggered it, which matters for cross-boundary skips that issue a
`loadfile`-then-park sequence (the playback-restart could otherwise be
attributed to the wrong seek issued moments earlier).

**Rejected — observe `time-pos` and treat first change after issue as
completion.** Three independent failure modes:

1. mpv emits `MPV_EVENT_PROPERTY_CHANGE` for `time-pos` continuously during
   playback (every frame). A skip issued while playing receives the next
   pre-seek `time-pos` change *before* the seek lands; the coordinator
   advances out of `flying` prematurely.
2. `mpv_observe_property` deduplicates equal-value changes by default. A
   small skip that lands on the same coarse `time-pos` bucket the player
   was already at (e.g., the exact-settle right after a coarse seek that
   landed on the right keyframe) generates no property-change event, and
   the coordinator hangs in `flying` forever.
3. Cross-boundary skips trigger a file change, which generates its own
   `time-pos` event indistinguishable from a seek-settle.

**Rejected — observe the `seeking` boolean property.** Better than `time-pos`
but still property-based; the false→true→false transition crosses two
events and forces the pump to maintain edge-detection state. `PLAYBACK_RESTART`
is one event with a clear meaning.

### D12 — Stale-completion guard: playlist generation counter

**Chosen.** `MPVSourcePlayer` exposes `var generation: UInt64` that is
incremented on every `setPlaylist(_:)` call, on every preview-mode entry
(via an explicit `bumpGeneration()`), and on `Workspace.resetSkipState()`.
Each seek captures the current generation at issue time; the seek-completion
handler in the event pump compares the captured generation to the current
one and drops the completion if they differ.

`ContentView.skipCoordinatorPlayerID: ObjectIdentifier?` is **deleted** —
the new generation counter replaces it for both the source-mode and
preview-mode paths. The preview-mode path also benefits: the existing
A → B → A round-trip bug noted at `ContentView.swift:96-101` (cache returns
the same `AVPlayer` instance, defeating `ObjectIdentifier`-based
distinction) is fixed by the same mechanism — every `selectedClipID`
change bumps the generation regardless of player identity.

**Rejected — keep `ObjectIdentifier` and add a parallel mechanism for
mpv.** Two stale-guard mechanisms is one too many. The `ObjectIdentifier`
guard never quite worked anyway (the cache-hit case in preview); replacing
both with a uniform counter cleans up two issues at once.

### D13 — Cross-boundary skip: atomic `loadfile <path> replace start=<t>`

**Chosen.** The cross-boundary path issues a single async command:
`loadfile <new-path> replace start=<t>`. mpv handles the file swap and
the start-position application as one operation. The command's async reply
ID is captured for completion-signal matching (D11).

**Rejected — `playlist-pos <i>` followed by `seek <t> absolute+exact`.**
Two-command sequence has a race: the second command can land before
the new file is demuxed, and is then either silently dropped (start of
file) or applied to the wrong file. mpv's command queue is serial but the
file-loading work itself is asynchronous and the seek can run before the
demuxer has built its time-base.

**Practical implication:** the `MPVSourcePlayer.skip` implementation uses
`PlaylistSkipResolver.resolveSkip` to compute `(targetPlaylistPos,
targetTimeSeconds)`. If `targetPlaylistPos == currentPlaylistPos`, issue an
in-file `seek <t> absolute+exact|keyframes`. Otherwise, look up the file
path at `targetPlaylistPos` and issue `loadfile <path> replace start=<t>`.

### D14 — Hardened-runtime entitlement: add `disable-library-validation`

**Chosen.** Add `com.apple.security.cs.disable-library-validation = true` to
`App/VideoCoach.entitlements`. This is required to launch a hardened-runtime
app linked against MPVKit — the XCFramework's bundled libmpv and FFmpeg
dylibs are signed by the upstream maintainer's identity, not the app's, and
hardened-runtime library validation refuses to load them otherwise.

**Why this isn't a "validate during smoke" item:** It's binary. The app
either has the entitlement (loads MPVKit, works) or doesn't (fails at
launch with a cryptic dyld error). IINA ships this entitlement for the
same reason.

**Security implication:** library validation primarily defends against
dylib injection. The app is already non-sandboxed with camera + mic access
— a high-privilege process. Disabling library validation is a small
incremental concession given the existing privilege footprint.

**Rejected — re-sign the XCFramework dylibs with our identity at build
time.** Possible in principle; brittle in practice (every MPVKit version
bump requires re-running the resign step) and offers no real security gain
over the entitlement.

### D15 — Volume curve: linear gain to match AVPlayer

**Chosen.** Set mpv option `volume-correct=no` at init so the `volume`
property is interpreted as linear gain (not perceptual). Map the SwiftUI
slider's 0...1 range to mpv's `0...100` linearly: `mpv_volume = 100 *
sliderValue`. Result: slider feel matches the AVPlayer baseline the user
has been training on; 0.5 sounds like 0.5 did pre-swap.

**Rejected — accept mpv's perceptual default.** Slider position-to-loudness
curve would change. Small but real UX regression; user has to re-learn the
slider feel and may set source levels too high/too low for a recording
session before noticing.

**Rejected — wrap the slider in a perceptual-to-linear conversion.**
Possible, but mpv's `volume-correct=no` is the cleaner one-line fix and
keeps the SwiftUI binding straightforward.

---

## Architecture

```
┌─────────────────────────── ContentView ───────────────────────────┐
│                                                                    │
│   appMode = .scanning|.recordingStarting|.recording                │
│   │                                                                │
│   ▼                                                                │
│   PlayerSurface area (ZStack):                                     │
│     • MPVPlayerView(player: workspace.sourcePlayer)                │
│     • DrawingOverlay (during .recording)                           │
│     • KeyCommandView (always)                                      │
│                                                                    │
│   appMode = .previewClip(id):                                      │
│     • PlayerSurface[AVPlayerView](player: previewPlayer(for: id))  │
│     • StrokeReplayOverlay, previewTextBar, KeyCommandView          │
│                                                                    │
│   handleSkip(delta) →                                              │
│     SkipCoordinator.requestSkip(...) → SkipDecision                │
│       → applySourceSkipDecision (if source-mode), via              │
│         MPVSourcePlayer.skip(deltaSeconds:exact:completion:)       │
│       → applySkipDecision         (if preview-mode), via           │
│         AVPlayer.seek(to:tolerance...:completionHandler:)          │
└────────────────────────────────────────────────────────────────────┘
```

**Tech stack:** Swift 5.9, macOS 14, AVFoundation (preview + export), MPVKit
(source playback), CoreImage, CoreVideo, XCTest, SwiftPM.

---

## Components

### `App/Source/MPVSourcePlayer.swift` (new)

`@MainActor @Observable final class MPVSourcePlayer` wrapping a persistent
`mpv_handle`. Owns the handle, the render context, and the event-pump
thread.

```swift
@MainActor
@Observable
public final class MPVSourcePlayer {
    public init() throws  // mpv_create + options + mpv_initialize

    // Playlist
    public func setPlaylist(_ paths: [String])  // playlist-clear + loadfile append per p

    // Playback
    public func play()
    public func pause()
    public func togglePlay()
    public func setVolume(_ v: Double)          // 0...1 → mpv 0...100

    // Seek / skip
    public func skip(
        deltaSeconds: Double,
        exact: Bool,
        completion: (@MainActor () -> Void)?
    )
    public func seekWithinCurrent(
        toSeconds: Double,
        exact: Bool,
        completion: (@MainActor () -> Void)?
    )

    // Render-context attach/detach (called by MPVPlayerView)
    public func attachRender(layer: CAMetalLayer) throws
    public func detachRender()

    // Observed state (drives UI + drives skip math + drives R-press read).
    // All updated by the event pump from `MPV_EVENT_PROPERTY_CHANGE`. Reads
    // are unsynchronized cached-value reads — no `mpv_get_property` blocking
    // call on the main thread (see "Why these are observed, not on-demand").
    public private(set) var isPaused: Bool
    public private(set) var playlistCount: Int
    public private(set) var playlistPos: Int
    public private(set) var timePos: Double            // last-observed displayed time
    public private(set) var currentDuration: Double    // duration of file at playlistPos
    public private(set) var generation: UInt64         // bumped on setPlaylist + bumpGeneration

    public func bumpGeneration()  // called on preview-entry / resetSkipState

    deinit  // mpv_render_context_free + mpv_destroy
}
```

**Why these are observed, not on-demand:** `mpv_get_property` is documented
thread-safe but is *not* lock-free — calls go through the mpv core and can
block the calling thread for up to ~500ms when the core is busy (decoding,
seeking, switching files). A synchronous `timePos` read on the main actor
during a burst FF/RW would freeze the UI. We avoid that entirely by
caching every value the app reads from a property-change event observed
on the event pump thread, then bouncing to `@MainActor` to update the
`@Observable` field.

**Property-change subscriptions** (via `mpv_observe_property` at init):
`pause`, `playlist-count`, `playlist-pos`, `time-pos`, `duration`. The
pump translates each to a `@MainActor` write to the corresponding cached
field. `time-pos` events fire frequently during playback; we accept the
cost (the work is just a value write + Observable notification).

**mpv config at init** (`mpv_set_option_string` before `mpv_initialize`):

| Option | Value | Reason |
|--------|-------|--------|
| `vo` | `libmpv` | Embedded rendering (we own the surface) |
| `prefetch-playlist` | `yes` | D10 — minimize cross-boundary gap |
| `keep-open` | `yes` | D9 — don't close at EOF |
| `pause` | `yes` | Start paused |
| `msg-level` | `all=warn` | Silence info logs |
| `audio-display` | `no` | No built-in audio visualizer |
| `osc` / `osd-level` | `no` / `0` | No mpv-drawn OSD |
| `target-colorspace-hint` | `yes` | HDR/HLG passthrough hint |
| `keep-open-pause` | `no` | D9 — don't auto-pause when parking at EOF |
| `volume-correct` | `no` | D15 — linear gain to match AVPlayer slider feel |
| `audio-display=no` note | — | Disables mpv's audio-only-file visualizer; **does not** mute output. Don't confuse with `ao=null`. |
| `hwdec` | *(deferred)* | D6 — Phase 1 picks `videotoolbox` if it works on the test file, else `no`. |

**Event pump:** dedicated background thread calls `mpv_wait_event` in a
loop. Events handled:

- `MPV_EVENT_PROPERTY_CHANGE` for `pause`, `playlist-count`, `playlist-pos`,
  `time-pos`, `duration` → bounce to `@MainActor`, update the corresponding
  `@Observable` cached field.
- `MPV_EVENT_PLAYBACK_RESTART` (D11) → bounce to `@MainActor`, look up the
  pending seek-completion closure for the most recently issued seek's
  reply ID, validate the captured generation matches `generation` (D12),
  fire it.
- `MPV_EVENT_COMMAND_REPLY` is consumed for the reply-ID matching machinery
  (D13: `loadfile ... start=<t>` — confirms the file actually started
  loading before we expect a `PLAYBACK_RESTART` for it).
- `MPV_EVENT_LOG_MESSAGE` at warn/error level → `os_log` via the app's
  unified-logging category.
- `MPV_EVENT_END_FILE` with `reason = error` → `os_log` warn (file
  unreadable; mpv auto-advances).
- `MPV_EVENT_SHUTDOWN` → exits the loop; deinit completes.

### `App/Views/MPVPlayerView.swift` (new)

`NSViewRepresentable` over a custom `NSView` that hosts a `CAMetalLayer`.

**Lifecycle:**

- `viewDidMoveToWindow` (window != nil) → `player.attachRender(layer:)`.
  Render context binds to the layer. CADisplayLink starts.
- `viewWillMove(toWindow: nil)` → `invalidate CADisplayLink first`, then
  `player.detachRender()`. Order matters (see "Teardown gate" below).

**Render driver:** CADisplayLink (macOS 14+) calls
`mpv_render_context_render` on display refresh, gated by mpv's
`mpv_render_context_set_update_callback` flag (only render when a new
frame is ready, not every refresh).

**Teardown gate (must be explicit, not implicit):** mpv's render API
states only one of `mpv_render_*` may run at a time. CADisplayLink fires
asynchronously; if `detachRender()` calls `mpv_render_context_free()` while
a display-link callback is mid-`mpv_render_context_render()`, behavior is
undefined.

The view enforces ordering:

1. `viewWillMove(toWindow: nil)` → `displayLink.invalidate()` (synchronous
   on macOS 14+ — no further callbacks will fire after return).
2. Take a `state.isRendering` lock, wait for any in-flight render to
   release it (one-frame max).
3. Call `player.detachRender()` → `mpv_render_context_free()`.

`attachRender` similarly gates on confirmation that any previous render
context was fully freed before calling `mpv_render_context_create()` —
mpv allows only one render context per core at a time.

The exact mpv render-API choice (Metal advanced control vs SW + manual blit)
will be committed in the implementation plan after reading MPVKit's headers
for the pinned version. Phase 1 also exercises mount → unmount → remount
to validate the lifecycle gates work in practice.

### `resolveSkip` — pure helper (in `VideoCoachCore`)

```swift
public struct PlaylistSkipResolution: Equatable, Sendable {
    public let targetPlaylistPos: Int
    public let targetTimeSeconds: Double
}

public enum PlaylistSkipResolver {
    public static func resolveSkip(
        currentPlaylistPos: Int,
        currentTimeSeconds: Double,
        fileDurations: [Double],
        deltaSeconds: Double
    ) -> PlaylistSkipResolution
}
```

Lives in Core so `VideoCoachCoreTests` can exhaustively test it. App-side
`MPVSourcePlayer.skip` calls it, then translates the result into mpv commands.

### Modified files

- `App/Models/Workspace.swift` — `virtualPlayer: AVPlayer?` → `sourcePlayer:
  MPVSourcePlayer?`. `virtualComposition` deleted. `rebuildVirtualPlayer` →
  `rebuildSourcePlayer`. `sourceTime(at:)` deleted (verified single consumer
  at `ContentView.swift:633`).
- `App/ContentView.swift` — `currentPlayer` and `skipCoordinatorPlayerID`
  deleted (D12 generation counter replaces the player-ID guard). `handleSkip`
  branches on `appMode` and uses the `driveSkipDecision` control-flow helper
  (D1). Source-mode pre-pauses + reads cached `(playlistPos, timePos)` at
  R-press (per "R-press" in Data flow). `handleTogglePlay`, `startRecording`,
  `resetSkipState` rewritten against `MPVSourcePlayer`.
- `App/Views/PlayerSurface.swift` — split: `PreviewPlayerSurface` (AVPlayerView,
  preview only); scanning ZStack uses `MPVPlayerView` directly.
- `App/Views/TransportBar.swift` — `ScanningTransport` reads
  `workspace.sourcePlayer?.isPaused` and calls `togglePlay()/setVolume(_:)`.
- `App/Views/KeyCommandView.swift` — **drop the dead `let player: AVPlayer?`
  parameter** (it's never read by `KeyCatchingView`; was a SwiftUI redraw
  trigger today). Redraw now keys off `appMode` only — sufficient because
  every player swap correlates with an `appMode` change.
- `App/Recording/RecordingController.swift` — **untouched**.
- `App/Capture/CaptureSessionController.swift` — **untouched**.
- `App/VideoCoach.entitlements` — **add**
  `com.apple.security.cs.disable-library-validation = true` (D14).
- `project.yml` — add MPVKit package dep at App level.

---

## Data flow

### Source playback startup (open project / add source)

1. `Workspace.openProject` → `rebuildSourcePlayer`.
2. Bookmark loop runs as today; failed resolves go into `missingSourceIndices`.
3. If `missing.isEmpty && !sourceVideos.isEmpty`:
   - Lazy-init `sourcePlayer = try MPVSourcePlayer()` on first call;
     subsequent calls reuse.
   - `sourcePlayer.setPlaylist(resolved.map { $0.url.path })`.
4. Else: `sourcePlayer?.setPlaylist([])` — clears playlist; the handle stays
   alive; the Relink banner takes over the player surface.

### Skip burst (no boundary cross)

1. KeyCommand → `handleSkip(delta)` (branches on `appMode` to source path).
2. Source path captures `let gen = sourcePlayer.generation` and reads
   `sourcePlayer.timePos` (cached value), feeds them to
   `SkipCoordinator.requestSkip(...)` → `SkipDecision`.
3. `applySourceSkip` calls into the shared `driveSkipDecision(decision,
   generation: gen, issueSeek: ...)` helper (D1). The closure passes the
   `SeekParams` to `sourcePlayer.skip(deltaSeconds: …, exact: …,
   completion: …)`.
4. `MPVSourcePlayer.skip` calls `PlaylistSkipResolver.resolveSkip`; target
   lies within current file. Issues `seek <t> absolute+keyframes` (or
   `+exact`) via `mpv_command_async` and stores the completion closure
   keyed by reply ID + generation.
5. Event pump receives `MPV_EVENT_PLAYBACK_RESTART` (D11) → bounces to
   `@MainActor` → looks up the pending completion by reply ID → validates
   captured generation matches `sourcePlayer.generation` (D12) → fires
   the closure → `SkipCoordinator.seekCompleted` → `driveSkipDecision`
   recurses with the next `SkipDecision`.

### Skip burst (boundary cross)

Same path through `SkipCoordinator` → `driveSkipDecision`; `resolveSkip`
returns a different `playlistPos`. `MPVSourcePlayer.skip` issues a single
atomic `loadfile <new-path> replace start=<t>` via `mpv_command_async`
(D13). The reply-ID/generation/`PLAYBACK_RESTART` machinery from above
applies identically.

`PlaylistSkipResolver.resolveSkip` clamps targets to within
`(0, fileDurations[last] - 0.05)` so we never issue a seek mpv would
refuse — a refused seek does not produce `PLAYBACK_RESTART` and would hang
the SkipCoordinator's `flying` state (D9).

### R-press (start recording)

The recording-anchor `(sourceIndex, startSourceSeconds)` is the contract
between the recorded webcam clip and the source frame the user was
watching at R-press. Get it wrong by 50ms and the export's overlay strokes
land on the wrong moment forever, so this read needs to be precise.

1. `sourcePlayer.pause()` synchronously (mpv `set_property pause yes`).
   Pause forces mpv to commit `time-pos` to the displayed frame and
   prevents prefetch from quietly advancing `playlist-pos` mid-read.
2. Wait briefly (one event-pump tick — typically <16ms) for the
   `pause`/`playlist-pos`/`time-pos` property-change events to flush so
   the cached `@Observable` fields reflect the post-pause state. In
   practice: `await Task.yield()` once on the main actor before reading.
3. Read cached `sourcePlayer.playlistPos` and `sourcePlayer.timePos`
   (these are `@Observable` cached values updated by the event pump,
   not synchronous `mpv_get_property` calls — see "Why these are
   observed" in Components).
4. `pendingRecording.sourceIndex = playlistPos`;
   `startSourceSeconds = timePos`.
5. UI flips to `.recordingStarting`.

**Why this avoids the prefetch race:** with `prefetch-playlist=yes` (D10),
mpv may be priming the next file mid-playback. Reading
`(playlistPos, timePos)` without first pausing risks capturing the
about-to-play index instead of the on-screen index. Pausing freezes
both. The latency cost (one frame, ~16ms at 60Hz) is below human
perception for a recording-start event.

### Clip-preview selection

1. `handleSelectionChange(newID)` calls `sourcePlayer?.pause()` (mirrors
   today's `virtualPlayer?.pause()`) and `sourcePlayer?.bumpGeneration()`
   so any in-flight skip-completion lands into a stale generation and is
   dropped (D12).
2. SwiftUI removes `MPVPlayerView` from the view hierarchy as the ZStack
   switches to `PreviewPlayerSurface`. `MPVPlayerView.viewWillMove(toWindow:
   nil)` invalidates its CADisplayLink, then calls `player.detachRender()`
   (the lifecycle gate from Components/`MPVPlayerView`). mpv keeps its
   decoder state but stops driving a now-orphan layer.
3. On return to `.scanning`, `MPVPlayerView` re-mounts → re-attaches render
   context.

**Known minor cost:** while previewing, mpv keeps prefetched frames warm
in its internal cache (D10's `prefetch-playlist=yes`). For a long preview
session (tens of minutes) on a low-RAM machine, this is wasted memory.
Acceptable trade-off for now; a future mitigation could `set_property
prefetch-playlist no` on preview entry and restore on exit. Not included
in this plan.

### Bookmark stale / source missing

Same as today: `missingSourceIndices` populated, `sourcePlayer.setPlaylist([])`,
Relink banner renders. mpv handle survives so a successful relink doesn't pay
init cost again.

---

## Error handling

- **`mpv_initialize` fails** → `MPVSourcePlayer.init` throws.
  `Workspace.rebuildSourcePlayer` propagates as `WorkspaceError.sourcePlayerInitFailed`.
  Player surface shows a card ("Couldn't initialize source player").
- **Render-context init fails** → `MPVPlayerView` falls back to a hard error
  label. Defensive only; should not happen on macOS 14+ Apple silicon.
- **File in playlist unreadable** → mpv emits `MPV_EVENT_END_FILE` with
  `reason = error`. Logged at warn level. Playlist auto-advances. Listed
  sources stay in the project; user discovers the issue when scanning into
  that source. Surfacing a banner is out of scope for this plan.
- **Decoder error mid-stream** → mpv handles internally; emits property
  events the UI doesn't react to. No crash.
- **Path encoding** → `URL.path` returns UTF-8; mpv accepts UTF-8 paths. No
  re-encoding needed.

---

## Testing

### Pure-logic unit tests — `VideoCoachCoreTests/PlaylistSkipResolverTests.swift`

- `resolveSkip` — same file, within bounds.
- `resolveSkip` — same file, would clamp to 0 (large negative delta).
- `resolveSkip` — same file, would clamp to file duration (large positive).
- `resolveSkip` — crosses one file boundary forward.
- `resolveSkip` — crosses one file boundary backward.
- `resolveSkip` — crosses two boundaries (delta larger than next file's duration).
- `resolveSkip` — clamps at end of last playlist entry.
- `resolveSkip` — clamps at start of first entry.
- `resolveSkip` — single-entry playlist.
- `resolveSkip` — empty playlist returns `(0, 0)` defensively.

### Manual smoke (verification checklist)

- [ ] Source playback of `/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4`
      is **smooth end-to-end** (compare against pre-swap commit by toggling).
- [ ] FF/RW key burst inside a single source: same UX as the AVPlayer path
      (coarse during burst, exact settle ~150 ms after release).
- [ ] FF/RW key burst that crosses a source boundary: lands in next file at
      the correct local offset.
- [ ] Toggle play/pause via space and the transport bar button.
- [ ] Volume slider audibly changes source playback gain.
- [ ] R-press starts a recording; resulting clip plays back correctly with
      the right `sourceIndex` + `startSourceSeconds`.
- [ ] Select clip → mpv pauses, preview takes over; close preview → mpv view
      returns, paused.
- [ ] Source bookmark stale (rename file externally) → Relink banner renders;
      mpv playlist is cleared; relink + rebuild restores playback.
- [ ] No crash / hang on app quit (mpv handle teardown is clean).
- [ ] Hardened-runtime entitlements (camera + mic) still pass with MPVKit
      linked.

### Out of scope

- mpv decoder behavior, Metal rendering correctness, HDR tone-mapping.
  Trusting MPVKit + mpv upstream.

---

## Risks to validate during implementation

(Carried over from the seed; most addressed by decisions above. Remaining
items are smoke-test concerns, not design holes.)

- **Bookmark URL → mpv path.** Resolved bookmarks return `URL`; mpv takes
  a path string. `URL.path` should produce a valid UTF-8 path. Validate
  on first integration smoke (Phase 1).
- **HDR/HLG metadata.** If the test file is HLG, `target-colorspace-hint=yes`
  should auto-tone-map for SDR display. Visually verify saturation parity
  (or graceful tone-map) against IINA.
- **mpv log-level chatter.** `msg-level=all=warn` set; verify silence in
  Console.app at smoke time.
- **`coarseSeekInFlight` flag** — preview-only
  (`StrokeReplayLayer`-driven freeze gate); does not affect source
  playback. Untouched.
- **mpv volume scaling (D15).** Confirm `volume-correct=no` actually flips
  mpv's `volume` property to linear in the pinned MPVKit version (older
  libmpv versions had the option spelled differently). Test by ear at
  0.0 / 0.25 / 0.5 / 0.75 / 1.0 slider positions and compare to the AVPlayer
  baseline.
- **CADisplayLink on macOS 14+ behavior under app backgrounding.** mpv keeps
  decoding when the app loses focus; CADisplayLink may pause. Either is
  fine for source playback (user expects pause when not focused), but the
  resume path on focus regain has historically been a source of macOS
  bugs. Smoke this.

---

## Phasing

Modeled on the previous plan's discipline (small phases, each lands green;
two adversarial review passes before execution; per-task fresh implementer +
spec reviewer + code-quality reviewer during execution).

- **Phase 1 — Bring-up + de-risk gate.** Add MPVKit SwiftPM dep at the App
  level. Add the `disable-library-validation` entitlement (D14). Stand up
  a standalone `MPVPlayerView` reachable from a hidden debug menu item.
  This phase is the load-bearing gate: each item below has to pass before
  Phase 2 starts. If any of (a)–(d) fail, the design is invalidated and
  we re-plan.

  **Gate checklist:**

  - **(a) Decoder gate (D6).** Load the test file with `hwdec=videotoolbox`,
    play 60+ seconds. Smooth playback, no keyframe-only stutter, no decoder
    stalls in `mpv_log`. If it fails, repeat with `hwdec=no`. Whichever
    passes is the value the implementation plan pins.
  - **(b) Hardened-runtime + library validation (D14).** Build under the
    project's normal hardened-runtime build (`./scripts/run.sh`, no
    workarounds). App must launch without dyld validation errors and
    successfully load MPVKit's bundled libmpv + FFmpeg dylibs.
  - **(c) Render-context lifecycle.** From the debug menu, mount
    `MPVPlayerView`, play 5s, dismiss the debug view (unmount), re-open
    it (remount). Player must continue playing without leaks, crashes,
    or render-context errors. Repeat 3× to shake out lifecycle races.
  - **(d) SwiftUI overlay composition.** Place a SwiftUI overlay
    (`Color.red.opacity(0.3)`, plus a `Text("overlay")` and a
    `DrawingOverlay`-shaped `Canvas`) inside the same ZStack as the
    `MPVPlayerView`. Overlays must composite correctly above the
    Metal-hosted player surface (no z-order surprises, no missing
    rasterization, hit-testing where expected).
  - **(e) HEVC decoder presence.** `mpv_log` for the loaded file shows
    libavcodec + HEVC decoder picked. (Some MPVKit builds strip codecs to
    shrink binary; ours needs HEVC.) Easy to assert via the log message
    `Using video decoder: hevc`.
  - **(f) EOF behavior (D9).** Scan to last second of the test file; FF
    should clamp; RW should retreat; leaving parked for 5s and pressing
    space toggles play/pause without unloading.

  Failures here either rule out the decoder swap entirely or require a
  design amendment before continuing.
- **Phase 2 — `MPVSourcePlayer` + skip resolver.** Implement the wrapper
  class with playlist + skip API. Implement `PlaylistSkipResolver` with full
  unit-test coverage in `VideoCoachCore`. No app integration yet.
- **Phase 3 — Workspace migration.** `virtualPlayer` →
  `sourcePlayer`. `rebuildSourcePlayer`. Recording read-site update
  (`startRecording` reads playlistPos + timePos directly).
  `Workspace.sourceTime(at:)` deletion.
- **Phase 4 — UI wiring.** `PlayerSurface` split, `TransportBar.ScanningTransport`
  rebind, `ContentView.handleSkip` branch, `applySourceSkipDecision`,
  `handleTogglePlay` rewrite.
- **Phase 5 — Adversarial review (two passes).** Same review pattern as the
  prior plan: `feature-dev:code-reviewer` + `superpowers:code-reviewer`,
  findings folded back into the implementation plan before execution.
- **Execution** — run the implementation plan via
  `superpowers:subagent-driven-development`.

---

## Adversarial review history

Two parallel passes ran on the design's first draft (`feature-dev:code-reviewer`
and `superpowers:code-reviewer`). Findings folded back into the decisions
above before this commit.

| Finding | Where it lives now |
|---------|-------------------|
| `time-pos` change is the wrong seek-completion signal (continuous fire, deduplication on equal values, cross-file ambiguity). | D11 — switched to `MPV_EVENT_PLAYBACK_RESTART` + async reply IDs. |
| `mpv_get_property` on the main thread can block ~500ms; on-demand `timePos`/`playlistPos`/`currentDuration` reads are unsafe. | Components/`MPVSourcePlayer` — properties are observed cached values updated by the event pump. |
| `ObjectIdentifier`-based stale-completion guard doesn't translate to mpv's persistent handle (instance doesn't change across `setPlaylist`). | D12 — generation counter replaces the player-ID guard for both paths. Also fixes the preexisting A→B→A AVPlayer cache bug. |
| `hwdec=no` was asserted, not validated; VideoToolbox may not actually share AVFoundation's broken decoder. | D6 — Phase 1 picks; default to `videotoolbox`, fall back to `no` if needed. |
| CADisplayLink callbacks can race `mpv_render_context_free`. | Components/`MPVPlayerView` — explicit teardown gate (invalidate displaylink, wait for in-flight render to release, then free). |
| Hardened-runtime + MPVKit XCFramework requires `disable-library-validation`. | D14 — entitlements file change in Modified files. |
| Two-command cross-boundary skip (`playlist-pos` + `seek`) races mpv's async file load. | D13 — single atomic `loadfile <path> replace start=<t>`. |
| `keep-open=yes` end-of-playlist behavior was underspecified; refused EOF seeks would hang the seek-completion signal. | D9 — also pin `keep-open-pause=no`; clamp seek targets to `(0, duration - epsilon)`; Phase 1 gate (f). |
| `KeyCommandView` not in modified-files list; carries dead `player: AVPlayer?` parameter. | Modified files — drop the parameter. |
| mpv volume defaults to perceptual-log; AVPlayer is linear; slider feel would change. | D15 — `volume-correct=no`; linear 0..1 → 0..100 mapping. |
| Phase 1 gate too narrow; would miss render-context lifecycle bugs, SwiftUI overlay composition issues, missing HEVC codec, hardened-runtime issues. | Phase 1 expanded to a 6-item gate checklist. |
| Two parallel skip executors risk drifting (the recursion + debounce + late-guard control flow is structurally identical and easy to break in a duplicate). | D1 revised — extracted `driveSkipDecision` control-flow helper that both paths call into, with the seek primitive passed as a closure. Not a player abstraction. |
| Pre-fetched frames stay warm in mpv's cache during long previews (memory cost). | D8 — noted as a known minor trade-off; mitigation deferred. |
| `audio-display=no` could be confused with `ao=null`. | mpv config table — explicit clarifying note added. |

## Open questions / things to commit during plan-writing, not now

- Exact MPVKit version pin (latest stable at plan time).
- mpv render-API choice in `MPVPlayerView` (Metal advanced control vs SW
  blit). Will be decided after reading the pinned MPVKit's headers.
- Concrete async-reply-ID dispatch shape inside the event pump (a
  dictionary keyed by reply ID with `(generation, completion)` values; or
  a small array since at most one or two seeks are ever in flight). Either
  works; pick at implementation time.
