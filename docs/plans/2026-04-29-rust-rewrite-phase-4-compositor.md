# Phase 4: wgpu Compositor (PiP) — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land a standalone `video-coach-compositor` crate that takes two RGBA frames (a "source" and a "webcam") and produces a single composited RGBA frame with the webcam scaled and placed in the bottom-right corner. Headless. No GStreamer integration yet. Output verified by golden-frame tests in CI.

**Architecture:** A `Compositor` owns a wgpu device + queue + render pipeline. `Compositor::compose(source, webcam) -> Frame` uploads two textures, renders into an offscreen color attachment, and reads back as an RGBA8 byte buffer. PiP geometry matches v1 design (webcam at 22% of source width, 2.2% margin from bottom-right). WGSL shaders (modern wgpu standard).

**Tech Stack:** `wgpu = "22"` (matches the recent stable line), `bytemuck` for vertex/uniform packing, `pollster` for awaiting `wgpu::Adapter::request_adapter` synchronously in tests. Headless backends — `Backends::PRIMARY` lets the OS pick (Metal on macOS, Vulkan/lavapipe on Linux, D3D12 on Windows). CI's Linux runner needs `mesa-vulkan-drivers` for lavapipe (software Vulkan).

**Scope refinements (defer to Phase 5+):**
- Stroke overlay rendering (vector strokes → triangle strips with width)
- Wiring the compositor into the GStreamer recording pipeline (`appsink → compositor → appsrc`)
- Live preview surface (Slint integration)
- NV12 / I420 input formats (Phase 4 uses RGBA8 only; conversions live in the GStreamer bridge)
- Visual parity test (preview vs export) — requires both paths to exist

Phase 4's bar: **the compositor produces a composited image with the webcam visibly scaled and placed in the corner of the source, verified by a hash of the output bytes.**

---

## Task 1: Bootstrap `video-coach-compositor` crate

**Files:**
- Create: `crates/video-coach-compositor/Cargo.toml`
- Create: `crates/video-coach-compositor/src/lib.rs`
- Modify: root `Cargo.toml` (workspace members)

**Step 1: Add to workspace.** Append `"crates/video-coach-compositor"` to `members`.

**Step 2: Manifest.**

```toml
# crates/video-coach-compositor/Cargo.toml
[package]
name = "video-coach-compositor"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
wgpu = "22"
bytemuck = { version = "1", features = ["derive"] }
pollster = "0.3"
thiserror = { workspace = true }
tracing = "0.1"
```

**Step 3: Placeholder `lib.rs`.**

```rust
// crates/video-coach-compositor/src/lib.rs
// Modules added in subsequent tasks.

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        // Crate compiles; runtime smoke happens in Task 3.
    }
}
```

**Step 4: Verify build.**

```bash
cargo build -p video-coach-compositor
cargo test -p video-coach-compositor
```

Both must succeed. wgpu's first compile takes a while (large dep graph); subsequent rebuilds are cached.

**Step 5: Commit.**

```bash
git add Cargo.toml Cargo.lock crates/video-coach-compositor/
git commit -m "feat(compositor): bootstrap video-coach-compositor crate"
```

---

## Task 2: Define `Frame` + `Compositor` types

**Files:**
- Create: `crates/video-coach-compositor/src/frame.rs`
- Create: `crates/video-coach-compositor/src/compositor.rs`
- Modify: `crates/video-coach-compositor/src/lib.rs`

**Step 1: `Frame` type.**

```rust
// crates/video-coach-compositor/src/frame.rs

/// An RGBA8 pixel buffer with explicit dimensions. Row-major, top-left origin,
/// no padding (bytes_per_row == width * 4). All compositor inputs and outputs
/// use this format; format conversion to/from GStreamer's NV12/I420 happens
/// in the bridge layer (Phase 5+).
#[derive(Debug, Clone)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

impl Frame {
    pub fn new(width: u32, height: u32, pixels: Vec<u8>) -> Self {
        debug_assert_eq!(
            pixels.len(),
            (width * height * 4) as usize,
            "RGBA8 frame must have width*height*4 bytes",
        );
        Self { width, height, pixels }
    }

    /// Solid-color frame for tests.
    pub fn solid(width: u32, height: u32, rgba: [u8; 4]) -> Self {
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for _ in 0..(width * height) {
            pixels.extend_from_slice(&rgba);
        }
        Self::new(width, height, pixels)
    }
}
```

**Step 2: `Compositor` skeleton.**

