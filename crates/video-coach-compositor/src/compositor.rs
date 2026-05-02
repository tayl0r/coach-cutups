use crate::frame::Frame;
use std::sync::{Arc, Mutex};
use thiserror::Error;
use video_coach_core::stroke_replay::VisibleStroke;
use wgpu::util::DeviceExt;

#[cfg(test)]
use std::sync::atomic::AtomicU64;

#[derive(Debug, Error)]
pub enum CompositorError {
    #[error("no compatible wgpu adapter available")]
    NoAdapter,
    #[error("device request failed: {0}")]
    DeviceRequest(#[from] wgpu::RequestDeviceError),
    #[error("readback failed: {0}")]
    Readback(String),
}

/// Per-vertex layout for the stroke pass. See `shaders/strokes.wgsl` for the
/// matching `VertexIn` struct. Each rendered line segment emits 4 vertices
/// (two triangles) with the same `segment_a/b` + `half_width` + `color`; the
/// `position` differs per corner of the quad.
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct StrokeVertex {
    position: [f32; 2],
    segment_a: [f32; 2],
    segment_b: [f32; 2],
    half_width: f32,
    _pad: f32, // align color to 16 bytes
    color: [f32; 4],
}

/// Phase 9 fixed line width: 4 pixels at 1080p output ≈ 0.0037 in [0,1] space.
/// Phase 10/11 may make this resolution-aware via a uniform; for now a fixed
/// value keeps the API surface small. Captured strokes' own `line_width` field
/// is normalized to frame height too — we use the larger of the two so that
/// captured widths still scale up if the user authored them wide, but never
/// shrink below the minimum-readable threshold.
const PHASE9_MIN_HALF_WIDTH: f32 = 0.0037 / 2.0;

/// AA quad expansion in [0,1] space — vertices are pushed slightly past the
/// half-width on each side so the fragment shader's smoothstep falloff has
/// room to fade. Must exceed the shader's `feather` constant; 2× is a safe
/// margin without making the quads visibly oversized.
const STROKE_QUAD_AA_PAD: f32 = 0.0025;

pub struct Compositor {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,

    // Plan #4 Task 1: cached PiP + stroke pipelines, rebuilt only when
    // the key changes. wgpu handles inside (RenderPipeline / BGL /
    // Sampler / ShaderModule) are Clone (refcounted Arc). Per Fix #41,
    // the lock is held only for cache-lookup-and-clone-out; encode
    // happens unlocked.
    pub(crate) pip_cache: Mutex<Option<PipPassCache>>,
    pub(crate) stroke_cache: Mutex<Option<StrokePassCache>>,

    // Plan #4 Task 2: pooled stroke vertex buffer. Capacity grows on
    // demand; never shrinks. wgpu::Buffer is Clone — same lock
    // discipline as Task 1 (clone-out, drop, encode). (Task 0:
    // scaffolded but not yet wired.)
    #[allow(dead_code)]
    pub(crate) stroke_vbo_pool: Mutex<Option<PooledVbo>>,

    // Plan #4 Task 3: freeze-segment compose memoization. LRU bounded
    // at 16 entries (~128 MB peak at 1080p RGBA — disclosed in
    // compose_tick docstring per Fix #49). Key includes content-derived
    // prefix bytes per Fix #43 to defend against allocator address
    // reuse. Value is Arc<Frame> per Fix #44 so cache hits don't
    // memcpy. Wired in Task 3 via compose_with_identity.
    pub(crate) freeze_cache: Mutex<FreezeCache>,

    // Plan #4: test-only counters for cache-rebuild assertions
    // (Fix #47). Crate-local; not visible to other crates' tests.
    // Tasks 1–3 wire the increments; Task 0 just scaffolds the fields.
    #[cfg(test)]
    pub(crate) pip_cache_rebuilds: AtomicU64,
    #[cfg(test)]
    pub(crate) stroke_cache_rebuilds: AtomicU64,
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) stroke_vbo_grows: AtomicU64,
    #[cfg(test)]
    pub(crate) freeze_cache_hits: AtomicU64,
}

// Cache key intent: the cached pipeline + BGL are dimension-agnostic
// (vs_fullscreen has no per-instance state, fs_pip samples by UV, the
// PiP rect goes through a per-call uniform buffer — see compose's
// `uniform_buf` at the call site). Including webcam_w/h or output
// dimensions would cause spurious rebuilds across clips with different
// webcam shapes WITHOUT improving correctness. If a future change adds
// dimension-baked constants to the shader (e.g. HDR / 10-bit work), the
// key MUST grow accordingly. Audit by inspecting shaders/pip.wgsl.
#[derive(Copy, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) struct PipPassKey {
    pub source_w: u32,
    pub source_h: u32,
}

// wgpu 22's handles (RenderPipeline / BindGroupLayout / Sampler /
// ShaderModule / PipelineLayout) are NOT `Clone` directly — they own the
// drop-side teardown. We wrap them in `Arc` so cache hits clone an Arc
// handle (cheap atomic refcount bump) instead of recreating the GPU
// resource. The Arc lives as long as any caller holds a clone, so the
// underlying `Drop` runs exactly once when the last clone goes away.
#[allow(dead_code)]
pub(crate) struct PipPassCache {
    pub key: PipPassKey,
    pub bind_group_layout: Arc<wgpu::BindGroupLayout>,
    pub pipeline_layout: Arc<wgpu::PipelineLayout>,
    pub pipeline: Arc<wgpu::RenderPipeline>,
    pub sampler: Arc<wgpu::Sampler>,
    pub shader: Arc<wgpu::ShaderModule>,
}

#[derive(Copy, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) struct StrokePassKey {
    // Phase 11: format hardcoded Rgba8Unorm so the key is empty in
    // practice. Future HDR work extends with format/color-space.
    pub _placeholder: u8,
}

