use crate::frame::Frame;
use thiserror::Error;
use wgpu::util::DeviceExt;

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
        Ok(Self { device, queue })
    }

    pub fn compose(&self, source: &Frame, webcam: &Frame) -> Result<Frame, CompositorError> {
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

        // 3. Pipeline.
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
        let bgl = self
            .device
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
        let pl_layout = self
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("pip-layout"),
                bind_group_layouts: &[&bgl],
                push_constant_ranges: &[],
            });
        let pipeline = self
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("pip-pipeline"),
                layout: Some(&pl_layout),
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

        let src_view = src_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let webcam_view = webcam_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("pip-bg"),
            layout: &bgl,
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
                    resource: wgpu::BindingResource::Sampler(&sampler),
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
            rpass.set_pipeline(&pipeline);
            rpass.set_bind_group(0, &bind_group, &[]);
            rpass.draw(0..3, 0..1);
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_returns_input_bytes() {
        let comp = Compositor::new_headless().expect("compositor");
        let source = Frame::solid(64, 64, [200, 100, 50, 255]);
        let webcam = Frame::solid(32, 32, [0, 0, 0, 255]); // unused in passthrough
        let out = comp.compose(&source, &webcam).expect("compose");
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
        let out = comp.compose(&source, &webcam).expect("compose");

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
        let out = comp.compose(&source, &webcam).expect("compose");

        let hex = format!("{:x}", Sha256::digest(&out.pixels));
        eprintln!("pip_320x180 hash on this machine: {hex}");

        // First-run procedure: this assertion intentionally fails until the
        // expected hash is filled in. Run `cargo test pip_320x180 -- --nocapture`,
        // copy the printed hash, paste it below, re-run to confirm match.
        let expected = "65557211990794a2aa913149e6a6e3ca2750f04597132938bb53e6f60ebbb55c";
        assert_eq!(hex, expected, "golden frame mismatch on macOS Metal");
    }
}
