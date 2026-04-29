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

    pub fn compose(&self, source: &Frame, _webcam: &Frame) -> Result<Frame, CompositorError> {
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

        // 2. Render target.
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

        // 3. Pipeline.
        let shader = self
            .device
            .create_shader_module(wgpu::include_wgsl!("shaders/passthrough.wgsl"));
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
                label: Some("passthrough-bgl"),
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
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            });
        let pl_layout = self
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("passthrough-layout"),
                bind_group_layouts: &[&bgl],
                push_constant_ranges: &[],
            });
        let pipeline = self
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("passthrough-pipeline"),
                layout: Some(&pl_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: "vs_fullscreen",
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: "fs_passthrough",
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
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("passthrough-bg"),
            layout: &bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&src_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&sampler),
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
        // Allow tiny rounding from sample/blit; compare a center pixel.
        let i = ((32 * 64 + 32) * 4) as usize;
        let center = &out.pixels[i..i + 4];
        assert!(
            (center[0] as i32 - 200).abs() <= 2
                && (center[1] as i32 - 100).abs() <= 2
                && (center[2] as i32 - 50).abs() <= 2
                && center[3] == 255,
            "center pixel diverged: {:?}",
            center
        );
    }
}