```rust
// crates/video-coach-compositor/src/compositor.rs
use thiserror::Error;
use crate::frame::Frame;

#[derive(Debug, Error)]
pub enum CompositorError {
    #[error("no compatible wgpu adapter available")]
    NoAdapter,
    #[error("device request failed: {0}")]
    DeviceRequest(#[from] wgpu::RequestDeviceError),
    #[error("readback failed: {0}")]
    Readback(String),
}

pub struct Compositor {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
}

impl Compositor {
    /// Build a headless compositor on the OS's preferred backend.
    pub fn new_headless() -> Result<Self, CompositorError> {
        pollster::block_on(Self::new_headless_async())
    }

    async fn new_headless_async() -> Result<Self, CompositorError> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: None,
                force_fallback_adapter: false,
            })
            .await
            .ok_or(CompositorError::NoAdapter)?;
        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("video-coach-compositor"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::downlevel_defaults(),
                    memory_hints: wgpu::MemoryHints::Performance,
                },
                None,
            )
            .await?;
        Ok(Self { device, queue })
    }

    pub fn compose(
        &self,
        _source: &Frame,
        _webcam: &Frame,
    ) -> Result<Frame, CompositorError> {
        // Real implementation lands in Task 4.
        Err(CompositorError::Readback("not implemented yet".into()))
    }
}
```

**Step 3: Wire modules.** In `lib.rs`:

```rust
pub mod compositor;
pub mod frame;

pub use compositor::{Compositor, CompositorError};
pub use frame::Frame;

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        // Module wiring verified — runtime tests in subsequent tasks.
    }
}
```

**Step 4: Verify.** `cargo build -p video-coach-compositor`; `cargo fmt --check`; `cargo clippy --workspace --all-targets -- -D warnings`. Test count unchanged.

**Step 5: Commit.**

```bash
git add crates/video-coach-compositor/src/
git commit -m "feat(compositor): Frame + Compositor::new_headless skeleton"
```

---

## Task 3: Implement `Compositor::compose` for solid-color passthrough

Proof of life: ignore the webcam input, just copy the source frame through a wgpu round trip and verify the output bytes match. If this works, the device → render pass → readback path is solid.

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs`
- Create: `crates/video-coach-compositor/src/shaders/passthrough.wgsl`

**Step 1: Passthrough WGSL.**

```wgsl
// crates/video-coach-compositor/src/shaders/passthrough.wgsl

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var src_sampler: sampler;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) idx: u32) -> VsOut {
    // Three-vertex covering triangle (the standard fullscreen trick).
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0),
    );
    var uvs = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(2.0, 1.0),
        vec2<f32>(0.0, -1.0),
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    out.uv  = uvs[idx];
    return out;
}

@fragment
fn fs_passthrough(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(src_tex, src_sampler, in.uv);
}
```

**Step 2: Replace `Compositor::compose`** with a real wgpu render pass that:

1. Uploads `source.pixels` into a `wgpu::Texture` (RGBA8UnormSrgb? — see note below).
2. Creates a render target texture of the same dimensions.
3. Runs the passthrough pipeline.
4. Reads the render target back into a `Vec<u8>` via a buffer + `device.poll(MaintainBase::Wait)`.
5. Returns a `Frame` with the read-back bytes.

**Format note:** Use `wgpu::TextureFormat::Rgba8Unorm` (NOT `Rgba8UnormSrgb`) so the bytes are passed through linearly — sRGB would apply gamma during sampling and the round-trip wouldn't be byte-identical. Phase 5+ can revisit when actual color management matters.

The body is long enough that the implementer should place it in `compositor.rs` directly. Key API calls:
- `wgpu::util::DeviceExt::create_texture_with_data` for the source upload
- `device.create_shader_module(wgpu::include_wgsl!("shaders/passthrough.wgsl"))`
- `device.create_render_pipeline(...)` with a single bind group layout
- A staging buffer with `MAP_READ | COPY_DST` usage; `device.poll(...)` after `submit`; `slice.map_async` then `slice.get_mapped_range()`.

**Bytes-per-row alignment:** wgpu requires `bytes_per_row` on `ImageDataLayout` to be a multiple of `COPY_BYTES_PER_ROW_ALIGNMENT` (256). For widths whose `width * 4` isn't a multiple of 256, compute padded `bytes_per_row` and strip padding when reading back. Use the helper:

```rust
fn padded_bytes_per_row(width: u32) -> u32 {
    let unpadded = width * 4;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    (unpadded + align - 1) / align * align
}
```

**Step 3: Test.** Append to `lib.rs`'s `#[cfg(test)] mod tests` (or split into a per-module test mod):

