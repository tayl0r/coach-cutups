# Video Coach — Rust Rewrite Design

A full rewrite of the macOS-only Swift app into a cross-platform Rust application, targeting macOS, Windows, and Linux from the same codebase. This document captures the architectural decisions; product behavior stays the same as the v1 design (`2026-04-27-video-coach-design.md`) unless explicitly noted under "Behavioral changes" below.

## Why rewrite

- v1 is structurally Apple-only: capture, the custom `AVVideoCompositing`, HEVC export, and the `CALayer` stroke overlay are all `AVFoundation`/`CoreAnimation`-bound. Roughly 70% of the app code can't be ported as-is.
- A cross-platform delivery is a goal, not a "leave doors open" hedge.
- Swift on Linux/Windows is workable as a *language*, but `AVFoundation` and `SwiftUI` are not — porting amounts to a rewrite of the platform layer either way. May as well rewrite into a stack designed to be cross-platform end-to-end.

## Goals

- Single codebase shipping on macOS, Windows, and Linux.
- Identical visual output across platforms — preview path and export path use the same compositor.
- Hardware-accelerated capture, decode, and encode wherever the OS provides it.
- Boring, well-trodden tech for the parts where bugs are expensive (capture, encode).

## Non-goals (v2)

- Beating v1's macOS-specific feature set on day one. v2 reaches parity, then expands.
- Mobile (iOS/iPadOS/Android). Desktop only.
- Browser/web build. Desktop binaries only.
- Project-file backwards compatibility. v2 defines its own `project.json` schema; v1 projects are not opened by v2.
- Any further Swift v1 development. v1 is frozen as of branch `rust-rewrite`'s parent commit.

## Technology stack