#[allow(dead_code)]
pub(crate) struct StrokePassCache {
    pub key: StrokePassKey,
    pub pipeline_layout: Arc<wgpu::PipelineLayout>,
    pub pipeline: Arc<wgpu::RenderPipeline>,
    pub shader: Arc<wgpu::ShaderModule>,
}

#[allow(dead_code)]
pub(crate) struct PooledVbo {
    // wgpu 22's `Buffer` is NOT `Clone` (verified against
    // wgpu-22.1.0/src/lib.rs line 450 — `pub struct Buffer { .. }` with
    // no `derive(Clone)`). To honor Fix #41's lock-discipline rule
    // (drop the Mutex guard BEFORE encode), we wrap in `Arc` so
    // cache-lookup clones an `Arc` handle out (cheap atomic refcount
    // bump), and the underlying GPU resource is dropped exactly once
    // when the last clone goes away. This mirrors the `Arc<…>`
    // wrapping inside `PipPassCache` / `StrokePassCache` for the same
    // reason.
    pub buffer: Arc<wgpu::Buffer>,
    pub capacity_vertices: usize,
}

pub(crate) struct FreezeCache {
    /// LRU. Newest at end. 16-entry cap. Linear scan is fine at N=16.
    /// Per Fix #44, value is `Arc<Frame>` so cache hits clone an Arc
    /// handle (cheap atomic refcount bump), not 8 MB of pixels.
    pub entries: Vec<(FreezeCacheKey, Arc<Frame>)>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct FreezeCacheKey {
    // Per Fix #43, the cache key resists Arc-pointer-address reuse
    // (allocator-slot reuse across drop-then-allocate at clip
    // boundaries) by mixing content-derived prefix bytes alongside the
    // pointer. `first16 + len + dims` cost ~64 bytes/key + a two-prefix
    // copy; negligible vs the 8 MB compose work being cached.
    pub source_ptr: usize, // Arc::as_ptr cast to usize
    pub source_w: u32,
    pub source_h: u32,
    pub source_pixels_len: usize,
    pub source_first16: [u8; 16],
    pub webcam_ptr: usize,
    pub webcam_w: u32,
    pub webcam_h: u32,
    pub webcam_pixels_len: usize,
    pub webcam_first16: [u8; 16],
    pub stroke_hash: u64,
}

/// PiP geometry matches v1's `pipTransform`: webcam at 22% of output width,
/// 2.2% margin from bottom-right. Aspect-ratio preserved via webcam frame
/// dimensions (the shader maps the rectangle uniformly).
const PIP_WIDTH_FRACTION: f32 = 0.22;
const PIP_MARGIN_FRACTION: f32 = 0.022;

fn pip_rect(out_w: u32, out_h: u32, webcam_w: u32, webcam_h: u32) -> [f32; 4] {
    let pip_w = PIP_WIDTH_FRACTION;
    let aspect = webcam_h as f32 / webcam_w.max(1) as f32;
    // The (out_w/out_h) factor compensates: pip_w and pip_h are normalized
    // to the OUTPUT's anisotropic coords, so to get a square-aspect PiP rect
    // for a square-aspect webcam, pip_h must scale by the inverse of the
    // output's aspect ratio.
    let pip_h = pip_w * aspect * (out_w as f32 / out_h.max(1) as f32);
    let margin_y = PIP_MARGIN_FRACTION;
    let margin_x = PIP_MARGIN_FRACTION * (out_h as f32 / out_w.max(1) as f32);
    let pip_x = 1.0 - pip_w - margin_x;
    let pip_y = 1.0 - pip_h - margin_y;
    [pip_x, pip_y, pip_w, pip_h]
}

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct PipParamsUniform {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

fn padded_bytes_per_row(width: u32) -> u32 {
    let unpadded = width * 4;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    unpadded.div_ceil(align) * align
}

impl Compositor {
    /// Build a headless compositor on the OS's preferred backend.
    pub fn new_headless() -> Result<Self, CompositorError> {
        pollster::block_on(Self::new_headless_async())
    }

    async fn new_headless_async() -> Result<Self, CompositorError> {
        // wgpu 22's `Instance::new` takes the descriptor BY VALUE (not by
        // reference). A later wgpu version flipped this; using `&` here
        // produces a type-mismatch compile error against 22.x.
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        // Try a real adapter first (Metal on macOS, native Vulkan/DX12 on
        // Linux/Windows). Fall back to a software adapter so headless Linux
        // CI (lavapipe = software Vulkan) still gets an adapter — macOS has
        // no fallback path, so `force_fallback_adapter: true` alone returns
        // `None` and the pipeline fails before it's built.
        let adapter = match instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: None,
                force_fallback_adapter: false,
            })
            .await
        {
            Some(a) => a,
            None => instance
                .request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::LowPower,
                    compatible_surface: None,
                    force_fallback_adapter: true,
                })
                .await
                .ok_or(CompositorError::NoAdapter)?,
        };
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
        Ok(Self {
            device,
            queue,
            // Plan #4 Task 0: cache scaffolding initialized empty. Tasks
            // 1–3 wire the lookup/insert paths into compose +
            // encode_stroke_pass + compose_with_identity.
            pip_cache: Mutex::new(None),
            stroke_cache: Mutex::new(None),
            stroke_vbo_pool: Mutex::new(None),
            freeze_cache: Mutex::new(FreezeCache {
                entries: Vec::new(),
            }),
            #[cfg(test)]
            pip_cache_rebuilds: AtomicU64::new(0),
            #[cfg(test)]
            stroke_cache_rebuilds: AtomicU64::new(0),
            #[cfg(test)]
            stroke_vbo_grows: AtomicU64::new(0),
            #[cfg(test)]
            freeze_cache_hits: AtomicU64::new(0),
        })
    }

    pub fn compose(
        &self,
        source: &Frame,
        webcam: &Frame,
        strokes: &[VisibleStroke],
    ) -> Result<Frame, CompositorError> {
        let w = source.width;
        let h = source.height;

        // 1. Upload source as a sampled texture.
        let src_tex = self.device.create_texture_with_data(
            &self.queue,
            &wgpu::TextureDescriptor {
                label: Some("source"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                // Rgba8Unorm (NOT Rgba8UnormSrgb) — matches the upload format
                // and the pipeline target so gamma isn't double-converted.
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            },
            wgpu::util::TextureDataOrder::LayerMajor,
            &source.pixels,
        );

        // 1b. Upload webcam as a sampled texture.
        let webcam_tex = self.device.create_texture_with_data(
            &self.queue,
            &wgpu::TextureDescriptor {
                label: Some("webcam"),
                size: wgpu::Extent3d {
                    width: webcam.width,
                    height: webcam.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            },
            wgpu::util::TextureDataOrder::LayerMajor,
            &webcam.pixels,
        );

        // 2. Render target (output is source-sized).
        let target = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("target"),
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });

        // 2b. Uniform buffer with the PiP rectangle.
        let rect = pip_rect(source.width, source.height, webcam.width, webcam.height);
        let uniform = PipParamsUniform {
            x: rect[0],
            y: rect[1],
            w: rect[2],
            h: rect[3],
        };
        let uniform_buf = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("pip-params"),
                contents: bytemuck::bytes_of(&uniform),
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            });

        // 3. Pipeline — cached. Per Fix #41 the Mutex guard is bounded to
        // the cache-lookup-and-clone block; encode below runs unlocked.
        // Per Fix #51 this is a pure-compute path, so panic on poison.
        let pip_key = PipPassKey {
            source_w: w,
            source_h: h,
        };
        let (pip_pipeline, pip_bgl, pip_sampler) = {
            let mut g = self.pip_cache.lock().expect("pip_cache poisoned");
            let needs_rebuild = g.as_ref().map(|c| c.key != pip_key).unwrap_or(true);
            if needs_rebuild {
                #[cfg(test)]
                self.pip_cache_rebuilds
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                *g = Some(self.build_pip_cache(pip_key));
            }
            let c = g.as_ref().expect("populated above");
            (
                c.pipeline.clone(),
                c.bind_group_layout.clone(),
                c.sampler.clone(),
            )
        }; // guard dropped here — encode happens unlocked

        let src_view = src_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let webcam_view = webcam_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("pip-bg"),
            layout: &pip_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&src_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&webcam_view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&pip_sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: uniform_buf.as_entire_binding(),
                },
            ],
        });

        // 4. Encode + submit.
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("compose-encoder"),
            });
        {
            let target_view = target.create_view(&wgpu::TextureViewDescriptor::default());
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("compose-pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &target_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            rpass.set_pipeline(&pip_pipeline);
            rpass.set_bind_group(0, &bind_group, &[]);
            rpass.draw(0..3, 0..1);
        }

        // 4b. Stroke pass — only build resources + encode if there's something
        // to draw. Per fix #4, we render in [0,1] space directly (Phase 9
        // ships only 16:9 → 16:9). EARLY-RETURN-style guard: when no strokes
        // are present we skip pipeline construction entirely so the
        // no-strokes path is byte-identical to the pre-Phase-9 PiP-only
        // output (this is what keeps the macOS golden hash stable).
        if !strokes.is_empty() {
            let vertices = build_stroke_vertices(strokes);
            if !vertices.is_empty() {
                self.encode_stroke_pass(&mut encoder, &target, &vertices);
            }
        }

        // 5. Copy render target → staging buffer (with row alignment).
        let bytes_per_row = padded_bytes_per_row(w);
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback-staging"),
            size: (bytes_per_row * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        encoder.copy_texture_to_buffer(
            wgpu::ImageCopyTexture {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::ImageCopyBuffer {
                buffer: &staging,
                layout: wgpu::ImageDataLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(h),
                },
            },
            wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit(Some(encoder.finish()));

        // 6. Map + read back.
        let slice = staging.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        // wgpu 22: `device.poll(...)` takes `Maintain::Wait` (NOT
        // `MaintainBase::Wait`); returns `MaintainResult` — bind to `_` so
        // clippy under `-D warnings` doesn't complain about unused result.
        let _ = self.device.poll(wgpu::Maintain::Wait);
        rx.recv()
            .map_err(|e| CompositorError::Readback(format!("recv: {e}")))?
            .map_err(|e| CompositorError::Readback(format!("map_async: {e}")))?;

        let mapped = slice.get_mapped_range();
        let mut pixels = Vec::with_capacity((w * h * 4) as usize);
        let unpadded = (w * 4) as usize;
        for row in 0..h as usize {
            let start = row * bytes_per_row as usize;
            pixels.extend_from_slice(&mapped[start..start + unpadded]);
        }
        drop(mapped);
        staging.unmap();

        Ok(Frame::new(w, h, pixels))
    }

    /// Plan #4 Task 3: compose path with Arc-pointer identity caching for
    /// freeze segments. The preview/export driver hands the SAME
    /// `Arc<Frame>` pair (frozen source + last-known webcam) for every
    /// tick inside a Freeze segment; strokes only change at event
    /// boundaries. Per Fix #43 the cache key mixes Arc-pointer identity
    /// with a content-derived prefix (first 16 bytes + len + dims) to
    /// defend against allocator address reuse across segment edges.
    /// Per Fix #44 the value is `Arc<Frame>` so cache hits return a
    /// cheap refcount bump, not an 8 MB pixel clone.
    ///
    /// On a cache hit this returns the SAME `Arc<Frame>` previously
    /// inserted (so callers can `Arc::ptr_eq` if they need that
    /// invariant). On a miss it composes via `compose` and inserts
    /// before returning.
    pub fn compose_with_identity(
        &self,
        source: &Arc<Frame>,
        webcam: &Arc<Frame>,
        strokes: &[VisibleStroke],
    ) -> Result<Arc<Frame>, CompositorError> {
        let key = FreezeCacheKey {
            source_ptr: Arc::as_ptr(source) as usize,
            source_w: source.width,
            source_h: source.height,
            source_pixels_len: source.pixels.len(),
            source_first16: first16_or_zero(&source.pixels),
            webcam_ptr: Arc::as_ptr(webcam) as usize,
            webcam_w: webcam.width,
            webcam_h: webcam.height,
            webcam_pixels_len: webcam.pixels.len(),
            webcam_first16: first16_or_zero(&webcam.pixels),
            stroke_hash: hash_stroke_set(strokes),
        };

        if let Some(cached) = self.lookup_freeze(&key) {
            #[cfg(test)]
            self.freeze_cache_hits
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            return Ok(cached);
        }

        let composed = self.compose(source.as_ref(), webcam.as_ref(), strokes)?;
        let arc_composed = Arc::new(composed);
        self.insert_freeze(key, arc_composed.clone());
        Ok(arc_composed)
    }

    /// Per Fix #51: freeze cache is a user-data path, so poison-recover
    /// rather than panic. Lock held only for the linear scan; result
    /// `Arc<Frame>` cloned out before guard drops.
    fn lookup_freeze(&self, key: &FreezeCacheKey) -> Option<Arc<Frame>> {
        let g = match self.freeze_cache.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        g.entries
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
    }

    /// 16-entry LRU. Newest at end; eviction pops the oldest from the
    /// front. Re-inserts of an existing key are deduped (retain != key)
    /// so the entry rotates to the back as "most-recently-used".
    fn insert_freeze(&self, key: FreezeCacheKey, frame: Arc<Frame>) {
        const LRU_CAP: usize = 16;
        let mut g = match self.freeze_cache.lock() {
            Ok(g) => g,
            Err(p) => {
                tracing::warn!(
                    target: "compositor.cache",
                    event = "compositor.cache_poisoned",
                    which = "freeze",
                );
                p.into_inner()
            }
        };
        g.entries.retain(|(k, _)| k != &key);
        if g.entries.len() >= LRU_CAP {
            g.entries.remove(0);
        }
        g.entries.push((key, frame));
    }

    /// Drop every cached freeze-compose entry. Called by the production
    /// drivers at segment-index transitions (preview) and at entry
    /// boundaries (export) per Fix #43 — content-prefix-defended keys
    /// already make stale-Arc hits impossible, but proactively clearing
    /// avoids a pathological 16-entry-per-segment build-up across long
    /// timelines.
    pub fn clear_freeze_cache(&self) {
        let mut g = match self.freeze_cache.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        g.entries.clear();
    }

    /// Encodes the stroke render pass onto `encoder`, writing into `target`
    /// using `LoadOp::Load` so the previous PiP pass's pixels are preserved
    /// and the strokes blend on top via `ALPHA_BLENDING`. Caller MUST ensure
    /// `vertices` is non-empty.
    fn encode_stroke_pass(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::Texture,
        vertices: &[StrokeVertex],
    ) {
        // Fix #50: caller (compose at line ~450) already filters empty
        // vertex slices; lock that invariant in so a future regression
        // can't pass through to a zero-byte write_buffer call.
        debug_assert!(
            !vertices.is_empty(),
            "encode_stroke_pass called with empty vertex slice"
        );
        let bytes = bytemuck::cast_slice(vertices);
        let needed_bytes = bytes.len();

        // Plan #4 Task 2: pooled VBO. Lookup-grow-clone-out under the
        // guard, then drop the guard before queue.write_buffer +
        // set_vertex_buffer (Fix #41). wgpu::Buffer in wgpu 22 IS Clone
        // (refcounted internally), so cloning the handle is a cheap
        // atomic refcount bump — no Arc wrapper needed. Pure-compute
        // path so .expect() on poison per Fix #51.
        let buffer = {
            let mut g = self
                .stroke_vbo_pool
                .lock()
                .expect("stroke_vbo_pool poisoned");
            let need_grow = match g.as_ref() {
                None => true,
                Some(p) => p.capacity_vertices * std::mem::size_of::<StrokeVertex>() < needed_bytes,
            };
            if need_grow {
                #[cfg(test)]
                self.stroke_vbo_grows
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let new_cap = vertices.len().next_power_of_two().max(64);
                let new_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("stroke-vbo-pool"),
                    size: (new_cap * std::mem::size_of::<StrokeVertex>()) as u64,
                    usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                });
                *g = Some(PooledVbo {
                    buffer: Arc::new(new_buffer),
                    capacity_vertices: new_cap,
                });
            }
            g.as_ref().expect("populated above").buffer.clone()
        }; // guard dropped here

        // Cached pipeline. Per Fix #41 the guard is dropped before encode;
        // per Fix #51 this is a pure-compute path so panic on poison.
        let stroke_key = StrokePassKey { _placeholder: 0 };
        let stroke_pipeline = {
            let mut g = self.stroke_cache.lock().expect("stroke_cache poisoned");
            let needs_rebuild = g.as_ref().map(|c| c.key != stroke_key).unwrap_or(true);
            if needs_rebuild {
                #[cfg(test)]
                self.stroke_cache_rebuilds
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                *g = Some(self.build_stroke_cache(stroke_key));
            }
            g.as_ref().expect("populated above").pipeline.clone()
        }; // guard dropped here

        // Upload after both guards have dropped. wgpu 22 guarantees the
        // DMA copy scheduled by Queue::write_buffer is ordered before
        // the encoder's commands when they share a single queue.submit
        // (the same single-submit flow already used in compose).
        self.queue.write_buffer(&buffer, 0, bytes);

        let target_view = target.create_view(&wgpu::TextureViewDescriptor::default());
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("stroke-pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        rpass.set_pipeline(&stroke_pipeline);
        // Slice to the live byte range so the trailing pool capacity is
        // invisible to the render pass (the buffer may be sized > needed).
        rpass.set_vertex_buffer(0, buffer.slice(..needed_bytes as u64));
        let vertex_count = vertices.len() as u32;
        rpass.draw(0..vertex_count, 0..1);
    }

    /// Build a fresh PiP pass cache entry. Called from `compose` only when
    /// the cache key changes (or on first use). All wgpu handles inside
    /// `PipPassCache` are refcounted — clone-out is cheap.
    ///
    /// Per the `PipPassKey` cache-key intent comment above, the construction
    /// is dimension-agnostic; `key.source_w` / `key.source_h` are stored on
    /// the returned cache for future-proofing only and are NOT used here.
    fn build_pip_cache(&self, key: PipPassKey) -> PipPassCache {
        let shader = self
            .device
            .create_shader_module(wgpu::include_wgsl!("shaders/pip.wgsl"));
        let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });
        let bind_group_layout =
            self.device
                .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                    label: Some("pip-bgl"),
                    entries: &[
                        wgpu::BindGroupLayoutEntry {
                            binding: 0,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Texture {
                                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                                view_dimension: wgpu::TextureViewDimension::D2,
                                multisampled: false,
                            },
                            count: None,
                        },
                        wgpu::BindGroupLayoutEntry {
                            binding: 1,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Texture {
                                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                                view_dimension: wgpu::TextureViewDimension::D2,
                                multisampled: false,
                            },
                            count: None,
                        },
                        wgpu::BindGroupLayoutEntry {
                            binding: 2,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                            count: None,
                        },
                        wgpu::BindGroupLayoutEntry {
                            binding: 3,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Buffer {
                                ty: wgpu::BufferBindingType::Uniform,
                                has_dynamic_offset: false,
                                min_binding_size: None,
                            },
                            count: None,
                        },
                    ],
                });
        let pipeline_layout = self
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("pip-layout"),
                bind_group_layouts: &[&bind_group_layout],
                push_constant_ranges: &[],
            });
        let pipeline = self
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("pip-pipeline"),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: "vs_fullscreen",
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: "fs_pip",
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: wgpu::TextureFormat::Rgba8Unorm,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview: None,
                // wgpu 22 added this field; absence is a compile error.
                cache: None,
            });
        PipPassCache {
            key,
            bind_group_layout: Arc::new(bind_group_layout),
            pipeline_layout: Arc::new(pipeline_layout),
            pipeline: Arc::new(pipeline),
            sampler: Arc::new(sampler),
            shader: Arc::new(shader),
        }
    }

    /// Build a fresh stroke pass cache entry. Called from
    /// `encode_stroke_pass` only on first use (the key is currently a
    /// `_placeholder: u8` singleton — see `StrokePassKey`).
    fn build_stroke_cache(&self, key: StrokePassKey) -> StrokePassCache {
        let shader = self
            .device
            .create_shader_module(wgpu::include_wgsl!("shaders/strokes.wgsl"));
        let pipeline_layout = self
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("stroke-layout"),
                bind_group_layouts: &[],
                push_constant_ranges: &[],
            });
        let pipeline = self
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("stroke-pipeline"),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: "vs_stroke",
                    compilation_options: Default::default(),
                    buffers: &[wgpu::VertexBufferLayout {
                        array_stride: std::mem::size_of::<StrokeVertex>() as u64,
                        step_mode: wgpu::VertexStepMode::Vertex,
                        attributes: &[
                            // position
                            wgpu::VertexAttribute {
                                format: wgpu::VertexFormat::Float32x2,
                                offset: 0,
                                shader_location: 0,
                            },
                            // segment_a
                            wgpu::VertexAttribute {
                                format: wgpu::VertexFormat::Float32x2,
                                offset: 8,
                                shader_location: 1,
                            },
                            // segment_b
                            wgpu::VertexAttribute {
                                format: wgpu::VertexFormat::Float32x2,
                                offset: 16,
                                shader_location: 2,
                            },
                            // half_width (single f32; the _pad slot is skipped)
                            wgpu::VertexAttribute {
                                format: wgpu::VertexFormat::Float32,
                                offset: 24,
                                shader_location: 3,
                            },
                            // color (16-byte aligned via _pad)
                            wgpu::VertexAttribute {
                                format: wgpu::VertexFormat::Float32x4,
                                offset: 32,
                                shader_location: 4,
                            },
                        ],
                    }],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: "fs_stroke",
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: wgpu::TextureFormat::Rgba8Unorm,
                        blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::TriangleList,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview: None,
                cache: None,
            });
        StrokePassCache {
            key,
            pipeline_layout: Arc::new(pipeline_layout),
            pipeline: Arc::new(pipeline),
            shader: Arc::new(shader),
        }
    }
}