```rust
#[test]
fn passthrough_returns_input_bytes() {
    let comp = Compositor::new_headless().expect("compositor");
    let source = Frame::solid(64, 64, [200, 100, 50, 255]);
    let webcam = Frame::solid(32, 32, [0, 0, 0, 255]); // unused in passthrough
    let out = comp.compose(&source, &webcam).expect("compose");
    assert_eq!(out.width, 64);
    assert_eq!(out.height, 64);
    // Allow tiny rounding from sample/blit; compare a center pixel.
    let i = ((32 * 64 + 32) * 4) as usize;
    let center = &out.pixels[i..i + 4];
    assert!(
        (center[0] as i32 - 200).abs() <= 2 &&
        (center[1] as i32 - 100).abs() <= 2 &&
        (center[2] as i32 -  50).abs() <= 2 &&
        center[3] == 255,
        "center pixel diverged: {:?}", center
    );
}
```

64×64 is small enough to be fast and large enough that any `bytes_per_row` padding bug surfaces (256 / 4 = 64, so width=64 is the boundary case).

**Step 4: Verify.** `cargo test -p video-coach-compositor` runs locally with the OS's preferred backend (Metal on macOS). Test should pass. fmt + clippy clean.

**Step 5: Commit.**

```bash
git add crates/video-coach-compositor/src/
git commit -m "feat(compositor): passthrough render — texture round-trip via wgpu"
```

---

## Task 4: PiP composite (webcam scaled into corner of source)

The actual feature. Source fills the frame; webcam is drawn on top at 22% width, 2.2% margin from bottom-right (matches v1 `pipTransform` constants).

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs`
- Create: `crates/video-coach-compositor/src/shaders/pip.wgsl`

**Step 1: PiP WGSL.**

```wgsl
// crates/video-coach-compositor/src/shaders/pip.wgsl

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var webcam_tex: texture_2d<f32>;
@group(0) @binding(2) var lin_sampler: sampler;

struct PipParams {
    // PiP rectangle in normalized output coords (0..1, top-left origin).
    pip_x:      f32,
    pip_y:      f32,
    pip_w:      f32,
    pip_h:      f32,
};
@group(0) @binding(3) var<uniform> params: PipParams;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) idx: u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0),
    );
    var uvs = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(2.0, 1.0),
        vec2<f32>(0.0, -1.0),
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    out.uv  = uvs[idx];
    return out;
}

@fragment
fn fs_pip(in: VsOut) -> @location(0) vec4<f32> {
    let src = textureSample(src_tex, lin_sampler, in.uv);

    // Inside the PiP rectangle, sample the webcam and overlay it opaquely.
    if (in.uv.x >= params.pip_x && in.uv.x < params.pip_x + params.pip_w &&
        in.uv.y >= params.pip_y && in.uv.y < params.pip_y + params.pip_h) {
        let pip_uv = vec2<f32>(
            (in.uv.x - params.pip_x) / params.pip_w,
            (in.uv.y - params.pip_y) / params.pip_h,
        );
        return textureSample(webcam_tex, lin_sampler, pip_uv);
    }

    return src;
}
```

**Step 2: PiP geometry constants.** In `compositor.rs`:

```rust
/// PiP geometry matches v1's `pipTransform`: webcam at 22% of output width,
/// 2.2% margin from bottom-right. Aspect-ratio preserved via webcam frame
/// dimensions (the shader maps the rectangle uniformly).
const PIP_WIDTH_FRACTION: f32 = 0.22;
const PIP_MARGIN_FRACTION: f32 = 0.022;

fn pip_rect(out_w: u32, out_h: u32, webcam_w: u32, webcam_h: u32) -> [f32; 4] {
    let pip_w = PIP_WIDTH_FRACTION;
    let aspect = webcam_h as f32 / webcam_w.max(1) as f32;
    let pip_h = pip_w * aspect * (out_w as f32 / out_h.max(1) as f32);
    let margin_y = PIP_MARGIN_FRACTION;
    let margin_x = PIP_MARGIN_FRACTION * (out_h as f32 / out_w.max(1) as f32);
    let pip_x = 1.0 - pip_w - margin_x;
    let pip_y = 1.0 - pip_h - margin_y;
    [pip_x, pip_y, pip_w, pip_h]
}
```

**Step 3: Add a uniform buffer to `Compositor`.** Replace `compose` to bind both textures + the uniform.

The render path now:
1. Upload source → texture A.
2. Upload webcam → texture B.
3. Write `pip_rect(...)` into a `wgpu::Buffer` (UNIFORM | COPY_DST).
4. Build a bind group with both textures + sampler + uniform.
5. Run a single draw call (3 vertices, fullscreen triangle).
6. Readback as before.

**Step 4: Golden-frame test.**

```rust
#[test]
fn pip_places_webcam_in_bottom_right() {
    let comp = Compositor::new_headless().expect("compositor");

    // Source: solid red. Webcam: solid blue. After compose, the
    // top-left of the output should be red and the bottom-right region
    // should be blue.
    let source = Frame::solid(640, 360, [255, 0, 0, 255]);
    let webcam = Frame::solid(160, 90, [0, 0, 255, 255]);
    let out = comp.compose(&source, &webcam).expect("compose");

    let sample = |x: u32, y: u32| -> [u8; 4] {
        let i = ((y * out.width + x) * 4) as usize;
        [out.pixels[i], out.pixels[i+1], out.pixels[i+2], out.pixels[i+3]]
    };

    // Top-left (well outside the PiP) is the source color.
    let tl = sample(8, 8);
    assert_eq!(tl[..3], [255, 0, 0], "top-left should be red, got {:?}", tl);

    // Pixel near the bottom-right margin is inside the PiP and should be webcam blue.
    let br = sample(out.width - 12, out.height - 12);
    assert!((br[2] as i32 - 255).abs() <= 4,
            "bottom-right should be webcam blue, got {:?}", br);
}
```

**Step 5: Verify.** `cargo test -p video-coach-compositor` should run all 3 tests (smoke, passthrough, pip) — each takes a fraction of a second on macOS. fmt + clippy clean.

**Step 6: Commit.**

```bash
git add crates/video-coach-compositor/src/
git commit -m "feat(compositor): PiP composite — webcam scaled into bottom-right of source"
```

---

## Task 5: Golden-frame hash test

Add a test that pins the EXACT byte hash of a known input → output. Catches accidental shader regressions, sampler config changes, or driver-version differences.

**Files:** Modify `crates/video-coach-compositor/src/compositor.rs` (or a new `tests/golden.rs` integration test).

**Step 1: Pick the canonical inputs.** Use 320×180 to keep the bytes small and the hash compact.

```rust
// inside the existing test mod
use sha2::{Digest, Sha256};