| Layer | Choice | Why |
|---|---|---|
| Language | **Rust** (workspace, stable channel) | Memory safety in code that juggles capture buffers, GPU textures, and encoder pipes; single-binary builds; cross-platform first-class. |
| UI | **Slint** | First-class GPU surface integration (clean wgpu interop), real desktop layouts (timeline, sidebar, inspector), native menus and file dialogs, declarative `.slint` files keep UI separable from logic. |
| Capture & encode | **GStreamer** via `gstreamer-rs` | Pipeline graph maps directly to capture→composite→encode; per-platform capture sources (`avfvideosrc`/`mfvideosrc`/`pipewiresrc`/`v4l2src`) and HW encoders (`vtenc_*`/`mfh26{4,5}enc`/`vaapi*enc`/`nvh26{4,5}enc`) are all reachable through one API. First-party Rust binding maintained by the GStreamer project. |
| Compositor & stroke layer | **wgpu** (via Slint's external-texture API) | Same surface drives live preview *and* export. No risk of preview/export divergence. Backed by Metal / D3D12 / Vulkan transparently. |
| Persistence | `serde_json` for `project.json`, plain files in `recordings/` | Same shape as v1, schema versioned (see "Project format" below). |

The GStreamer pipeline does **not** use the `compositor` element for the actual PiP+stroke composite. Frames flow:

```
[capture/decode src] → appsink → wgpu compositor → appsrc → [encoder] → [muxer/sink]
```

The same wgpu compositor runs for live preview, with the output texture bound to a Slint `Image` rather than fed into `appsrc`. Single source of truth for visual output.

## Codec strategy

Decoupled by stage:

- **Recording (intermediate `recordings/*.mov`)**: **H.264 hardware-encoded** via the OS encoder (`vtenc_h264` / `mfh264enc` / `vaapih264enc` / `nvh264enc`). Universally available, real-time on every modern GPU, decodes fast for the export pass. File size is irrelevant — these never leave the user's machine.
- **Export (per-tag `.mp4` deliverables)**: **HEVC hardware-encoded** via the OS encoder (`vtenc_h265` / `mfh265enc` / `vaapih265enc` / `nvh265enc`). ~30–40% smaller than H.264 at the same quality, which matters when the user is uploading on slow internet.
- **Export software fallback**: **x265** for machines lacking a HW HEVC encoder (rare on modern hardware, but possible on older Linux boxes or AMD Linux without VAAPI HEVC). x265 is GPLv2-or-later, compatible with the project's AGPL-3.0. The export sheet warns the user about expected encode time when this path is taken.
- **AV1**: deferred. Software svt-av1 at 4K is 8–15× slower than VT HEVC on Apple Silicon, and HW AV1 encode hasn't reached Apple Silicon yet. Revisit when M-series gains HW AV1 encode (likely M5/M6 era), at which point flipping the default is a one-line change.
- **No FFmpeg dependency.** GStreamer covers everything we need. (The v1 design's "no FFmpeg" stance is preserved.)

## Architecture

### Crate layout

```
video-coach/
├── crates/
│   ├── video-coach-core/        # Pure logic, no GStreamer, no Slint, no wgpu.
│   │                             # Data model, project IO, source-time
│   │                             # reconstruction, stroke replay algorithm,
│   │                             # tag aggregation, compilation plan.
│   │                             # Mirrors v1's VideoCoachCore Swift package.
│   ├── video-coach-media/       # GStreamer pipelines: capture, decode-for-preview,
│   │                             # encode, mux. Owns the appsrc/appsink surfaces.
│   ├── video-coach-compositor/  # wgpu compositor + stroke renderer. Pure render
│   │                             # logic, takes input textures + a frame plan,
│   │                             # produces output textures. No GStreamer here.
│   ├── video-coach-app/          # Slint UI, glue, command handling, project lifecycle.
│   └── video-coach-tests/        # Integration tests (headless pipelines, round-trip
│                                  # encode/decode, golden-frame compositor tests).
├── ui/                           # `.slint` files.
└── docs/
```

`video-coach-core` is platform-neutral and unit-tested with `cargo test` (no GStreamer init, no GPU). Same discipline as v1's Swift package — mistakes are caught on the cheapest layer.

### Data flow — recording

```
camera → avfvideosrc/mfvideosrc/v4l2src → appsink → [Rust: hand frame to writer]
mic    → avfaudiosrc/wasapisrc/pulsesrc  → appsink → [Rust: hand frame to writer]
                                                          ↓
                                          mux into recordings/<clip>.mov
                                          (H.264 video, AAC audio, fragmented mp4/mov)
```

Strokes captured during recording are stored as a `Vec<StrokeEvent>` in memory and persisted to `project.json` on clip finalize — *not* burned into the recording. The compositor replays them at export time. Same algorithm as v1, ported.

### Data flow — preview

```
recordings/clip.mov (H.264)  ─┐
                               ├→ filesrc → demux → decodebin → appsink ─┐
project.json source ranges    ─┘                                          │
                                                                          ↓
                                                        wgpu compositor (PiP + strokes)
                                                                          ↓
                                                            Slint Image surface
```

### Data flow — export

```
recordings/clip.mov (H.264)  ─┐
                               ├→ filesrc → demux → decodebin → appsink ─┐
project.json compilation plan ─┘                                          │
                                                                          ↓
                                                        wgpu compositor (PiP + strokes)
                                                                          ↓
                                                          appsrc → vtenc_h265/etc → mp4mux → filesink
```

The compositor is the same code path. Only the sink changes.

## Project format (v2)

`project.json` keeps a similar shape to v1 but bumps a `schemaVersion: 2`. Notable changes:

- Source-video bookmarks: replaced with relative paths from project folder. v1's macOS security-scoped bookmarks don't translate cross-platform; relative paths force the project folder to be a self-contained unit (which it already mostly is).
- Stroke storage: identical schema to v1.
- Recording paths: stored relative to project folder.

v1 → v2 migration is **not** provided. v1 projects remain readable only by the frozen v1 Swift app.

## Behavioral changes vs v1

The product behavior described in `2026-04-27-video-coach-design.md` carries over, with these specific differences:

- HEVC fallback to x265 on machines without HW HEVC, with a UI warning about encode time. (v1 only ran on Apple Silicon, where VT HEVC is always available.)
- Recording intermediate is H.264 instead of HEVC. Visually invisible to the user; affects only the on-disk size of `recordings/*.mov`.
- Project format is incompatible with v1 (see above).
- Initial v2 ships with the same single-camera/single-mic defaults as v1, with device pickers still deferred.

## Build / distribution

- **Build system**: Cargo workspace. `cargo build --release` produces a single binary per platform.
- **Packaging**:
  - macOS: `cargo bundle` or hand-rolled `.app` with `codesign` + notarization.
  - Windows: MSI via `cargo-wix` or simple zip-and-ship.
  - Linux: AppImage for distribution-agnostic single-file delivery.
- **GStreamer dependency**: bundled with the app on macOS (via Homebrew gstreamer libs copied into the `.app`) and Windows (MSVC builds shipped with the installer). On Linux, expect users to have GStreamer installed system-wide; AppImage bundles the plugins it needs.
- **CI**: GitHub Actions matrix (macos-latest, windows-latest, ubuntu-latest), build + test on every push, artifacts on tag.

## Repository layout & migration

- New code lives in this repo on branch `rust-rewrite` (already cut from `feat/impl-phases-1-4-9` HEAD as of `0252052`). Eventually merges to `main`.
- The Swift v1 sources (`App/`, `VideoCoachCore/`, `VideoCoach.xcodeproj/`) stay untouched on `main` until the Rust v2 reaches parity. Then we delete them in a single "remove v1" commit at v2 launch.
- `docs/plans/` keeps both the v1 and v2 design docs side by side. v1 plan files (`2026-04-27-*.md`) are historical; this doc is authoritative for v2.

## Testing strategy

- **`video-coach-core`**: pure-logic unit tests with `cargo test`. No GStreamer, no GPU — runs in CI on every push.
- **`video-coach-compositor`**: golden-frame tests. Render known input textures + a known stroke list, hash the output, compare. Runs headlessly in CI with a software wgpu adapter (lavapipe / WARP).
- **`video-coach-media`**: GStreamer integration tests with synthetic test sources (`videotestsrc` / `audiotestsrc`). Verify pipeline construction, end-to-end encode/decode round trips, frame counts. Doesn't require real cameras.
- **End-to-end**: scripted Slint UI tests for the critical paths (new project → record clip → export). Slint has limited UI-test tooling; expect these to be smoke tests, not exhaustive.
- **Visual parity test (preview vs export)**: same input clip + plan, render through preview path and through export path, compare hashes. Must match. Catches divergence the moment it's introduced.

## Phasing (rough — formalized in the implementation plan)

1. Workspace skeleton, `video-coach-core` ported from Swift (data model, project IO, source-time reconstruction, plan generation).
2. GStreamer capture pipeline (camera + mic → file). Shippable as a CLI before any UI.
3. wgpu compositor: PiP + stroke layer. Tested via golden-frame harness.
4. GStreamer export pipeline: file → decode → composite → encode → mux.
5. Slint UI shell, project picker, source-video timeline, basic transport.
6. Recording UI integration.
7. Clip preview integration (compositor surface → Slint image).
8. Export sheet UI.
9. Polish, packaging, cross-platform CI green.

## Open questions

- **Audio mixing**: in v1 source-volume and commentary-volume sliders are global project preferences. v2 keeps that. GStreamer's `audiomixer` element handles the live mix cleanly. Confirm the mix happens server-side (in the encode pipeline) and not in the UI layer.
- **Stroke replay timing**: v1's `StrokeReplay.swift` reconstructs stroke timing from event logs; the algorithm should port verbatim. Verify the porting preserves timing semantics with a golden-event-log test.
- **Hardened-runtime / signing on macOS**: v1 was personal-use unsigned. v2 may distribute more broadly — decide on Developer ID signing and notarization scope when packaging matters.
