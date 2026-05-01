/// An RGBA8 pixel buffer with explicit dimensions. Row-major, top-left origin,
/// no padding (bytes_per_row == width * 4). All compositor inputs and outputs
/// use this format; format conversion to/from GStreamer's NV12/I420 happens
/// in the bridge layer (Phase 5+).
///
/// `PartialEq` derive (Phase 10 Task 5, fix #40) lets the N-frame parity
/// test compare `Vec<Frame>` byte-equal across two `compose_entry_frame`
/// calls. `Vec<u8>` already implements `PartialEq` so the derive is free;
/// the derived comparison is field-by-field equality on width/height/pixels.
#[derive(Debug, Clone, PartialEq, Eq)]
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
        Self {
            width,
            height,
            pixels,
        }
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