/// Per Fix #43: copy the first 16 bytes of `pixels` (zero-padding if
/// shorter) into a fixed-size array. Used by `FreezeCacheKey` as a
/// content-derived prefix that defends the cache against allocator
/// address reuse — when an `Arc<Frame>` drops at a segment boundary and
/// the next clip's freeze-frame happens to land at the same heap slot,
/// the prefix mismatch forces a cache miss instead of a stale hit.
fn first16_or_zero(pixels: &[u8]) -> [u8; 16] {
    let mut out = [0u8; 16];
    let n = pixels.len().min(16);
    out[..n].copy_from_slice(&pixels[..n]);
    out
}

/// Per Fix #45: hash the visible-stroke set using `f64::to_bits` for
/// the stroke's `first_point_record_time` (NaN-safe, exact bit
/// equality), and prefix the slice length so `[]` and
/// `[VisibleStroke{drawn=0}]` cannot collide. Stroke identity is
/// `Stroke::id` (Uuid) folded in as `u128` so two strokes with
/// identical geometry but different UUIDs distinguish.
fn hash_stroke_set(strokes: &[VisibleStroke]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (strokes.len() as u64).hash(&mut h);
    for vs in strokes {
        vs.stroke.id.as_u128().hash(&mut h);
        (vs.drawn_point_count as u64).hash(&mut h);
        vs.first_point_record_time.to_bits().hash(&mut h);
    }
    h.finish()
}

