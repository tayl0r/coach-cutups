use crate::frame::Frame;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CompositorError {
    #[error("no compatible wgpu adapter available")]
    NoAdapter,
    #[error("device request failed: {0}")]
    DeviceRequest(#[from] wgpu::RequestDeviceError),
    #[error("readback failed: {0}")]
    Readback(String),
}

#[allow(dead_code)] // device/queue used in Task 3+
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
        // wgpu 22's `Instance::new` takes the descriptor BY VALUE (not by
        // reference). A later wgpu version flipped this; using `&` here
        // produces a type-mismatch compile error against 22.x.
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        // `force_fallback_adapter: true` is required so headless Linux CI
        // (lavapipe = software Vulkan) returns an adapter at all. With
        // `false` and no real GPU, `request_adapter` returns `None` and
        // the test fails before the pipeline is built.
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: None,
                force_fallback_adapter: true,
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

    pub fn compose(&self, _source: &Frame, _webcam: &Frame) -> Result<Frame, CompositorError> {
        Err(CompositorError::Readback("not implemented yet".into()))
    }
}