fn pixel_grid(w: u32, h: u32, scale: u8) -> Frame {
    let mut pixels = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            // Distinguishable per-pixel so any shader bug shows.
            pixels.extend_from_slice(&[(x * scale as u32) as u8, (y * scale as u32) as u8, 128, 255]);
        }
    }
    Frame::new(w, h, pixels)
}

#[test]
fn pip_320x180_matches_golden_hash() {
    let comp = Compositor::new_headless().expect("compositor");
    let source = pixel_grid(320, 180, 1);
    let webcam = pixel_grid(160, 90, 3);
    let out = comp.compose(&source, &webcam).expect("compose");
    let mut hasher = Sha256::new();
    hasher.update(&out.pixels);
    let hex = format!("{:x}", hasher.finalize());

    // Expected hash: filled in on first run via:
    //   cargo test -p video-coach-compositor pip_320x180_matches_golden -- --nocapture
    // ...then paste the printed hash here.
    let expected = "<TODO-FILL-AFTER-FIRST-RUN>";
    assert_eq!(hex, expected, "golden frame mismatch");
}
```

**Step 2: First-run dance.** The implementer runs the test once with `eprintln!("{hex}");` instead of `assert_eq!`, captures the actual hash, pastes it as the `expected`, then re-runs to confirm match. Add `sha2 = "0.10"` to `[dev-dependencies]` in the compositor crate.

**Step 3: Commit.**

```bash
git add crates/video-coach-compositor/Cargo.toml crates/video-coach-compositor/src/ Cargo.lock
git commit -m "test(compositor): pin golden-frame hash for PiP at 320x180"
```

---

## Task 6: CI — install Vulkan loader for headless wgpu on Linux

The compositor tests run on the `test` matrix's Linux runner. Linux has no GPU; wgpu falls back to lavapipe (software Vulkan) but only if the Vulkan loader + lavapipe driver are installed.

**Files:** Modify `.github/workflows/rust.yml`.

**Step 1: Add Linux install step in the `test` job.**

```yaml
      - name: Install Vulkan + lavapipe (Ubuntu only)
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y libvulkan1 mesa-vulkan-drivers vulkan-tools
```

Place this BEFORE the `cargo build`/`cargo test` steps. macOS uses Metal natively; Windows uses D3D12. No install needed there.

**Step 2: Push and verify.**

Implementer commits the workflow change but does NOT push; the controller will push and watch the matrix.

```bash
git add .github/workflows/rust.yml
git commit -m "ci: install lavapipe so headless wgpu has a software Vulkan adapter on Linux"
```

---

## Phase 4 exit criteria

- All tasks committed.
- `cargo test -p video-coach-compositor` green locally on macOS.
- `cargo build -p video-coach-app --release --no-default-features` still clean — compositor is NOT yet wired into the app, so this should be unaffected.
- CI `test` matrix green on macOS / Windows / Linux.
- The `pip_places_webcam_in_bottom_right` and `pip_320x180_matches_golden_hash` tests both pass on Linux CI (proving lavapipe gives reproducible output).

When this is green, Phase 5 starts wiring the compositor into the GStreamer recording pipeline (appsink → wgpu → appsrc) and adds the stroke overlay.