/// Builds a flat triangle-list vertex buffer (6 vertices per segment) from
/// the visible portion of every stroke. Returns an empty vec if no strokes
/// have ≥ 2 drawable points or if all points coincide (degenerate segments).
fn build_stroke_vertices(strokes: &[VisibleStroke]) -> Vec<StrokeVertex> {
    let mut out = Vec::new();
    for vs in strokes {
        let n = vs.drawn_point_count.min(vs.stroke.points.len());
        if n < 2 {
            continue;
        }
        // Per fix #4: stroke captured.color is in 0..1 floats already; pass
        // through. Captured stroke also carries its own line_width (also
        // normalized to frame height); we take the larger of (captured,
        // Phase-9 minimum) so faint strokes still hit the AA threshold.
        let color = [
            vs.stroke.color.r as f32,
            vs.stroke.color.g as f32,
            vs.stroke.color.b as f32,
            vs.stroke.color.a as f32,
        ];
        let captured_half = (vs.stroke.line_width as f32) * 0.5;
        let half_width = captured_half.max(PHASE9_MIN_HALF_WIDTH);

        for pair in vs.stroke.points[..n].windows(2) {
            let a = [pair[0].x as f32, pair[0].y as f32];
            let b = [pair[1].x as f32, pair[1].y as f32];
            let dx = b[0] - a[0];
            let dy = b[1] - a[1];
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-7 {
                continue; // degenerate segment
            }
            // Unit perpendicular (rotated 90°). Quad expansion along this
            // axis covers the line width + AA falloff; expansion along the
            // tangent extends past the endpoints so round caps fade cleanly.
            let nx = -dy / len;
            let ny = dx / len;
            let tx = dx / len;
            let ty = dy / len;
            let pad = half_width + STROKE_QUAD_AA_PAD;
            // 4 corners: a + (-tangent*pad ± perp*pad), b + (+tangent*pad ± perp*pad).
            let a_minus_t = [a[0] - tx * pad, a[1] - ty * pad];
            let b_plus_t = [b[0] + tx * pad, b[1] + ty * pad];
            let c0 = [a_minus_t[0] - nx * pad, a_minus_t[1] - ny * pad];
            let c1 = [a_minus_t[0] + nx * pad, a_minus_t[1] + ny * pad];
            let c2 = [b_plus_t[0] - nx * pad, b_plus_t[1] - ny * pad];
            let c3 = [b_plus_t[0] + nx * pad, b_plus_t[1] + ny * pad];

            let make = |position: [f32; 2]| StrokeVertex {
                position,
                segment_a: a,
                segment_b: b,
                half_width,
                _pad: 0.0,
                color,
            };
            // Two triangles (c0, c1, c2) and (c1, c3, c2) → triangle list.
            out.push(make(c0));
            out.push(make(c1));
            out.push(make(c2));
            out.push(make(c1));
            out.push(make(c3));
            out.push(make(c2));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_returns_input_bytes() {
        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(64, 64, [200, 100, 50, 255]);
        let webcam = Frame::solid(32, 32, [0, 0, 0, 255]); // unused in passthrough
        let out = comp.compose(&source, &webcam, &[]).expect("compose");
        assert_eq!(out.width, 64);
        assert_eq!(out.height, 64);
        // Sample the top-left corner: it's well outside the PiP rect (which
        // sits in the bottom-right) so should retain the source color.
        let i = ((8 * 64 + 8) * 4) as usize;
        let tl = &out.pixels[i..i + 4];
        assert!(
            (tl[0] as i32 - 200).abs() <= 2
                && (tl[1] as i32 - 100).abs() <= 2
                && (tl[2] as i32 - 50).abs() <= 2
                && tl[3] == 255,
            "top-left pixel diverged: {:?}",
            tl
        );
    }

    #[test]
    fn pip_places_webcam_in_bottom_right() {
        let comp = Compositor::new_headless().expect("compositor");

        // Source: solid red. Webcam: solid blue. After compose, the
        // top-left of the output should be red and the bottom-right region
        // should be blue.
        let source = Frame::solid(640, 360, [255, 0, 0, 255]);
        let webcam = Frame::solid(160, 90, [0, 0, 255, 255]);
        let out = comp.compose(&source, &webcam, &[]).expect("compose");

        let sample = |x: u32, y: u32| -> [u8; 4] {
            let i = ((y * out.width + x) * 4) as usize;
            [
                out.pixels[i],
                out.pixels[i + 1],
                out.pixels[i + 2],
                out.pixels[i + 3],
            ]
        };

        // Top-left (well outside the PiP) is the source color.
        let tl = sample(8, 8);
        assert_eq!(tl[..3], [255, 0, 0], "top-left should be red, got {:?}", tl);

        // Pixel near the bottom-right margin is inside the PiP and should be webcam blue.
        let br = sample(out.width - 12, out.height - 12);
        assert!(
            (br[2] as i32 - 255).abs() <= 4,
            "bottom-right should be webcam blue, got {:?}",
            br
        );
    }

    #[test]
    fn compose_with_no_strokes_matches_phase5_baseline() {
        // Regression guard for fix #5: passing &[] strokes must produce the
        // same pixels as the original PiP-only path. We can't call the OLD
        // signature (it's gone), so we re-assert the same red-source +
        // blue-webcam sampling expectations from `pip_places_webcam_in_
        // bottom_right` to prove the no-strokes path is unaffected by the
        // new API.
        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(640, 360, [255, 0, 0, 255]);
        let webcam = Frame::solid(160, 90, [0, 0, 255, 255]);
        let out = comp.compose(&source, &webcam, &[]).expect("compose");

        let sample = |x: u32, y: u32| -> [u8; 4] {
            let i = ((y * out.width + x) * 4) as usize;
            [
                out.pixels[i],
                out.pixels[i + 1],
                out.pixels[i + 2],
                out.pixels[i + 3],
            ]
        };

        let tl = sample(8, 8);
        assert_eq!(tl[..3], [255, 0, 0], "top-left should be red, got {:?}", tl);
        let br = sample(out.width - 12, out.height - 12);
        assert!(
            (br[2] as i32 - 255).abs() <= 4,
            "bottom-right should be webcam blue, got {:?}",
            br
        );
    }

    #[test]
    fn stroke_pass_changes_pixels_along_path() {
        use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};

        let comp = Compositor::new_headless().expect("compositor");
        // Solid red source so any non-red pixel proves the stroke pass ran.
        // PiP webcam goes to the bottom-right; we sample on the centerline.
        let source = Frame::solid(640, 360, [255, 0, 0, 255]);
        let webcam = Frame::solid(160, 90, [0, 0, 0, 255]);

        // Horizontal line across the middle, [0.2, 0.5] → [0.8, 0.5].
        let stroke = Stroke {
            id: uuid::Uuid::nil(),
            color: Rgba::RED, // captured red — but with PHASE9 alpha blending the (1,0.2,0.2)
            // color blends measurably on top of pure (1,0,0). Even if alpha=1
            // the stroke color (255, 51, 51) differs in green/blue channels
            // by 51, which is well above the ±2 tolerance.
            line_width: 0.01,
            points: vec![
                StrokePoint {
                    x: 0.2,
                    y: 0.5,
                    t: 0.0,
                },
                StrokePoint {
                    x: 0.8,
                    y: 0.5,
                    t: 1.0,
                },
            ],
            auto_clear_after_seconds: None,
        };
        let visible = VisibleStroke {
            stroke,
            first_point_record_time: 0.0,
            drawn_point_count: 2,
        };
        let out = comp
            .compose(&source, &webcam, std::slice::from_ref(&visible))
            .expect("compose");

        let sample = |x: u32, y: u32| -> [u8; 4] {
            let i = ((y * out.width + x) * 4) as usize;
            [
                out.pixels[i],
                out.pixels[i + 1],
                out.pixels[i + 2],
                out.pixels[i + 3],
            ]
        };

        // On the stroke (mid-x, mid-y): not the source color. Source is
        // (255, 0, 0); the stroke is RED (1.0, 0.2, 0.2) → green channel
        // should rise above 0.
        let on_stroke = sample(out.width / 2, out.height / 2);
        assert!(
            on_stroke[1] > 8,
            "expected stroke to lift green channel; got {:?}",
            on_stroke
        );

        // Off the stroke (mid-x, near top): IS the source color.
        let off_stroke = sample(out.width / 2, out.height / 10);
        assert!(
            (off_stroke[0] as i32 - 255).abs() <= 2 && off_stroke[1] <= 2 && off_stroke[2] <= 2,
            "expected source red off the stroke path; got {:?}",
            off_stroke
        );
    }

    #[test]
    fn pooled_vbo_grows_on_capacity_miss() {
        // Plan #4 Task 2: stroke VBO is pooled. First call allocates the
        // pool buffer (grow #1). A larger stroke that exceeds capacity
        // triggers exactly one grow (grow #2). A repeat of the same large
        // stroke MUST reuse the buffer (no grow). After three calls the
        // grow counter lands at exactly 2.
        use std::sync::atomic::Ordering;
        use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};

        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(640, 360, [255, 0, 0, 255]);
        let webcam = Frame::solid(160, 90, [0, 0, 0, 255]);

        let make_stroke = |n_points: usize| -> VisibleStroke {
            let denom = (n_points.saturating_sub(1).max(1)) as f64;
            let points: Vec<StrokePoint> = (0..n_points)
                .map(|i| {
                    let t = i as f64 / denom;
                    StrokePoint {
                        x: 0.2 + 0.6 * t,
                        y: 0.5,
                        t,
                    }
                })
                .collect();
            let drawn = points.len();
            let stroke = Stroke {
                id: uuid::Uuid::nil(),
                color: Rgba::RED,
                line_width: 0.01,
                points,
                auto_clear_after_seconds: None,
            };
            VisibleStroke {
                stroke,
                first_point_record_time: 0.0,
                drawn_point_count: drawn,
            }
        };

        let small = make_stroke(2);
        let _ = comp
            .compose(&source, &webcam, std::slice::from_ref(&small))
            .expect("compose small");
        let after_first = comp.stroke_vbo_grows.load(Ordering::Relaxed);
        assert_eq!(after_first, 1, "first call should allocate the pool once");

        let big = make_stroke(200);
        let _ = comp
            .compose(&source, &webcam, std::slice::from_ref(&big))
            .expect("compose big");
        let after_second = comp.stroke_vbo_grows.load(Ordering::Relaxed);
        assert_eq!(after_second, 2, "big stroke should trigger one grow");

        let _ = comp
            .compose(&source, &webcam, std::slice::from_ref(&big))
            .expect("compose big again");
        let after_third = comp.stroke_vbo_grows.load(Ordering::Relaxed);
        assert_eq!(
            after_third, 2,
            "third call (same size) must NOT grow; capacity already covers"
        );
    }

    #[test]
    fn compose_tick_matches_compose_method() {
        // Locks in fix #24's contract: `compose_tick` is a thin wrapper
        // around `Compositor::compose`. Same instance, same inputs, byte-
        // for-byte equality. If this ever drifts, the parity test in
        // Task 6 (and the preview-vs-export hash equality goal) fail.
        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(128, 72, [50, 200, 100, 255]);
        let webcam = Frame::solid(64, 36, [0, 0, 0, 255]);
        let via_method = comp.compose(&source, &webcam, &[]).expect("method");
        let via_free = crate::compose_tick(&comp, &source, &webcam, &[]).expect("free fn");
        assert_eq!(via_method.width, via_free.width);
        assert_eq!(via_method.height, via_free.height);
        assert_eq!(via_method.pixels, via_free.pixels);
    }

    #[test]
    fn pip_cache_rebuild_count_is_one_for_n_calls() {
        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(64, 64, [200, 100, 50, 255]);
        let webcam = Frame::solid(32, 32, [0, 0, 0, 255]);
        for _ in 0..5 {
            let _ = comp.compose(&source, &webcam, &[]).expect("compose");
        }
        let rebuilds = comp
            .pip_cache_rebuilds
            .load(std::sync::atomic::Ordering::Relaxed);
        assert_eq!(
            rebuilds, 1,
            "expected exactly 1 PiP pipeline rebuild for 5 same-dim composes, got {rebuilds}"
        );
    }

    #[test]
    fn freeze_cache_hit_returns_byte_identical_output() {
        // Plan #4 Task 3: compose_with_identity caches the composed
        // Arc<Frame> by Arc-pointer identity (defended by content
        // prefix). A second call with the SAME Arc<Frame> source +
        // webcam + strokes must return the SAME Arc (ptr_eq) and thus
        // byte-identical pixels — the cache hit short-circuits the GPU
        // compose entirely.
        use std::sync::atomic::Ordering;
        use std::sync::Arc;

        let comp = Compositor::new_headless().expect("compositor");
        let source = Arc::new(Frame::solid(64, 64, [200, 100, 50, 255]));
        let webcam = Arc::new(Frame::solid(32, 32, [0, 0, 0, 255]));

        let first = comp
            .compose_with_identity(&source, &webcam, &[])
            .expect("compose 1");
        let hits_after_first = comp.freeze_cache_hits.load(Ordering::Relaxed);
        assert_eq!(hits_after_first, 0, "first call must miss");

        let second = comp
            .compose_with_identity(&source, &webcam, &[])
            .expect("compose 2");
        let hits_after_second = comp.freeze_cache_hits.load(Ordering::Relaxed);
        assert_eq!(hits_after_second, 1, "second call must hit");

        assert!(
            Arc::ptr_eq(&first, &second),
            "cache hit should return the same Arc"
        );
        assert_eq!(first.pixels, second.pixels, "cache hit byte-identical");
    }

    #[test]
    fn stroke_hash_distinguishes_drawn_count() {
        use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};
        let stroke = Stroke {
            id: uuid::Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.01,
            points: vec![
                StrokePoint {
                    x: 0.0,
                    y: 0.0,
                    t: 0.0,
                },
                StrokePoint {
                    x: 0.5,
                    y: 0.5,
                    t: 0.5,
                },
                StrokePoint {
                    x: 1.0,
                    y: 1.0,
                    t: 1.0,
                },
            ],
            auto_clear_after_seconds: None,
        };
        let vs1 = VisibleStroke {
            stroke: stroke.clone(),
            first_point_record_time: 0.0,
            drawn_point_count: 2,
        };
        let vs2 = VisibleStroke {
            stroke,
            first_point_record_time: 0.0,
            drawn_point_count: 3,
        };
        assert_ne!(
            hash_stroke_set(std::slice::from_ref(&vs1)),
            hash_stroke_set(std::slice::from_ref(&vs2)),
            "drawn_point_count delta must change the hash"
        );
    }

    #[test]
    fn stroke_hash_length_prefix_disambiguates() {
        use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};
        let stroke = Stroke {
            id: uuid::Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.01,
            points: vec![StrokePoint {
                x: 0.0,
                y: 0.0,
                t: 0.0,
            }],
            auto_clear_after_seconds: None,
        };
        let single_empty = VisibleStroke {
            stroke,
            first_point_record_time: 0.0,
            drawn_point_count: 0,
        };
        let h_empty_slice = hash_stroke_set(&[]);
        let h_one_zero_drawn = hash_stroke_set(std::slice::from_ref(&single_empty));
        assert_ne!(
            h_empty_slice, h_one_zero_drawn,
            "[] must hash differently from [VisibleStroke{{drawn=0}}]; length prefix"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn pip_320x180_matches_macos_golden_hash() {
        use sha2::{Digest, Sha256};

        fn pixel_grid(w: u32, h: u32, scale: u8) -> Frame {
            let mut pixels = Vec::with_capacity((w * h * 4) as usize);
            for y in 0..h {
                for x in 0..w {
                    pixels.extend_from_slice(&[
                        (x * scale as u32) as u8,
                        (y * scale as u32) as u8,
                        128,
                        255,
                    ]);
                }
            }
            Frame::new(w, h, pixels)
        }

        let comp = Compositor::new_headless().expect("compositor");
        let source = pixel_grid(320, 180, 1);
        let webcam = pixel_grid(160, 90, 3);
        let out = comp.compose(&source, &webcam, &[]).expect("compose");

        let hex = format!("{:x}", Sha256::digest(&out.pixels));
        eprintln!("pip_320x180 hash on this machine: {hex}");

        // First-run procedure: this assertion intentionally fails until the
        // expected hash is filled in. Run `cargo test pip_320x180 -- --nocapture`,
        // copy the printed hash, paste it below, re-run to confirm match.
        let expected = "65557211990794a2aa913149e6a6e3ca2750f04597132938bb53e6f60ebbb55c";
        assert_eq!(hex, expected, "golden frame mismatch on macOS Metal");
    }
}
